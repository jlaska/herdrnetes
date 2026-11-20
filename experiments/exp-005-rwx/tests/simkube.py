"""Shared offline simulator for the scenario and fail-closed tests (EXP-005-RWX). Not a test module.

SimKube keeps every real guard of rwxlib.Kube (validation, label guard, allow-list, tri-state classification) and replaces
only the final `kubectl` call: `exec` runs the probe/git/request-repo locally under a temp directory standing in for /rwx,
and get/apply/delete are answered from a small in-memory model of the cluster. Failure injection:
  kube.fail[<substring of the kubectl command line>] = CmdResult | Exception   (checked first, for reads and mutations)
  kube.patch[(pod, probe-subcommand)] = callable(obj) -> obj | None             (rewrite/garble a probe's JSON result)
All git invocations are hermetic (GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1); no signing key is ever touched.
"""
import ctypes
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

HARNESS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "harness")
sys.path.insert(0, HARNESS)
import rwxlib as L  # noqa: E402
import scenarios as S  # noqa: E402

RUN = "20261119a"
NS = L.namespace_for(RUN)
GENV = dict(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
NODES = ["node-x1", "node-x2", "node-x3"]       # node-x3 runs the live Herdr pod
HERDR_NS = "herdrnetes-exp"
PV = "pvc-11111111-2222-3333-4444-555555555555"
NOON = lambda: datetime(2026, 11, 19, 12, 0, tzinfo=timezone.utc)  # noqa: E731  outside the maintenance window
NOT_FOUND = L.CmdResult(1, "", 'Error from server (NotFound): not found')


def no_new_privs():
    ctypes.CDLL(None).prctl(38, 1, 0, 0, 0)     # PR_SET_NO_NEW_PRIVS: lets local probes report what a restricted pod reports


def jload(path):
    with open(path) as fh:
        return json.load(fh)


def obj(kind, name, **extra):
    o = {"apiVersion": "v1", "kind": kind, "metadata": {"name": name}}
    o.update(extra)
    return o


def lst(items):
    return {"apiVersion": "v1", "kind": "List", "items": items}


class SimKube(L.Kube):
    def __init__(self, root, node_b="node-x2", herdr_uid="herdr-uid-1", **kw):
        super().__init__("ctx-sim", RUN, live=True, execute=True, echo=lambda *_: None)
        self.root, self.nodes_ab, self.herdr_uid = root, {"rwx-a": "node-x1", "rwx-b": node_b}, herdr_uid
        self.pods, self.pvc, self.ns_exists, self.holders, self.mutations, self.herdr_flip_after = {}, False, False, {}, [], None
        self.netpol = False
        self.generation = 0
        self.nodes_list, self.node_flags, self.manager_tag = list(NODES), {}, "v1.13.0"
        self.crds = ["talosupgrades.tuppr.example", "kubernetesupgrades.tuppr.example"]   # both observed in PREFLIGHT.md
        self.crs = ["Completed"]
        self.hang_after, self.stuck_pod, self.terminated_after = None, None, None
        self.herdr_pods = 1
        self.exec_count = 0
        self.fail, self.fail_post, self.patch = {}, {}, {}      # fail_post applies only after the namespace was deleted (verification)
        self.ns_deleted = False
        self.mounts = {}                         # pod -> dict(fstype=, vers=, source=) overriding the faked NFS mountinfo
        self.leftover = set()                    # cleanup items that survive namespace deletion: 'pv','volume','sm-pod','sm-cr','svc','va'

    # -- cluster model
    def lab(self):
        return {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: RUN}

    def pod_obj(self, name):
        n = self.pods[name]
        return obj("Pod", name, metadata={"name": name, "namespace": NS, "uid": f"uid-{name}-{n}", "labels": self.lab()},
                   spec={"nodeName": self.nodes_ab[name]},
                   status={"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                           "containerStatuses": [{"name": "ws", "restartCount": 0, "state": self.pod_state(name)}]})

    def pod_state(self, name):
        if name == "rwx-a" and self.terminated_after is not None and self.exec_count > self.terminated_after:
            return {"terminated": {"exitCode": 137}}
        return {"running": {}}

    def herdr_obj(self):
        uid = self.herdr_uid if not (self.herdr_flip_after is not None and self.exec_count > self.herdr_flip_after) else "CHANGED"
        return obj("Pod", "herdr-0", metadata={"name": "herdr-0", "uid": uid, "ownerReferences": [{"kind": "StatefulSet", "name": "herdr"}]},
                   spec={"nodeName": "node-x3"},
                   status={"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                           "containerStatuses": [{"name": "herdr", "restartCount": 0, "imageID": "img"}]})

    def volume_present(self):
        return self.pvc or "volume" in self.leftover

    def vols(self):
        items = [obj("Volume", "pvc-other", status={"state": "attached", "robustness": "healthy"})]
        if self.volume_present():
            items.append(obj("Volume", PV, spec={"accessMode": "rwx", "numberOfReplicas": 3},
                             status={"state": "attached", "robustness": "healthy", "kubernetesStatus": {"namespace": NS}}))
        return items

    def sm_present(self):
        return (self.pvc and "rwx-a" in self.pods) or "sm-pod" in self.leftover

    def jr(self, o):
        return L.CmdResult(0, json.dumps(o), "")

    def get(self, a):
        """a: list after the 'get' verb, '-o json' removed."""
        kind = a[0]
        name = a[1] if len(a) > 1 and not a[1].startswith("-") else None
        if kind == "namespace" and name == HERDR_NS:
            return self.jr(obj("Namespace", HERDR_NS))
        if kind == "namespace":
            return self.jr(obj("Namespace", NS, metadata={"name": NS, "labels": self.lab()})) if self.ns_exists else NOT_FOUND
        if kind == "nodes":
            return self.jr(lst([obj("Node", n, spec={"unschedulable": self.node_flags.get(n) == "cordoned"},
                                    status={"conditions": [{"type": "Ready", "status": "False" if self.node_flags.get(n) == "notready" else "True"}],
                                            "nodeInfo": {"kubeletVersion": "v1.36.6", "osImage": "Talos", "kernelVersion": "6.18"}})
                                for n in self.nodes_list]))
        if kind == "crd":
            return self.jr(lst([obj("CustomResourceDefinition", n) for n in self.crds]))
        if kind in self.crds:
            return self.jr(lst([obj("TalosUpgrade", "x", status={"phase": ph} if ph is not None else {}) for ph in self.crs]))
        if kind == "storageclass":
            return self.jr(obj("StorageClass", "longhorn", provisioner="driver.longhorn.io", reclaimPolicy="Delete",
                               volumeBindingMode="Immediate", parameters={"numberOfReplicas": "3"}))
        if kind == "csidriver":
            return self.jr(obj("CSIDriver", "driver.longhorn.io", spec={"fsGroupPolicy": "ReadWriteOnceWithFSType", "attachRequired": True}))
        if kind == "volumes.longhorn.io":
            if name:
                v = [i for i in self.vols() if i["metadata"]["name"] == name]
                return self.jr(v[0]) if v else NOT_FOUND
            return self.jr(lst(self.vols()))
        if kind == "nodes.longhorn.io":
            return self.jr(lst([obj("Node", n, status={"conditions": [{"type": "Ready", "status": "True"},
                                                                       {"type": "Schedulable", "status": "True"}]}) for n in NODES]))
        if kind == "sharemanagers.longhorn.io":
            if not name:
                return self.jr(lst([]))
            if self.sm_present() and name == PV:
                return self.jr(obj("ShareManager", PV, status={"state": "running", "ownerID": "n", "endpoint": "nfs://x"}))
            return NOT_FOUND
        if kind == "settings.longhorn.io":
            return self.jr(obj("Setting", name, value="false"))
        if kind == "pods" and "app.kubernetes.io/name=herdr" in a:
            return self.jr(lst([self.herdr_obj()] * self.herdr_pods))
        if kind == "pods" and "-l" in a:
            if self.sm_present():
                return self.jr(lst([self.sm_pod()]))
            return self.jr(lst([]))
        if kind == "pods":
            return self.jr(lst([obj("Pod", "longhorn-manager-abc", status={"phase": "Running"},
                                    spec={"containers": [{"name": "longhorn-manager", "image": f"longhornio/longhorn-manager:{self.manager_tag}"}]})]))
        if kind == "pod" and name == f"share-manager-{PV}":
            return self.jr(self.sm_pod()) if self.sm_present() else NOT_FOUND
        if kind == "service":
            return self.jr(obj("Service", name)) if (self.sm_present() and name == PV) or "svc" in self.leftover else NOT_FOUND
        if kind in ("engines.longhorn.io", "replicas.longhorn.io"):
            n = 1 if kind.startswith("eng") else 3
            return self.jr(lst([obj("Replica", f"r{i}", spec={"nodeID": "node-x1"}) for i in range(n)] if self.volume_present() else []))
        if kind == "volumeattachments.storage.k8s.io":
            return self.jr(lst([obj("VolumeAttachment", "va1", spec={"source": {"persistentVolumeName": PV}})]
                               if (self.pvc or "va" in self.leftover) else []))
        if kind == "pv" and name:
            return self.jr(obj("PersistentVolume", name)) if (self.pvc or "pv" in self.leftover) and name == PV else NOT_FOUND
        if kind == "pv":
            return self.jr(lst([obj("PersistentVolume", PV, spec={"claimRef": {"namespace": NS, "name": L.PVC_NAME}})]
                               if (self.pvc or "pv" in self.leftover) else []))
        if kind == "networkpolicy" and name:
            return self.jr(obj("NetworkPolicy", name, metadata={"name": name, "namespace": NS, "labels": self.lab()})) if self.netpol else NOT_FOUND
        if kind == "pod" and name == "herdr-0":
            return self.jr(self.herdr_obj())
        if kind == "pod" and name in self.pods:
            return self.jr(self.pod_obj(name))
        if kind in ("pvc", "persistentvolumeclaim") and self.pvc:
            return self.jr(obj("PersistentVolumeClaim", L.PVC_NAME, metadata={"name": L.PVC_NAME, "namespace": NS, "labels": self.lab()},
                               spec={"volumeName": PV}, status={"phase": "Bound"}))
        if kind.startswith("pvc,pod"):
            items = [obj("Pod", n, metadata={"name": n, "labels": self.lab()}) for n in self.pods]
            if self.pvc:
                items.append(obj("PersistentVolumeClaim", L.PVC_NAME, metadata={"name": L.PVC_NAME, "labels": self.lab()}))
            if self.netpol:
                items.append(obj("NetworkPolicy", "default-deny-all", metadata={"name": "default-deny-all", "labels": self.lab()}))
            return self.jr(lst(items))
        if kind == "events":
            return self.jr(lst([]))
        return NOT_FOUND

    def sm_pod(self):
        return obj("Pod", f"share-manager-{PV}", metadata={"name": f"share-manager-{PV}", "uid": "sm-uid"},
                   spec={"nodeName": "node-x3", "containers": [{"image": "longhornio/longhorn-share-manager:v1.13.0"}]},
                   status={"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                           "containerStatuses": [{"restartCount": 0, "imageID": "sha256:abc"}]})

    # -- the only thing replaced: the final kubectl call
    def _go(self, argv, mutating, input=None, timeout=None):
        self.trace.append(" ".join(argv))
        line = " ".join(argv)
        active = dict(self.fail)
        if self.ns_deleted:
            active.update(self.fail_post)
        for key, res in active.items():
            if key in line:
                if callable(res) and not isinstance(res, BaseException):
                    res = res()
                if isinstance(res, BaseException):
                    raise res
                return res
        i = 3 if argv[1] == "--context" else 1
        rest = argv[i:]
        if rest[0] == "-n":
            rest = rest[2:]
        verb = rest[0]
        if verb == "config":
            return L.CmdResult(0, "ctx-sim\n", "")
        if verb == "version":
            return L.CmdResult(0, json.dumps({"serverVersion": {"gitVersion": "v1.36.6"}}), "")
        if verb == "auth":
            return L.CmdResult(0, "yes\n", "")
        if verb in ("describe",) or (verb == "get" and "-o" in rest and rest[rest.index("-o") + 1] in ("wide", "yaml")):
            return L.CmdResult(0, "text", "")
        if verb == "get":
            a = [x for x in rest[1:] if x not in ("-o", "json")]
            return self.get(a)
        if verb == "apply":
            self.mutations.append(("apply", input.count("kind:")))
            for kind, name in re_docs(input):
                if kind == "Namespace":
                    self.ns_exists = True
                elif kind == "PersistentVolumeClaim":
                    self.pvc = True
                elif kind == "NetworkPolicy":
                    self.netpol = True
                elif kind == "Pod":
                    self.generation += 1
                    self.pods[name] = self.generation
            return L.CmdResult(0, "applied", "")
        if verb == "delete":
            kind, name = rest[1], rest[2]
            self.mutations.append(("delete", kind, name))
            if kind == "pod" and name == self.stuck_pod:
                return L.CmdResult(1, "", "error: timed out waiting for the condition on pods/" + name)
            if kind == "pod":
                self.pods.pop(name, None)
                for p in self.holders.pop(name, []):
                    p.kill()
            elif kind == "persistentvolumeclaim":
                self.pvc = False
            elif kind == "networkpolicy":
                self.netpol = False
            elif kind == "namespace":
                for plist in self.holders.values():
                    for p in plist:
                        p.kill()
                self.holders.clear()
                self.ns_deleted = True
                self.ns_exists = False
                self.pods.clear()
                self.pvc = False
                self.netpol = False
            return L.CmdResult(0, "deleted", "")
        if verb == "exec":
            return self.do_exec(rest, input, timeout)
        raise AssertionError(f"unsimulated kubectl: {rest}")

    # -- local execution standing in for `kubectl exec`
    def local_cmd(self, cmd):
        """cmd after '--'. Returns (argv, env)."""
        env = dict(os.environ, **GENV)
        if cmd[0] == "env":
            i = 1
            while "=" in cmd[i]:
                k, v = cmd[i].split("=", 1)
                env[k] = v
                i += 1
            cmd = cmd[i:]
        cmd = [sys.executable if c == "python3" else c for c in cmd]
        return cmd, env

    def fake_mount(self, pod, o):
        m = dict(fstype="nfs4", vers="4.1", source="svc-share:/pvc-1")
        m.update(self.mounts.get(pod, {}))
        o["mount"] = dict(mount_point=L.MOUNT, mount_options="rw", fstype=m["fstype"], source=m["source"], super_options="rw")
        opts = {"hard": True, "proto": "tcp"}
        if m.get("vers"):
            opts["vers"] = m["vers"]
        o["nfs_options"] = opts
        return o

    def do_exec(self, rest, input, timeout):
        self.exec_count += 1
        pod = rest[rest.index("-c") - 1]
        if self.hang_after is not None and self.exec_count > self.hang_after:
            return L.CmdResult(124, "", f"timeout after {timeout}s")
        if pod not in self.pods:
            return L.CmdResult(1, "", f'pods "{pod}" not found')
        cmd, env = self.local_cmd(rest[rest.index("--") + 1:])
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                             preexec_fn=no_new_privs)
        self.holders.setdefault(pod, []).append(p)       # like a real pod: deleting it ends everything exec'd in it
        if pod not in self.pods:                         # pod deleted while this exec was starting (worker thread race)
            p.kill()
        out, err = p.communicate(input, timeout=timeout)
        sub = cmd[3] if len(cmd) > 3 and cmd[1:3] == ["-I", "-"] else None
        if sub in ("mountinfo", "writegate", "identity"):
            o = L.parse_probe_output(out)
            if sub == "mountinfo":
                o = self.fake_mount(pod, o)
            elif sub == "identity":
                o.update(uid=1000, gid=1000)                       # the simulated pod runs as 1000:1000
            elif sub == "writegate":
                o.update(uid=1000, gid=1000)
                o.get("root_stat", {}).update(uid=1000, gid=1000)
                if "owner_is_caller" in o.get("steps", {}):
                    o["steps"]["owner_is_caller"].update(file_uid=1000, file_gid=1000)
            fn = self.patch.get((pod, sub))
            if fn is not None:
                o = fn(o)
            out = "garbled{" if o is None else json.dumps(o) + "\n"
        return L.CmdResult(p.returncode, out, err)

    def popen_exec(self, pod, cmd, stdin=None):
        self.trace.append(f"popen {pod} {cmd[:4]}")
        argv, env = self.local_cmd([str(c) for c in cmd])
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                             preexec_fn=no_new_privs)
        p.stdin.write(stdin)
        p.stdin.close()
        self.holders.setdefault(pod, []).append(p)
        return p


def re_docs(text):
    for doc in L.split_docs(text):
        kind = re.search(r"(?m)^kind:\s*(\S+)", doc).group(1)
        name = re.search(r"(?m)^  name:\s*(\S+)", doc).group(1)
        yield kind, name


class SimBase(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.tmp = os.path.realpath(self._td.name)
        self.root = os.path.join(self.tmp, "rwx")
        self.local = os.path.join(self.tmp, "emptydir")
        os.makedirs(self.root)
        os.makedirs(self.local)
        self.saved = (L.MOUNT, L.WORK, S.SRC, S.WS, S.LOCAL_TMP, S.BIG_FILES, S.BIG_COMMITS, S.PERF_RUNS, S.HEARTBEAT_S, S.LOCK_HOLD_S)
        L.MOUNT, L.WORK = self.root, self.root + "/work"
        S.SRC, S.WS, S.LOCAL_TMP = L.WORK + "/sources", L.WORK + "/ws", self.local
        S.BIG_FILES, S.BIG_COMMITS, S.PERF_RUNS, S.HEARTBEAT_S, S.LOCK_HOLD_S = 60, 3, 1, 4, 5
        self.addCleanup(self.restore)

    def restore(self):
        L.MOUNT, L.WORK, S.SRC, S.WS, S.LOCAL_TMP, S.BIG_FILES, S.BIG_COMMITS, S.PERF_RUNS, S.HEARTBEAT_S, S.LOCK_HOLD_S = self.saved

    def runner(self, setup=None, clock=NOON, **kw):
        kube = SimKube(self.root, **kw)
        if setup:
            setup(kube)
        san = L.Sanitizer()
        ev = L.Evidence(os.path.join(self.tmp, "evidence"), RUN, san)
        res = L.Results(echo=lambda *_: None)
        r = S.Runner(kube, ev, san, res, clock=clock, sleep=lambda *_: None)
        return r, kube, res, ev
