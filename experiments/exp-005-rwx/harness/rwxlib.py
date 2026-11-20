"""EXP-005-RWX harness library (issue #32). Pure logic plus a guarded kubectl wrapper. stdlib only.

Safety model (all enforced here, unit-tested in tests/test_rwxlib.py):
  * Three modes. Default = offline dry run: kubectl is never executed. --live = read-only cluster contact.
    --execute (with --confirm-run-id equal to --run-id) = mutations allowed.
  * Mutations are limited to: apply of this experiment's own rendered manifests (Namespace, PVC, Pod,
    NetworkPolicy), graceful delete of a named Pod/PVC/NetworkPolicy in the scratch namespace, and delete of
    the scratch Namespace itself. Every delete first re-reads the object's labels and requires
    herdrnetes.io/experiment=exp-005-rwx and herdrnetes.io/run-id=<run id>.
  * Reads never target Secrets. Longhorn, PVs, VolumeAttachments and the live Herdr pod are only ever read.
  * Evidence is sanitized in memory and scanned for residual identifiers before it is written to disk.
"""
import json
import os
import re
import statistics
import subprocess
import sys
import time
from collections import namedtuple
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
EXP_DIR = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(os.path.dirname(EXP_DIR))
MANIFEST_DIR = os.path.join(EXP_DIR, "manifests")

EXPERIMENT = "exp-005-rwx"
EXP_LABEL = "herdrnetes.io/experiment"
RUN_LABEL = "herdrnetes.io/run-id"
NS_PREFIX = "herdrnetes-exp005-rwx-"
STORAGE_CLASS = "longhorn"
PVC_NAME = "rwx-scratch"
PODS = {"a": "rwx-a", "b": "rwx-b"}
CONTAINER = "ws"
MOUNT = "/rwx"
WORK = "/rwx/work"
# Same digest as EXP-005 (RESULTS.md, experiments/exp-005/manifests/workspace-pod.yaml).
IMAGE = ("ghcr.io/jlaska/herdrnetes-herdr@"
         "sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277")
LONGHORN_NS = "longhorn-system"
DEFAULT_HERDR_NS = "herdrnetes-exp"     # live Herdr; read-only
DEFAULT_HERDR_POD = "herdr-0"
HERDR_LABEL = "app.kubernetes.io/name=herdr"
DEFAULT_EXPECT_LONGHORN = "v1.13.0"      # cluster identity guard; override with RWX_EXPECT_LONGHORN (recorded in evidence)
MAINT_WINDOW = ((6, 30), (8, 30))         # UTC; the tuppr upgrade window is 07:00Z and node restarts followed it
UPGRADE_IDLE_PHASES = ("", "completed", "idle", "succeeded", "ready", "healthy")
UPGRADE_CRD_HINTS = ("talosupgrade", "kubernetesupgrade")   # matched against CRD names; no API group is hard-coded
DNS_LABEL_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

TIMEOUTS = dict(pvc_bound=120, pod_ready=300, share_manager=180, pod_delete=120, cleanup=300, lock_after_delete=150)
DISK_STOP_PCT = 85                       # stop if the 1Gi volume is this full
ALLOWED_KINDS = ("Namespace", "PersistentVolumeClaim", "Pod", "NetworkPolicy")
MUTABLE_DELETE_KINDS = ("pod", "persistentvolumeclaim", "networkpolicy")
RUN_ID_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$")   # namespace <= 63 chars incl. prefix
NODE_SEL_RE = re.compile(r"^([A-Za-z0-9._/-]{1,63})=([A-Za-z0-9._-]{1,63})$")

CmdResult = namedtuple("CmdResult", "rc out err")


class Refused(Exception):
    """A guard refused an operation (never retried, never worked around)."""


class StopRun(Exception):
    """A mandatory stop condition fired. The runner collects evidence and runs guarded cleanup."""


class HangSuspected(StopRun):
    """A kubectl exec/probe timed out or a process outlived its timeout: an NFS I/O hang is suspected.
    Further tests are skipped; evidence is collected; graceful cleanup is attempted; residue is reported, never forced."""


def utcnow():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print(f"{utcnow()} {msg}", file=sys.stderr, flush=True)


MATRIX = [
    ("R00", "Baseline and read-only preflight; live Herdr baseline"),
    ("R01", "Provision the RWX PVC; two pods on different nodes; share-manager appears"),
    ("R02", "Mount options, owner/mode/fsGroup observation, UID 1000 write + git smoke gate (STOP gate)"),
    ("R03", "Cross-node visibility (close-to-open): new file, in-place update, open/listdir/stat"),
    ("R04", "Sequential hand-off: hydrate on B, commit alternately on A/B, fsck both"),
    ("R05", "Concurrent request-repo: 4+4 same repo across nodes; two different repos at once"),
    ("R06", "Cross-node flock and fcntl exclusion; release on holder exit"),
    ("R07", "renameat2 RENAME_NOREPLACE availability, errno, plain rename onto non-empty dir, fallback"),
    ("R08", "Concurrent git on ONE repo (index.lock/ref lock) and O_EXCL race"),
    ("R09", "git worktree across pods, stable absolute paths; INFO: rename parent then worktree repair"),
    ("R10", "POSIX edges: umask/mode, mmap/msync, fsync, hardlink/symlink, O_APPEND race"),
    ("R11", "Small-file performance (repeated, medians) vs emptyDir control"),
    ("R12", "Ordinary delete/recreate of one scratch pod; data, locks, fsck, I/O errors"),
    ("R13", "Share-manager lifecycle, image, replica nodes and objects, read-only, at every checkpoint"),
    ("R14", "Guarded cleanup; verify PVC/PV/Longhorn volume/share-manager/namespace gone"),
]

PREFLIGHT_READS = [
    "clock guard: UTC must be outside 06:30-08:30; get nodes (all Ready, none cordoned); get crd + upgrade CRs (tuppr) must be idle/completed",
    "kubectl config get-contexts -o name; kubectl version -o json",
    "cluster identity: longhorn-manager image tag == expected (default v1.13.0); Herdr namespace exists; exactly one pod labelled "
    "app.kubernetes.io/name=herdr, owned by a StatefulSet; >= 2 schedulable nodes excluding the Herdr node",
    "get namespace <ns> (must be absent); get storageclass longhorn; get csidriver driver.longhorn.io",
    "get volumes.longhorn.io, nodes.longhorn.io, sharemanagers.longhorn.io, settings.longhorn.io <3 named settings>, pods (longhorn-system)",
    "auth can-i create namespaces / persistentvolumeclaims / pods",
    "get pod <herdr pod> in the live Herdr namespace (UID + restart counts only)",
]

# ----------------------------------------------------------------------------- naming and manifests
def valid_run_id(run_id):
    if not isinstance(run_id, str) or not RUN_ID_RE.match(run_id):
        raise Refused(f"invalid run-id {run_id!r}: lowercase alphanumerics and '-', 1-24 chars, "
                      "starting and ending alphanumeric")
    return run_id


def namespace_for(run_id):
    return NS_PREFIX + valid_run_id(run_id)


def parse_node_selector(spec):
    """RWX_NODE_SELECTOR='key=value' (runtime only; never committed). Returns dict ({} when unset)."""
    if not spec:
        return {}
    m = NODE_SEL_RE.match(spec.strip())
    if not m:
        raise Refused("RWX_NODE_SELECTOR must be a single key=value pair")
    return {m.group(1): m.group(2)}


def render(template_name, run_id, **extra):
    """Render manifests/<template_name>.yaml by plain ${VAR} substitution; unknown variables are an error."""
    ns = namespace_for(run_id)
    values = dict(RUN_ID=run_id, NAMESPACE=ns, NODE_SELECTOR_JSON="{}", HERDR_NS=DEFAULT_HERDR_NS)
    if not DNS_LABEL_RE.match(str(extra.get("HERDR_NS", values["HERDR_NS"]))):
        raise Refused("HERDR_NS is not a valid namespace name")
    values.update({k: str(v) for k, v in extra.items()})
    with open(os.path.join(MANIFEST_DIR, template_name + ".yaml")) as fh:
        text = fh.read()
    out = re.sub(r"\$\{([A-Z_]+)\}", lambda m: values[m.group(1)] if m.group(1) in values else _missing(m), text)
    validate_manifest_text(out, ns, run_id)
    return out


def _missing(m):
    raise Refused(f"manifest variable ${{{m.group(1)}}} has no value")


def render_pod(run_id, which, node_selector=None, herdr_ns=DEFAULT_HERDR_NS):
    if which not in PODS:
        raise Refused(f"unknown pod {which!r}")
    sel = json.dumps(node_selector or {}, sort_keys=True)
    return render("pod", run_id, POD_NAME=PODS[which], COMPONENT=f"rwx-{which}", NODE_SELECTOR_JSON=sel, HERDR_NS=herdr_ns)


def split_docs(text):
    return [d for d in re.split(r"(?m)^---\s*$", text) if d.strip()]


def validate_manifest_text(text, ns, run_id):
    """Every document: allowed kind, run-id label, and (if namespaced) exactly the scratch namespace."""
    for doc in split_docs(text):
        kind = re.search(r"(?m)^kind:\s*(\S+)\s*$", doc)
        if not kind or kind.group(1) not in ALLOWED_KINDS:
            raise Refused(f"manifest kind not allowed: {kind.group(1) if kind else None}")
        if not re.search(r'(?m)^\s+%s:\s*"?%s"?\s*$' % (re.escape(RUN_LABEL), re.escape(run_id)), doc):
            raise Refused("manifest lacks the run-id label")
        if not re.search(r"(?m)^\s+%s:\s*%s\s*$" % (re.escape(EXP_LABEL), EXPERIMENT), doc):
            raise Refused("manifest lacks the experiment label")
        if kind.group(1) == "Namespace":
            if not re.search(r"(?m)^  name:\s*%s\s*$" % re.escape(ns), doc):
                raise Refused("Namespace manifest names a different namespace")
        else:
            if not re.search(r"(?m)^  namespace:\s*%s\s*$" % re.escape(ns), doc):
                raise Refused("namespaced manifest names a different namespace")
    return True


# ----------------------------------------------------------------------------- kubectl wrapper
FORBIDDEN_READ_KINDS = re.compile(r"(^|[,/ ])secrets?(\.|,|$)", re.I)
READ_VERBS = ("get", "describe", "version", "logs")


def validate_read(argv):
    if not argv or argv[0] not in READ_VERBS and argv[:2] not in (["auth", "can-i"], ["config", "get-contexts"]):
        raise Refused(f"not a read-only kubectl verb: {argv[:2]}")
    joined = " ".join(argv)
    if argv[0] in ("get", "describe") and any(FORBIDDEN_READ_KINDS.search(a) for a in argv[1:2]):
        raise Refused("reading Secrets is not allowed")
    for bad in ("-w", "--watch", "--raw", "--as", "--token", "--kubeconfig", "--server"):
        if bad in argv:
            raise Refused(f"flag not allowed in a read: {bad}")
    if "--dry-run=server" in joined:
        raise Refused("--dry-run=server is prohibited")
    return True


def validate_mutation(argv, ns, run_id):
    """Allow-list for mutating kubectl calls (argv excludes --context/-n, which Kube adds)."""
    valid_run_id(run_id)
    if any(a.startswith(("--force", "--grace-period", "--now", "--all", "--selector", "-l", "--dry-run",
                         "--cascade", "--wait=foreground", "--field-selector", "--as", "--kubeconfig",
                         "--server", "--token", "--overwrite", "--prune", "-A", "--all-namespaces"))
           for a in argv):
        raise Refused(f"forbidden flag in mutation: {argv}")
    if argv[:3] == ["apply", "-f", "-"] and len(argv) == 3:
        return "apply"
    if argv[0] == "delete" and len(argv) >= 3:
        kind, name = argv[1], argv[2]
        flags = argv[3:]
        for f in flags:
            if not re.fullmatch(r"--wait=(true|false)|--timeout=\d{1,4}s", f):
                raise Refused(f"delete flag not allowed: {f}")
        if kind == "namespace":
            if name != ns:
                raise Refused("refusing to delete a namespace other than the scratch namespace")
            return "delete-namespace"
        if kind not in MUTABLE_DELETE_KINDS:
            raise Refused(f"refusing to delete kind {kind}")
        if "/" in name or name.startswith("-") or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", name):
            raise Refused(f"bad object name {name!r}")
        return "delete-" + kind
    raise Refused(f"mutation not on the allow-list: {argv[:3]}")


def subprocess_runner(argv, input=None, timeout=None):
    try:
        p = subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout)
        return CmdResult(p.returncode, p.stdout, p.stderr)
    except subprocess.TimeoutExpired as e:
        return CmdResult(124, (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""),
                         f"timeout after {timeout}s")


class Kube:
    """kubectl pinned to one context and the scratch namespace. Mode is decided by (live, execute)."""

    def __init__(self, ctx, run_id, live=False, execute=False, runner=subprocess_runner, popen=subprocess.Popen,
                 echo=log):
        self.run_id = valid_run_id(run_id)
        self.ns = namespace_for(run_id)
        self.ctx = ctx
        self.live = live or execute
        self.execute = execute
        self.runner = runner
        self.popen = popen
        self.echo = echo
        self.trace = []                  # every command line, for evidence (sanitized on write)
        self.procs = []                  # local `kubectl exec` clients started with popen_exec
        if self.live and not ctx:
            raise Refused("KCTX is not set (no default; pass the owner-designated kubeconfig context)")

    def _base(self, ns=True):
        return ["kubectl", "--context", self.ctx] + (["-n", self.ns] if ns else [])

    def _go(self, argv, mutating, input=None, timeout=None):
        line = " ".join(argv)
        self.trace.append(line)
        if mutating and not self.execute:
            self.echo(f"DRY-RUN (mutation, not executed): {line}")
            return CmdResult(0, "", "dry-run")
        if not self.live:
            self.echo(f"DRY-RUN (offline, not executed): {line}")
            return CmdResult(0, "", "dry-run")
        self.echo(("EXEC " if mutating else "read ") + line)
        return self.runner(argv, input=input, timeout=timeout)

    # -- reads
    def read(self, args, ns=True, namespace=None, timeout=60):
        validate_read(args)
        base = ["kubectl", "--context", self.ctx]
        if namespace:
            base += ["-n", namespace]
        elif ns:
            base += ["-n", self.ns]
        return self._go(base + list(args), False, timeout=timeout)

    def read_json(self, args, **kw):
        r = self.read(list(args) + ["-o", "json"], **kw)
        if r.err == "dry-run":
            return None
        if r.rc != 0:
            return {"__error__": r.err.strip(), "__rc__": r.rc}
        try:
            return json.loads(r.out)
        except ValueError:
            return {"__error__": "unparseable json", "__rc__": r.rc}

    # -- exec in a scratch pod (runs inside our own pods only)
    def _exec_argv(self, pod, cmd):
        if pod not in PODS.values():
            raise Refused(f"exec only allowed in {sorted(PODS.values())}, not {pod!r}")
        return self._base() + ["exec", "-i", pod, "-c", CONTAINER, "--"] + [str(c) for c in cmd]

    def exec(self, pod, cmd, stdin=None, timeout=300):
        r = self._go(self._exec_argv(pod, cmd), False, input=stdin, timeout=timeout)
        if r.rc == 124 and r.err.startswith("timeout"):
            raise HangSuspected(f"NFS I/O hang suspected: exec in {pod} timed out after {timeout}s ({' '.join(map(str, cmd[:5]))})")
        return r

    def popen_exec(self, pod, cmd, stdin=None):
        argv = self._exec_argv(pod, cmd)
        self.trace.append(" ".join(argv))
        if not self.live:
            raise Refused("popen_exec requires --live")
        self.echo("read " + " ".join(argv))
        p = self.popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if stdin is not None:
            p.stdin.write(stdin)
            p.stdin.close()
        self.procs.append(p)
        return p

    def reap(self):
        """Terminate local kubectl-exec clients still running (never touches the cluster). Returns how many were left."""
        left = 0
        for p in self.procs:
            if p.poll() is None:
                left += 1
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
        self.procs = []
        return left

    # -- mutations
    def apply(self, manifest_text):
        validate_manifest_text(manifest_text, self.ns, self.run_id)
        validate_mutation(["apply", "-f", "-"], self.ns, self.run_id)
        argv = ["kubectl", "--context", self.ctx, "apply", "-f", "-"]
        return self._go(argv, True, input=manifest_text, timeout=120)

    def guard_labels(self, kind, name):
        """Object must exist with experiment=exp-005-rwx and run-id=<this run>. Dry-run: skipped."""
        if not self.live:
            return
        r = self.read_json(["get", kind, name], ns=False if kind == "namespace" else True)
        if r is None or "__error__" in r:
            raise Refused(f"guard: {kind}/{name} not readable: {(r or {}).get('__error__')}")
        labels = r.get("metadata", {}).get("labels") or {}
        if labels.get(EXP_LABEL) != EXPERIMENT or labels.get(RUN_LABEL) != self.run_id:
            raise Refused(f"guard: {kind}/{name} lacks {EXP_LABEL}={EXPERIMENT} / {RUN_LABEL}={self.run_id}")
        if kind != "namespace" and r.get("metadata", {}).get("namespace") != self.ns:
            raise Refused(f"guard: {kind}/{name} is not in {self.ns}")

    def delete(self, kind, name, wait=True, timeout=120):
        argv = ["delete", kind, name, f"--wait={'true' if wait else 'false'}", f"--timeout={timeout}s"]
        if kind == "namespace":
            argv = ["delete", kind, name, "--wait=false"]
        validate_mutation(argv, self.ns, self.run_id)
        self.guard_labels(kind, name)
        base = ["kubectl", "--context", self.ctx] + ([] if kind == "namespace" else ["-n", self.ns])
        return self._go(base + argv, True, timeout=timeout + 30)


# ----------------------------------------------------------------------------- pure analysis helpers
def summarize(values):
    vals = [float(v) for v in values]
    if not vals:
        return dict(n=0)
    return dict(n=len(vals), min=min(vals), median=statistics.median(vals), max=max(vals),
                mean=round(statistics.fmean(vals), 4))


def parse_probe_output(text):
    """Probes print diagnostics freely and a final single-line JSON object. Return it (or {})."""
    for line in reversed((text or "").strip().splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return {}


def herdr_facts(pod_json):
    """UID and per-container restart counts of a pod object, or None."""
    if not pod_json or "__error__" in pod_json:
        return None
    md = pod_json.get("metadata", {})
    rc = {c["name"]: c.get("restartCount", 0) for c in pod_json.get("status", {}).get("containerStatuses", [])}
    return {"uid": md.get("uid"), "restarts": rc}


def longhorn_volume_states(volumes_json):
    """name -> (state, robustness) from `get volumes.longhorn.io -o json`."""
    out = {}
    for item in (volumes_json or {}).get("items", []):
        st = item.get("status", {})
        out[item["metadata"]["name"]] = (st.get("state", ""), st.get("robustness", ""))
    return out


BAD_ROBUSTNESS = ("degraded", "faulted")


def check_invariants(base_herdr, now_herdr, base_vols, now_vols, scratch_volume=None, nodes_a_b=None):
    """Return (stops, infos). Each stop is a mandatory stop condition from the issue #32 owner conditions."""
    stops, infos = [], []
    if base_herdr is not None:
        if now_herdr is None:
            stops.append("live Herdr pod unreadable or missing")
        else:
            if now_herdr["uid"] != base_herdr["uid"]:
                stops.append("live Herdr pod UID changed")
            if now_herdr["restarts"] != base_herdr["restarts"]:
                stops.append(f"live Herdr restart counts changed: {base_herdr['restarts']} -> {now_herdr['restarts']}")
    for name, (_state, rob) in (now_vols or {}).items():
        if name == scratch_volume:
            continue
        b = (base_vols or {}).get(name)
        if b is None:
            infos.append(f"new Longhorn volume outside the scratch PVC: {name}")
            continue
        if b[1] != rob:
            msg = f"volume {name} robustness {b[1]!r} -> {rob!r}"
            (stops if rob in BAD_ROBUSTNESS else infos).append(msg)
    for name in (base_vols or {}):
        if name not in (now_vols or {}) and name != scratch_volume:
            infos.append(f"Longhorn volume vanished: {name}")
    if nodes_a_b and nodes_a_b[0] and nodes_a_b[0] == nodes_a_b[1]:
        stops.append("both scratch pods are on the same node")
    return stops, infos


def evaluate_gate(r):
    """R02 stop gate. r is the `writegate` probe result for UID 1000 at the mount root.
    Returns (ok, reasons). Never suggests a remedy: the harness must stop, collect and clean up."""
    reasons = []
    if not r:
        return False, ["no probe output"]
    if r.get("uid") != 1000 or r.get("gid") != 1000:
        reasons.append(f"unexpected identity uid={r.get('uid')} gid={r.get('gid')}")
    for step, res in (r.get("steps") or {}).items():
        if not res.get("ok"):
            reasons.append(f"{step} failed: {res.get('errno')}" + (f" ({res['msg']})" if res.get("msg") else ""))
    if not r.get("steps"):
        reasons.append("no gate steps reported")
    root = r.get("root_stat") or {}
    if not root:
        reasons.append("no root_stat reported")
    else:
        if not root.get("is_dir", False):
            reasons.append("mount root is not a directory")
        if root.get("uid") not in (0, 1000) or root.get("gid") not in (0, 1000):
            reasons.append(f"unexpected ownership at mount root: uid={root.get('uid')} gid={root.get('gid')} "
                           f"mode={oct(root.get('mode') or 0)}")
    return not reasons, reasons


def pods_on_different_nodes(a, b):
    return bool(a) and bool(b) and a != b


# ----------------------------------------------------------------------------- environment guards (pure)
def image_tag(image):
    """'repo/name:v1.13.0' -> 'v1.13.0'; digest-only or untagged -> ''."""
    ref = (image or "").split("@")[0]
    return ref.rsplit(":", 1)[1] if ":" in ref.rsplit("/", 1)[-1] else ""


def longhorn_manager_tags(pods_json):
    tags = set()
    for p in (pods_json or {}).get("items", []):
        if p.get("metadata", {}).get("name", "").startswith("longhorn-manager"):
            for c in p.get("spec", {}).get("containers", []):
                if c.get("name") == "longhorn-manager":
                    tags.add(image_tag(c.get("image")))
    return sorted(tags)


def identity_stops(expected_tag, manager_tags, herdr_ns_json, herdr_pods_json, herdr_pod_name):
    """Cluster identity guard: refuse to run against the wrong kube context."""
    stops = []
    if not manager_tags:
        stops.append("no longhorn-manager pods found in longhorn-system (wrong context?)")
    elif manager_tags != [expected_tag]:
        stops.append(f"longhorn-manager image tag(s) {manager_tags} != expected {expected_tag!r} (wrong context?)")
    if not herdr_ns_json or "__error__" in herdr_ns_json:
        stops.append("Herdr namespace not found (wrong context?)")
    pods = (herdr_pods_json or {}).get("items", []) if herdr_pods_json and "__error__" not in herdr_pods_json else []
    if len(pods) != 1:
        stops.append(f"expected exactly one pod labelled {HERDR_LABEL} in the Herdr namespace, found {len(pods)}")
    else:
        pod = pods[0]
        if pod["metadata"].get("name") != herdr_pod_name:
            stops.append(f"Herdr pod is {pod['metadata'].get('name')!r}, expected {herdr_pod_name!r}")
        if not any(o.get("kind") == "StatefulSet" for o in pod["metadata"].get("ownerReferences", []) or []):
            stops.append("Herdr pod is not owned by a StatefulSet")
    return stops


def node_ready(n):
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in n.get("status", {}).get("conditions", []))


def node_health_stops(nodes_json):
    stops = []
    for n in (nodes_json or {}).get("items", []):
        name = n["metadata"]["name"]
        if not node_ready(n):
            stops.append(f"node {name} is NotReady")
        if n.get("spec", {}).get("unschedulable"):
            stops.append(f"node {name} is cordoned")
    return stops


def candidate_nodes(nodes_json, herdr_node):
    """Ready, schedulable, untainted nodes other than the one running live Herdr."""
    return [n["metadata"]["name"] for n in (nodes_json or {}).get("items", [])
            if node_ready(n) and not n.get("spec", {}).get("unschedulable") and not n.get("spec", {}).get("taints")
            and n["metadata"]["name"] != herdr_node]


def in_maintenance_window(now, window=MAINT_WINDOW):
    (h1, m1), (h2, m2) = window
    t = (now.hour, now.minute)
    return (h1, m1) <= t < (h2, m2)


def upgrade_crd_names(crd_json):
    return sorted(i["metadata"]["name"] for i in (crd_json or {}).get("items", [])
                  if any(h in i["metadata"]["name"].split(".")[0].lower() for h in UPGRADE_CRD_HINTS))


def upgrade_stops(crs):
    """crs: list of (crd, name, phase). Anything not clearly completed/idle blocks the run."""
    return [f"upgrade CR {crd}/{name} phase {phase!r} is not completed/idle"
            for crd, name, phase in crs if (phase or "").lower() not in UPGRADE_IDLE_PHASES]


def scratch_pod_stops(pod_json, name):
    """A scratch container must still be running, never restarted (restartPolicy Never)."""
    if not pod_json or "__error__" in pod_json:
        return [f"scratch pod {name} unreadable"]
    stops = []
    st = pod_json.get("status", {})
    if st.get("phase") != "Running":
        stops.append(f"scratch pod {name} phase is {st.get('phase')!r}")
    for c in st.get("containerStatuses", []) or []:
        if c.get("restartCount", 0) > 0:
            stops.append(f"scratch pod {name} container {c.get('name')} restarted ({c['restartCount']})")
        if "terminated" in (c.get("state") or {}):
            stops.append(f"scratch pod {name} container {c.get('name')} terminated unexpectedly")
    return stops


# ----------------------------------------------------------------------------- cleanup planning (pure)
SYSTEM_OBJECTS = {("configmap", "kube-root-ca.crt"), ("serviceaccount", "default")}
EXPECTED_KINDS = {"pod", "persistentvolumeclaim", "networkpolicy"}
CLEANUP_ORDER = ("pod", "networkpolicy", "persistentvolumeclaim")


def plan_cleanup(inventory, ns_obj, run_id):
    """inventory: list of {kind,name,labels}. ns_obj: Namespace JSON or None. Returns dict(refusals, deletes, delete_ns)."""
    valid_run_id(run_id)
    ns = namespace_for(run_id)
    refusals, deletes = [], []
    if ns_obj is None:
        return dict(refusals=[], deletes=[], delete_ns=False, note="namespace absent; nothing to do")
    meta = ns_obj.get("metadata", {})
    labels = meta.get("labels") or {}
    if meta.get("name") != ns:
        refusals.append(f"namespace name mismatch: {meta.get('name')!r}")
    if labels.get(EXP_LABEL) != EXPERIMENT:
        refusals.append(f"namespace lacks {EXP_LABEL}={EXPERIMENT}")
    if labels.get(RUN_LABEL) != run_id:
        refusals.append(f"namespace lacks {RUN_LABEL}={run_id}")
    for it in inventory:
        kind, name, lab = it["kind"].lower(), it["name"], it.get("labels") or {}
        if (kind, name) in SYSTEM_OBJECTS:
            continue
        if kind not in EXPECTED_KINDS:
            refusals.append(f"unexpected kind in namespace: {kind}/{name}")
        elif lab.get(EXP_LABEL) != EXPERIMENT or lab.get(RUN_LABEL) != run_id:
            refusals.append(f"{kind}/{name} lacks the experiment/run-id labels")
        else:
            deletes.append((kind, name))
    deletes.sort(key=lambda kn: (CLEANUP_ORDER.index(kn[0]), kn[1]))
    return dict(refusals=refusals, deletes=deletes, delete_ns=not refusals, note="")


def verify_cleanup(facts):
    """facts: dict of booleans/lists observed read-only after cleanup. Returns list of failures (empty = all gone)."""
    fails = []
    for key, label in (("namespace_present", "scratch namespace still present"),
                       ("pvc_present", "scratch PVC still present"),
                       ("pv_present", "scratch PV still present"),
                       ("longhorn_volume_present", "Longhorn volume still present"),
                       ("share_manager_pod_present", "share-manager pod still present"),
                       ("share_manager_cr_present", "ShareManager CR still present"),
                       ("share_manager_service_present", "share-manager Service still present"),
                       ("volume_attachment_present", "VolumeAttachment still present")):
        if facts.get(key):
            fails.append(label)
    return fails


# ----------------------------------------------------------------------------- sanitizer
IPV4_RE = re.compile(r"(?<![\w.])(?!127\.0\.0\.1(?![\d.]))(?!0\.0\.0\.0(?![\d.]))(?:\d{1,3}\.){3}\d{1,3}(?![\w]|\.\d)")
IPV6_RE = re.compile(r"(?<![0-9A-Fa-f:.])[0-9A-Fa-f]*(?::[0-9A-Fa-f]*){2,7}(?![0-9A-Fa-f:.])")
APISERVER_RE = re.compile(r"https?://(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):6443")
INTERNAL_DOMAIN_RE = re.compile(r"\b[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.(?:local|internal|lan|home|corp|intranet|localdomain)\b")
MAC_RE = re.compile(r"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b")
HOME_RE = re.compile(r"/home/[^/\s\"']+")
PRIVKEY_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)", re.S)
TOKEN_RES = [re.compile(p) for p in (r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
                                     r"gh[pousr]_[A-Za-z0-9]{20,}", r"github_pat_[A-Za-z0-9_]{20,}",
                                     r"glpat-[A-Za-z0-9_-]{16,}", r"AKIA[0-9A-Z]{16}",
                                     r"sk-[A-Za-z0-9]{24,}")]
BEARER_RE = re.compile(r"(?i)\bbearer\s+(?!<redacted)[A-Za-z0-9._~+/=-]+")
# key: value / key=value where the key names a credential and the value is not a boolean/empty literal
KV_SECRET_RE = re.compile(
    r"""(?ix)\b([\w.-]*(?:token|password|passwd|secret|bearer|authorization|api[_-]?key)[\w.-]*)(\s*["']?\s*[:=]\s*["']?)
        (?!true\b|false\b|null\b|none\b|<redacted)([^\s"',}]+)""")


class Sanitizer:
    """Replace node names with <node-N>, drop IPs, internal domains, API server URLs, home paths, tokens and keys.
    Node names are supplied at run time and never stored in the repository."""

    def __init__(self, node_names=(), extra_literals=(), context_name=None):
        self.nodes = {}
        for n in sorted(set(node_names)):
            self.add_node(n)
        self.extra = sorted({e for e in extra_literals if e}, key=len, reverse=True)
        self.context = context_name or None

    def add_node(self, name):
        if name and name not in self.nodes:
            self.nodes[name] = f"<node-{len(self.nodes) + 1}>"
        return self.nodes.get(name)

    def alias(self, name):
        return self.nodes.get(name, name)

    def text(self, s):
        if s is None:
            return s
        s = PRIVKEY_RE.sub("<redacted-private-key>", s)
        for rx in TOKEN_RES:
            s = rx.sub("<redacted-token>", s)
        s = BEARER_RE.sub("Bearer <redacted>", s)
        s = KV_SECRET_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}<redacted>", s)
        s = APISERVER_RE.sub("<apiserver>", s)
        if self.context:
            s = s.replace(self.context, "<context>")
        for name in sorted(self.nodes, key=len, reverse=True):
            s = s.replace(name, self.nodes[name])
        for lit in self.extra:
            s = s.replace(lit, "<redacted>")
        s = INTERNAL_DOMAIN_RE.sub("<internal-host>", s)
        s = IPV4_RE.sub("<ip>", s)
        s = IPV6_RE.sub(lambda m: "<ip6>" if ("::" in m.group(0) or m.group(0).count(":") >= 3) else m.group(0), s)
        s = MAC_RE.sub("<mac>", s)
        s = HOME_RE.sub("/home/<user>", s)
        return s

    def leaks(self, s):
        """Residual identifiers in already-sanitized text (reasons only, never the values)."""
        found = []
        if any(n in s for n in self.nodes):
            found.append("node name")
        if any(e in s for e in self.extra):
            found.append("extra literal")
        if self.context and self.context in s:
            found.append("context name")
        for label, rx in (("ipv4", IPV4_RE), ("apiserver", APISERVER_RE), ("internal domain", INTERNAL_DOMAIN_RE),
                          ("private key", PRIVKEY_RE), ("mac", MAC_RE)):
            if rx.search(s):
                found.append(label)
        if any(rx.search(s) for rx in TOKEN_RES):
            found.append("token")
        if re.search(r"(?m)^[^\n]*(?:password|passwd)\s*[:=]\s*(?!<redacted)\S", s, re.I):
            found.append("password")
        return found


class Evidence:
    """Write sanitized evidence under experiments/exp-005-rwx/evidence/<run id>/. Raw text never reaches disk."""

    def __init__(self, base_dir, run_id, sanitizer, enabled=True):
        self.dir = os.path.join(base_dir, valid_run_id(run_id))
        self.san = sanitizer
        self.enabled = enabled
        self.withheld = []
        if enabled:
            os.makedirs(os.path.join(self.dir, "raw"), exist_ok=True)

    def write(self, name, text):
        if not self.enabled:
            return None
        if os.path.isabs(name) or ".." in name.split("/"):
            raise Refused(f"bad evidence name {name!r}")
        clean = self.san.text(text if isinstance(text, str) else json.dumps(text, indent=1, sort_keys=True))
        leaks = self.san.leaks(clean)
        path = os.path.join(self.dir, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if leaks:
            self.withheld.append((name, leaks))
            with open(path + ".WITHHELD", "w") as fh:
                fh.write("withheld by the sanitizer: residual " + ", ".join(leaks) + "\n")
            return None
        with open(path, "w") as fh:
            fh.write(clean if clean.endswith("\n") else clean + "\n")
        return path


class Results:
    STATUSES = ("PASS", "FAIL", "INFO", "LIMITATION", "BLOCKED", "SKIP", "UNTESTED")

    def __init__(self, echo=log):
        self.rows = []
        self.echo = echo

    def rec(self, test, status, detail=""):
        if status not in self.STATUSES:
            raise ValueError(status)
        self.rows.append((test, status, detail))
        self.echo(f"{test} {status} {detail}")

    def tsv(self):
        return "test\tstatus\tdetail\n" + "".join(f"{t}\t{s}\t{d}\n" for t, s, d in self.rows)

    def counts(self):
        c = {}
        for _, s, _ in self.rows:
            c[s] = c.get(s, 0) + 1
        return c

    def failed(self):
        return [t for t, s, _ in self.rows if s == "FAIL"]


def default_evidence_dir():
    return os.path.join(EXP_DIR, "evidence")


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "herdrnetes-exp005-rwx")


def now_s():
    return time.monotonic()
