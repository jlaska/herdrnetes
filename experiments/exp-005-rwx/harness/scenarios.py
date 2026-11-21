"""EXP-005-RWX orchestration of R00-R14 (issue #32). Workstation side; talks to the cluster only through rwxlib.Kube.

A Runner owns one run. Mutations happen only in create_resources(), r12 (delete/recreate of ONE scratch pod) and
cleanup(); everything else is read-only kubectl or `kubectl exec` into the two scratch pods.
Stop conditions raise StopRun; run() then collects evidence and runs the guarded cleanup. There is deliberately
no code path that escalates privileges, relaxes Pod Security, changes a StorageClass/Longhorn setting or force-deletes.
"""
import concurrent.futures as cf
from datetime import datetime, timezone
import hashlib
import json
import os
import queue
import subprocess
import threading
import time

import podprobe
import rwxlib as L
from rwxlib import ABSENT, PODS, PRESENT, UNKNOWN, StopRun, Tri, log

PROBE_PATH = os.path.join(L.HERE, "podprobe.py")
REQUEST_REPO_PATH = os.path.join(L.REPO_ROOT, "experiments", "exp-005", "harness", "request-repo")
SRC = f"{L.WORK}/sources"
WS = f"{L.WORK}/ws"
BIG_FILES, BIG_COMMITS, PERF_RUNS = 3000, 5, 5
LOCAL_TMP = "/tmp"          # emptyDir inside the pods (control for R07/R11)
HEARTBEAT_S, LOCK_HOLD_S = 150, 14


def wait_until(fn, timeout, interval=2.0):
    t0 = time.monotonic()
    while True:
        v = fn()
        if v:
            return v, time.monotonic() - t0
        if time.monotonic() - t0 > timeout:
            return None, time.monotonic() - t0
        time.sleep(interval)


def pod_ready(pj):
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in (pj or {}).get("status", {}).get("conditions", []))


def inventory_from(json_obj):
    return [dict(kind=i["kind"], name=i["metadata"]["name"], labels=i["metadata"].get("labels") or {})
            for i in (json_obj or {}).get("items", [])]


INV_KINDS = ("pvc,pod,statefulset,deployment,replicaset,daemonset,job,cronjob,configmap,networkpolicy,service,"
             "serviceaccount,role,rolebinding,ingress,resourcequota,limitrange")


class Runner:
    def __init__(self, kube, evidence, sanitizer, results, network_policy=True, node_selector=None,
                 herdr_ns=L.DEFAULT_HERDR_NS, herdr_pod=L.DEFAULT_HERDR_POD, sleep=time.sleep,
                 expect_longhorn=L.DEFAULT_EXPECT_LONGHORN, clock=None):
        self.kube, self.ev, self.san, self.res = kube, evidence, sanitizer, results
        self.run_id, self.ns = kube.run_id, kube.ns
        self.network_policy, self.node_selector = network_policy, node_selector or {}
        self.herdr_ns, self.herdr_pod = herdr_ns, herdr_pod
        self.sleep = sleep
        self.expect_longhorn = expect_longhorn
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        self.herdr_node = None
        self.base_herdr = self.base_vols = None
        self.pv = None                       # also the Longhorn volume name
        self.nodes = {}
        self.observations = []
        self.rr_log = []
        self.timings = []
        self.created = False
        with open(PROBE_PATH) as fh:
            self.probe_src = fh.read()
        self.rr_src = ""
        if os.path.exists(REQUEST_REPO_PATH):
            with open(REQUEST_REPO_PATH) as fh:
                self.rr_src = fh.read()

    # ------------------------------------------------------------------ plumbing
    def tim(self, step, seconds):
        self.timings.append((step, round(seconds, 2)))

    def px(self, which, sub, *args, timeout=300, label=None):
        r = self.kube.exec(PODS[which], ["python3", "-I", "-", sub, *map(str, args)], stdin=self.probe_src,
                           timeout=timeout)
        out = L.parse_probe_output(r.out)
        out["_rc"] = r.rc
        if r.rc != 0:
            out["_stderr"] = r.err.strip()[-400:]
        if label:
            self.ev.write(f"raw/{label}.json", out)
        return out

    def rr(self, which, rid, source, pause=None, label=None, timeout=900):
        env = [f"WORKSPACE_ROOT={WS}"] + ([f"REQUEST_REPO_TEST_PAUSE_AFTER_CLONE={pause}"] if pause else [])
        r = self.kube.exec(PODS[which], ["env", *env, "python3", "-I", "-", "--timeout", "600", rid, source],
                           stdin=self.rr_src, timeout=timeout)
        out = L.parse_probe_output(r.out)
        out["_rc"] = r.rc
        self.rr_log.append(out)
        if label:
            self.ev.write(f"raw/{label}.json", out)
        return out

    def gitx(self, which, repo, *args, timeout=300):
        env = [f"{k}={v}" for k, v in podprobe.GIT_ENV.items()]
        return self.kube.exec(PODS[which], ["env", *env, "git", "-C", repo, *args], timeout=timeout)

    def par(self, *fns):
        """Run callables concurrently. The first exception (for example HangSuspected) is raised at once: we do not wait for
        the other workers, whose kubectl exec sessions end when the guarded cleanup deletes the pods (never forced)."""
        ex = cf.ThreadPoolExecutor(max_workers=max(len(fns), 1))
        futs = [ex.submit(f) for f in fns]
        cf.wait(futs, return_when=cf.FIRST_EXCEPTION)
        for f in futs:
            if f.done() and f.exception() is not None:
                ex.shutdown(wait=False, cancel_futures=True)
                raise f.exception()
        results = [f.result() for f in futs]
        ex.shutdown(wait=True)
        return results

    def rj(self, args, **kw):
        return self.kube.read_json(args, **kw)

    def stop(self, test, reason):
        self.res.rec(test, "FAIL", f"STOP: {reason}")
        raise StopRun(f"{test}: {reason}")

    # ------------------------------------------------------------------ read-only observation
    def need(self, label, what, args, kind=None, name=None, is_list=False, allow_empty=True, **kw):
        """Fail-closed read: returns parsed data, or STOPs. An UNKNOWN answer (error, timeout, empty/malformed output, wrong
        schema) is never treated as 'empty', 'healthy' or 'unchanged'. ABSENT is acceptable only for an empty list."""
        t = self.kube.read_state(args, kind=kind, name=name, is_list=is_list, **kw)
        if t.state == L.UNKNOWN:
            self.stop(label, f"{what} unreadable: {t.reason}")
        if t.state == L.ABSENT:
            if is_list and allow_empty:
                return {"items": []}
            self.stop(label, f"{what} not found or empty ({t.reason})")
        return t.data

    def herdr_now(self):
        """UID/restarts of the live Herdr pod, or None if it could not be positively read."""
        t = self.kube.read_state(["get", "pod", self.herdr_pod], kind="Pod", name=self.herdr_pod, ns=False, namespace=self.herdr_ns)
        return L.herdr_facts(t.data) if t.state == L.PRESENT else None

    def vols_now(self):
        """name -> (state, robustness) of every Longhorn volume, or None if the inventory could not be positively read."""
        t = self.kube.read_state(["get", "volumes.longhorn.io"], is_list=True, ns=False, namespace=L.LONGHORN_NS)
        if t.state == L.UNKNOWN:
            return None
        try:
            return L.longhorn_volume_states(t.data or {"items": []})
        except (ValueError, KeyError, TypeError):
            return None

    def disk_pct(self):
        d = self.px("a", "df", L.MOUNT)
        pct = d.get("used_pct")
        return pct if isinstance(pct, (int, float)) else None

    def check_environment(self, label):
        """Maintenance-window, node-health and upgrade-controller guards (read-only, fail closed). Returns the nodes JSON."""
        now = self.clock()
        if L.in_maintenance_window(now):
            self.stop(label, f"UTC {now:%H:%M} is inside the maintenance window {L.MAINT_WINDOW[0]}-{L.MAINT_WINDOW[1]} "
                             "(upgrade controller window; node restarts expected)")
        nodes = self.need(label, "node list", ["get", "nodes"], is_list=True, allow_empty=False, ns=False)
        stops = L.node_health_stops(nodes)
        # CRD absence is acceptable only when the CRD listing itself succeeded and shows it absent
        crds = self.need(label, "CRD list", ["get", "crd"], is_list=True, ns=False)
        missing = L.missing_upgrade_crds(crds)
        if missing:        # PREFLIGHT.md observed both CRDs; a CRD list lacking them means upgrade state is unavailable, not idle
            self.stop(label, f"upgrade controller state unavailable: CRD(s) for {missing} not found in a successfully read CRD list")
        crs = []
        for crd in L.upgrade_crd_names(crds):
            j = self.need(label, f"upgrade CR list {crd}", ["get", crd, "-A"], is_list=True, ns=False)
            if not j["items"]:     # PREFLIGHT.md: both upgrade objects exist (Completed); an empty list is not the observed normal state
                self.stop(label, f"upgrade controller state unavailable: no {crd} object (expected one, observed Completed in PREFLIGHT.md)")
            crs += [(crd, (i.get("metadata") or {}).get("name", "?"), (i.get("status") or {}).get("phase")) for i in j["items"]]
        self._upgrade_crs_seen = sorted({c[0] for c in crs})
        self._upgrade_phases = sorted({f"{c[0].split('.')[0]}={c[2]}" for c in crs})
        stops += L.upgrade_stops(crs)
        if stops:
            self.stop(label, "; ".join(stops))
        return nodes

    def check_scratch_pods(self, label):
        for w in ("a", "b"):
            if self.nodes.get(w):
                t = self.kube.read_state(["get", "pod", PODS[w]], kind="Pod", name=PODS[w])
                stops = L.scratch_pod_stops(t.data if t.state == L.PRESENT else {"__error__": t.reason}, PODS[w])
                if stops:
                    self.stop(label, "; ".join(stops))

    def check_global(self, label):
        self.check_environment(label)
        self.check_scratch_pods(label)
        stops, infos = L.check_invariants(self.base_herdr, self.herdr_now(), self.base_vols, self.vols_now(),
                                          scratch_volume=self.pv, nodes_a_b=(self.nodes.get("a"), self.nodes.get("b")))
        for i in infos:
            self.res.rec(f"{label}/inv", "INFO", i)
        if stops:
            self.stop(label, "; ".join(stops))
        if self.created and self.nodes.get("a"):
            pct = self.disk_pct()
            if pct is None:
                self.stop(label, "scratch volume usage unreadable (df probe failed)")
            if pct >= L.DISK_STOP_PCT:
                self.stop(label, f"scratch volume {pct}% full (limit {L.DISK_STOP_PCT}%)")

    def share_manager_state(self):
        """Read-only Longhorn objects of the scratch volume. `unknown` lists every read that could not be positively
        established; callers must treat a non-empty `unknown` as a failed observation, never as 'absent'."""
        if not self.pv:
            return {}
        lh = dict(ns=False, namespace=L.LONGHORN_NS)
        rs = self.kube.read_state
        pods = rs(["get", "pods", "-l", f"longhorn.io/share-manager={self.pv}"], is_list=True, **lh)
        sm = rs(["get", "sharemanagers.longhorn.io", self.pv], kind="ShareManager", name=self.pv, **lh)
        svc = rs(["get", "service", self.pv], kind="Service", name=self.pv, **lh)
        vol = rs(["get", "volumes.longhorn.io", self.pv], kind="Volume", name=self.pv, **lh)
        eng = rs(["get", "engines.longhorn.io", "-l", f"longhornvolume={self.pv}"], is_list=True, **lh)
        rep = rs(["get", "replicas.longhorn.io", "-l", f"longhornvolume={self.pv}"], is_list=True, **lh)
        unknown = [f"{n}: {t.reason}" for n, t in (("share-manager pods", pods), ("ShareManager CR", sm), ("Service", svc),
                                                   ("Longhorn volume", vol), ("engines", eng), ("replicas", rep))
                   if t.state == L.UNKNOWN]
        if vol.state == L.ABSENT:
            unknown.append("Longhorn volume: absent although the PVC is bound")
        items = lambda t: (t.data or {}).get("items", [])  # noqa: E731
        smp = [dict(name=p["metadata"]["name"], uid=p["metadata"]["uid"], phase=p["status"].get("phase"),
                    node=p["spec"].get("nodeName"), ready=pod_ready(p),
                    image=[c.get("image") for c in p["spec"].get("containers", [])],
                    image_id=[c.get("imageID") for c in p["status"].get("containerStatuses", [])],
                    restarts=sum(c.get("restartCount", 0) for c in p["status"].get("containerStatuses", [])))
               for p in items(pods)]
        replica_nodes = sorted(self.san.alias(r.get("spec", {}).get("nodeID") or "?") for r in items(rep))
        vd = vol.data or {}
        vs = vd.get("status", {})
        smd = sm.data or {}
        return dict(unknown=unknown, share_manager_pods=smp,
                    sharemanager_cr=None if sm.state != L.PRESENT else dict(
                        state=smd.get("status", {}).get("state"), owner=smd.get("status", {}).get("ownerID"),
                        endpoint_present=bool(smd.get("status", {}).get("endpoint"))),
                    service_present=svc.state == L.PRESENT,
                    volume=dict(state=vs.get("state"), robustness=vs.get("robustness"),
                                access_mode=(vd.get("spec", {}) or {}).get("accessMode"),
                                replicas_requested=(vd.get("spec", {}) or {}).get("numberOfReplicas"),
                                kubernetes_ns=(vs.get("kubernetesStatus") or {}).get("namespace")),
                    engines=len(items(eng)), replicas=len(items(rep)), replica_nodes=replica_nodes)

    def scratch_facts(self):
        out = {}
        for w in ("a", "b"):
            t = self.kube.read_state(["get", "pod", PODS[w]], kind="Pod", name=PODS[w])
            if t.state == L.PRESENT:
                pj = t.data
                out[w] = dict(phase=pj["status"].get("phase"), uid=pj["metadata"].get("uid", "")[:8],
                              restarts={c["name"]: c.get("restartCount", 0) for c in pj["status"].get("containerStatuses", [])})
            else:
                out[w] = dict(unreadable=t.reason)
        return out

    def observe(self, label):
        o = self.share_manager_state()
        o["label"] = label
        o["scratch_pods"] = self.scratch_facts()
        o["herdr_restarts"] = (self.herdr_now() or {}).get("restarts")
        self.observations.append(o)
        self.ev.write(f"observe/{label}.json", o)
        bad = list(o.get("unknown", [])) + [f"scratch pod {w}: {v['unreadable']}" for w, v in o["scratch_pods"].items() if "unreadable" in v]
        if o["herdr_restarts"] is None:
            bad.append("live Herdr pod unreadable")
        if bad:
            self.stop("R13", f"observation {label} incomplete (fail closed): " + "; ".join(bad))
        return o

    # ------------------------------------------------------------------ R00
    def r00(self):
        t = "R00"
        ctxs = self.kube.read(["config", "get-contexts", "-o", "name"], ns=False)
        if ctxs.rc != 0 or self.kube.ctx not in ctxs.out.split():
            self.stop(t, "kube context unreadable or does not exist in kubeconfig")
        nodes = self.check_environment(t)     # maintenance window, node health, upgrade CRs (fail closed)
        vr = self.kube.read(["version", "-o", "json"], ns=False)
        ver = L.parse_probe_output(vr.out.replace("\n", " ")) if vr.rc == 0 else {}
        if not ver.get("serverVersion", {}).get("gitVersion"):
            self.stop(t, "kubernetes server version unreadable")
        for n in nodes["items"]:
            self.san.add_node(n["metadata"]["name"])
        # cluster identity guard: right Longhorn, right Herdr (STOP otherwise: wrong kube context)
        lpods = self.need(t, "longhorn-system pod list", ["get", "pods"], is_list=True, allow_empty=False, ns=False, namespace=L.LONGHORN_NS)
        tags = L.longhorn_manager_tags(lpods)
        herdr_ns_obj = self.need(t, f"Herdr namespace {self.herdr_ns}", ["get", "namespace", self.herdr_ns], kind="Namespace",
                                 name=self.herdr_ns, ns=False)
        herdr_pods = self.need(t, "Herdr pod list", ["get", "pods", "-l", L.HERDR_LABEL], is_list=True, allow_empty=False, ns=False,
                               namespace=self.herdr_ns)
        idstops = L.identity_stops(self.expect_longhorn, tags, herdr_ns_obj, herdr_pods, self.herdr_pod)
        if idstops:
            self.stop(t, "cluster identity: " + "; ".join(idstops))
        self.herdr_node = herdr_pods["items"][0]["spec"].get("nodeName")
        if not self.herdr_node:
            self.stop(t, "Herdr pod has no node assigned")
        self.san.add_node(self.herdr_node)
        cand = L.candidate_nodes(nodes, self.herdr_node)
        if len(cand) < 2:
            self.stop(t, f"need >= 2 Ready schedulable untainted nodes excluding the Herdr node, found {len(cand)}")
        ns_state = self.kube.read_state(["get", "namespace", self.ns], kind="Namespace", name=self.ns, ns=False)
        if ns_state.state != L.ABSENT:
            self.stop(t, f"namespace {self.ns} must be positively absent (state {ns_state.state}: {ns_state.reason or 'exists'})")
        sc = self.need(t, f"StorageClass {L.STORAGE_CLASS}", ["get", "storageclass", L.STORAGE_CLASS], kind="StorageClass",
                       name=L.STORAGE_CLASS, ns=False)
        if sc.get("provisioner") != "driver.longhorn.io":
            self.stop(t, f"StorageClass provisioner is {sc.get('provisioner')!r}, expected driver.longhorn.io")
        if sc.get("reclaimPolicy") != "Delete":
            self.stop(t, f"StorageClass reclaimPolicy is {sc.get('reclaimPolicy')!r}; a PV would outlive cleanup")
        csid = self.need(t, "CSIDriver driver.longhorn.io", ["get", "csidriver", "driver.longhorn.io"], kind="CSIDriver",
                         name="driver.longhorn.io", ns=False)
        vols = self.need(t, "Longhorn volume inventory", ["get", "volumes.longhorn.io"], is_list=True, allow_empty=False, ns=False,
                         namespace=L.LONGHORN_NS)
        try:
            self.base_vols = L.longhorn_volume_states(vols)
        except (ValueError, KeyError, TypeError) as e:
            self.stop(t, f"Longhorn volume inventory unparseable: {e}")
        bad = [n for n, (_, r) in self.base_vols.items() if r in L.BAD_ROBUSTNESS]
        if bad:
            self.stop(t, f"unhealthy Longhorn volumes present before the run: {bad}")
        notrun = [p["metadata"]["name"] for p in lpods["items"] if p.get("status", {}).get("phase") not in ("Running", "Succeeded")]
        if notrun:
            self.stop(t, f"longhorn-system pods not Running: {notrun}")
        lnodes = self.need(t, "Longhorn node list", ["get", "nodes.longhorn.io"], is_list=True, allow_empty=False, ns=False,
                           namespace=L.LONGHORN_NS)
        for n in lnodes["items"]:
            for cond in ("Ready", "Schedulable"):
                if _cond(n, cond) != "True":
                    self.stop(t, f"Longhorn node {self.san.alias(n['metadata']['name'])} condition {cond} is {_cond(n, cond)!r}")
            if _cond(n, "NFSClientInstalled") not in (None, "True"):
                self.stop(t, f"Longhorn node {self.san.alias(n['metadata']['name'])} NFSClientInstalled={_cond(n, 'NFSClientInstalled')!r}")
        existing_sm = self.need(t, "ShareManager list", ["get", "sharemanagers.longhorn.io"], is_list=True, ns=False, namespace=L.LONGHORN_NS)
        settings = {}
        for sname in ("rwx-volume-fast-failover", "storage-network", "storage-network-for-rwx-volume-enabled"):
            st = self.kube.read_state(["get", "settings.longhorn.io", sname], kind="Setting", name=sname, ns=False, namespace=L.LONGHORN_NS)
            if st.state == L.UNKNOWN or (st.state == L.ABSENT and sname == "rwx-volume-fast-failover"):
                self.stop(t, f"Longhorn setting {sname} unreadable or missing: {st.reason}")
            settings[sname] = (st.data or {}).get("value") if st.state == L.PRESENT else "not-present-in-this-version"
        can = {}
        for w in ("create namespaces", f"create persistentvolumeclaims -n {self.ns}", f"create pods -n {self.ns}", "delete namespaces"):
            r = self.kube.read(["auth", "can-i", *w.split()], ns=False)
            can[w] = r.out.strip()
            if can[w] != "yes":
                self.stop(t, f"permission check `{w}` did not return 'yes' ({can[w]!r}, rc={r.rc})")
        self.base_herdr = self.herdr_now()
        if not self.base_herdr:
            self.stop(t, "live Herdr pod baseline unreadable (read-only get failed)")
        hp = herdr_pods["items"][0]
        snap = dict(
            server_version=ver["serverVersion"]["gitVersion"],
            nodes=[dict(name=self.san.alias(n["metadata"]["name"]),
                        kubelet=n["status"]["nodeInfo"].get("kubeletVersion"), os=n["status"]["nodeInfo"].get("osImage"),
                        kernel=n["status"]["nodeInfo"].get("kernelVersion")) for n in nodes["items"]],
            storageclass=dict(provisioner=sc.get("provisioner"), reclaim=sc.get("reclaimPolicy"),
                              binding=sc.get("volumeBindingMode"), parameters=sc.get("parameters"),
                              allow_expansion=sc.get("allowVolumeExpansion")),
            csidriver=dict(fsGroupPolicy=csid.get("spec", {}).get("fsGroupPolicy"), attachRequired=csid.get("spec", {}).get("attachRequired")),
            longhorn=dict(volumes=len(self.base_vols), by_robustness=_count([r for _, r in self.base_vols.values()]),
                          nodes=[dict(ready=_cond(n, "Ready"), schedulable=_cond(n, "Schedulable"),
                                      nfs_client=_cond(n, "NFSClientInstalled")) for n in lnodes["items"]],
                          existing_share_managers=len(existing_sm["items"]), settings=settings, pods=len(lpods["items"])),
            auth=can,
            herdr=dict(uid_prefix=(self.base_herdr["uid"] or "")[:8], restarts=self.base_herdr["restarts"],
                       ready=pod_ready(hp), image_id=[c.get("imageID", "") for c in hp.get("status", {}).get("containerStatuses", [])]),
            identity=dict(expected_longhorn_manager_tag=self.expect_longhorn, observed_tags=tags, herdr_namespace=self.herdr_ns,
                          herdr_pod_count=len(herdr_pods["items"]), herdr_node=self.san.alias(self.herdr_node),
                          candidate_nodes_excluding_herdr=[self.san.alias(n) for n in cand],
                          utc_now=self.clock().strftime("%Y-%m-%dT%H:%MZ"),
                          maintenance_window_utc=[f"{h:02d}:{m:02d}" for h, m in L.MAINT_WINDOW],
                          upgrade_crds_checked=getattr(self, "_upgrade_crs_seen", []),
                          upgrade_cr_phases_observed=getattr(self, "_upgrade_phases", []),
                          idle_phases_accepted=list(L.UPGRADE_IDLE_PHASES)),
            scratch=dict(namespace=self.ns, image=L.IMAGE, network_policy=self.network_policy))
        self.ev.write("preflight.json", snap)
        self.res.rec(t, "PASS", f"read-only baseline captured: {len(cand)} candidate nodes, longhorn "
                                f"{snap['longhorn']['volumes']} volumes healthy, identity ok (longhorn-manager {tags}), class {L.STORAGE_CLASS} reclaim Delete, "
                                f"fsGroupPolicy={snap['csidriver']['fsGroupPolicy']}, upgrade CR phases {snap['identity']['upgrade_cr_phases_observed']}, "
                                "herdr baseline recorded")

    # ------------------------------------------------------------------ R01
    def create_resources(self):
        t = "R01"
        k = self.kube
        k.apply(L.render("namespace", self.run_id))
        self.created = True
        if self.network_policy:
            k.apply(L.render("networkpolicy", self.run_id))
        k.apply(L.render("pvc", self.run_id))
        pvc, dt = wait_until(lambda: (lambda j: j if j and j.get("status", {}).get("phase") == "Bound" else None)(
            self.rj(["get", "pvc", L.PVC_NAME])), L.TIMEOUTS["pvc_bound"])
        self.tim("pvc_bound", dt)
        if not pvc:
            self.collect("r01-pvc-not-bound")
            self.stop(t, f"PVC not Bound within {L.TIMEOUTS['pvc_bound']}s (class may reject RWX)")
        self.pv = pvc["spec"]["volumeName"]
        for which in ("a", "b"):
            k.apply(L.render_pod(self.run_id, which, self.node_selector, self.herdr_ns))
            pj, dt = wait_until(lambda w=which: (lambda j: j if pod_ready(j) else None)(self.rj(["get", "pod", PODS[w]])),
                                L.TIMEOUTS["pod_ready"])
            self.tim(f"pod_{which}_ready", dt)
            if not pj:
                self.collect(f"r01-pod-{which}-not-ready")
                self.stop(t, f"pod {PODS[which]} not Ready within {L.TIMEOUTS['pod_ready']}s")
            self.nodes[which] = pj["spec"]["nodeName"]
            self.san.add_node(self.nodes[which])
            if which == "a":
                sm, dt = wait_until(lambda: any(p["phase"] == "Running" and p["ready"]
                                                for p in self.share_manager_state().get("share_manager_pods", [])),
                                    L.TIMEOUTS["share_manager"])
                self.tim("share_manager_running_after_pod_a", dt)
                if not sm:
                    self.collect("r01-share-manager")
                    self.stop(t, f"share-manager not Running within {L.TIMEOUTS['share_manager']}s")
        if not L.pods_on_different_nodes(self.nodes["a"], self.nodes["b"]):
            self.collect("r01-same-node")
            self.stop(t, "pods landed on the same node")
        o = self.observe("after-create")
        v = o.get("volume", {})
        self.res.rec(t, "PASS", f"PVC Bound in {self.timings[0][1]}s (RWX), pods on different nodes "
                                f"({self.san.alias(self.nodes['a'])}, {self.san.alias(self.nodes['b'])}), share-manager "
                                f"Running, Longhorn volume accessMode={v.get('access_mode')} robustness={v.get('robustness')}")

    # ------------------------------------------------------------------ R02 (stop gate)
    def r02(self):
        """Positive filesystem/identity gate on BOTH pods. Nothing after R02 runs unless every assertion holds on both pods;
        unparseable probe output is a failure, never a pass. No remedy is attempted (no privilege change, no class change)."""
        t = "R02"
        per, problems = {}, []
        for w in ("a", "b"):
            per[w] = dict(identity=self.px(w, "identity", label=f"r02-identity-{w}"),
                          mount=self.px(w, "mountinfo", L.MOUNT, label=f"r02-mountinfo-{w}"),
                          gate=self.px(w, "writegate", L.MOUNT, label=f"r02-gate-{w}"))
            i_ok, i_why = L.evaluate_identity(per[w]["identity"])
            m_ok, m_why, mfacts = L.evaluate_mount(per[w]["mount"])
            g_ok, g_why = L.evaluate_gate(per[w]["gate"])
            for key, name, ok, why in (("identity", "identity/security", i_ok, i_why), ("nfsv4", "NFSv4 mount", m_ok, m_why),
                                       ("gate", "UID 1000 write + git smoke gate", g_ok, g_why)):
                self.res.rec(f"R02-{w}-{key}", "PASS" if ok else "FAIL", f"pod {w}: {name}: " + ("ok" if ok else "; ".join(why)))
                if not ok:
                    problems.append(f"pod {w} {name}: {'; '.join(why)}")
            per[w]["mfacts"] = mfacts
        if not problems:
            src = {w: per[w]["mfacts"].get("source") for w in per}
            if src["a"] != src["b"]:
                problems.append("the two pods are not mounted from the same NFS export (sources differ)")
        if problems:
            self.stop(t, "positive R02 gate failed (NOT escalating privileges, no workaround): " + " | ".join(problems))
        m = per["a"]["mount"]
        fsg = m.get("fsgroup_observation", {})
        self.res.rec("R02a", "INFO", f"mount a={per['a']['mfacts']} b={per['b']['mfacts']}")
        self.res.rec("R02b", "INFO", f"fsGroup 1000 applied to root gid? {fsg.get('applied')} (root gid={fsg.get('root_gid')}, "
                                     f"setgid={fsg.get('setgid_bit')}); root mode={oct(m['root_stat']['mode'])} "
                                     f"uid={m['root_stat']['uid']}")
        idt = per["a"]["identity"]
        self.res.rec("R02c", "INFO", f"groups={idt.get('groups')} seccomp={idt.get('seccomp')} (2 = filter, from RuntimeDefault)")
        mk = self.px("a", "mkwork", L.MOUNT, label="r02-mkwork")
        vis = self.px("b", "statinfo", L.WORK, label="r02-work-visible-from-b")
        if not (mk.get("ok") and vis.get(L.WORK)):
            self.stop(t, f"work tree created by A not visible from B (mkwork ok={mk.get('ok')}); not the same filesystem")
        self.res.rec(t, "PASS", "both pods: uid/gid 1000, NoNewPrivs, no capabilities; /rwx is an NFSv4.1+ mount of the same export; "
                                "files owned numerically by 1000; create/write/fsync/rename/mkdir/symlink/unlink and the non-root git "
                                "init/clone/commit/fsck smoke passed; work tree created by A visible from B")

    # ------------------------------------------------------------------ R03
    def pp(self, writer, reader, mode, kind, n, timeout):
        d = f"{L.WORK}/pp/{writer}{reader}-{kind}-{mode}"
        ra, rb = self.par(lambda: self.px(reader, "pingpong", "b", d, n, mode, kind, timeout, timeout=n * timeout + 120),
                          lambda: self.px(writer, "pingpong", "a", d, n, mode, kind, timeout, timeout=n * timeout + 120))
        return rb, ra   # (writer result, reader result)

    def r03(self):
        t = "R03"
        plan = [("open", "new", 20, 30), ("listdir", "new", 20, 30), ("open", "inplace", 20, 30), ("stat", "new", 3, 75)]
        for mode, kind, n, to in plan:
            for w, r in (("a", "b"), ("b", "a")):
                wres, rres = self.pp(w, r, mode, kind, n, to)
                self.ev.write(f"raw/r03-{w}{r}-{kind}-{mode}.json", dict(writer=wres, reader=rres))
                s = L.summarize(wres.get("rtt_ms", []))
                strict = mode != "stat"
                bad = wres.get("timeouts", 1) or rres.get("timeouts", 1) or rres.get("content_mismatch", 1)
                st = ("PASS" if not bad else "FAIL") if strict else "INFO"
                self.res.rec(f"{t}-{kind}-{mode}-{w}to{r}", st,
                             f"rtt_ms median={s.get('median')} max={s.get('max')} n={s.get('n')} timeouts="
                             f"{wres.get('timeouts')}/{rres.get('timeouts')} content_mismatch={rres.get('content_mismatch')}")
        self.res.rec(t, "INFO", "close-to-open visibility measured in both directions; see R03-* rows")

    # ------------------------------------------------------------------ R04
    def r04(self):
        t = "R04"
        mk = self.px("a", "mkrepo", SRC, "h1", 300, 5, timeout=900, label="r04-mkrepo-h1")
        t0 = time.monotonic()
        seen, _ = wait_until(lambda: self.px("b", "statinfo", f"{SRC}/h1.git/HEAD").get(f"{SRC}/h1.git/HEAD"), 60, 0.5)
        vis_s = time.monotonic() - t0
        r1 = self.rr("b", "h1", f"file://{SRC}/h1.git", label="r04-rr-b-first")
        r2 = self.rr("a", "h1", f"file://{SRC}/h1.git", label="r04-rr-a-second")
        ok = bool(seen) and r1.get("action") == "hydrated" and r2.get("action") == "already_ready" and r1.get("_rc") == 0
        self.res.rec("R04a", "PASS" if ok else "FAIL",
                     f"source from A visible to B after {vis_s:.1f}s (incl. exec overhead); B first request={r1.get('action')} "
                     f"(promotion={r1.get('promotion')}, {r1.get('duration_ms')}ms); A second request={r2.get('action')}")
        repo = f"{WS}/h1"
        lat, good = [], True
        for i in range(3):
            for w, o in (("b", "a"), ("a", "b")):
                c = self.px(w, "gitcommit", repo, w, i, label=f"r04-commit-{w}-{i}")
                if not c.get("ok"):
                    good = False
                    continue
                t1 = time.monotonic()
                seen_head, _ = wait_until(lambda o=o, h=c["head"]: self.px(o, "gitinfo", repo).get("head") == h, 30, 0.5)
                lat.append(round(time.monotonic() - t1, 2))
                good = good and bool(seen_head)
        f = {w: self.px(w, "fsck", repo, label=f"r04-fsck-{w}") for w in ("a", "b")}
        gi = {w: self.px(w, "gitinfo", repo) for w in ("a", "b")}
        agree = gi["a"].get("head") == gi["b"].get("head") and gi["a"].get("commits") == gi["b"].get("commits")
        self.res.rec("R04b", "PASS" if good and agree else "FAIL",
                     f"6 alternating commits visible on the other node (poll latencies s={lat}); heads agree={agree}")
        self.res.rec(t, "PASS" if all(v.get("ok") for v in f.values()) and ok and good and agree else "FAIL",
                     f"fsck --strict clean on A={f['a'].get('ok')} B={f['b'].get('ok')}; mkrepo {mk.get('seconds')}s")

    # ------------------------------------------------------------------ R05
    def r05(self):
        t = "R05"
        mk = self.px("a", "mkrepo", SRC, "big", BIG_FILES, BIG_COMMITS, timeout=1800, label="r05-mkrepo-big")
        self.tim("mkrepo_big_on_rwx", mk.get("seconds") or 0)
        src = f"file://{SRC}/big.git"
        for rid, pause in (("c1", 4), ("c2", None)):
            jobs = [(w, i) for w in ("a", "b") for i in range(4)]
            outs = self.par(*[(lambda w=w, i=i, rid=rid, pause=pause: self.rr(w, rid, src, pause=pause, label=f"r05-{rid}-{w}{i}")) for w, i in jobs])
            acts = _count([o.get("action") for o in outs])
            rcs = _count([o.get("_rc") for o in outs])
            attempts = sorted({o.get("attempt") for o in outs})
            f = {w: self.px(w, "fsck", f"{WS}/{rid}")for w in ("a", "b")}
            ok = acts.get("hydrated") == 1 and acts.get("already_ready") == 7 and rcs == {0: 8} and all(v.get("ok") for v in f.values())
            self.res.rec(f"R05-{rid}", "PASS" if ok else "FAIL",
                         f"4+4 concurrent (pause={pause}): actions={acts} rcs={rcs} attempts={attempts} "
                         f"fsck A={f['a'].get('ok')} B={f['b'].get('ok')}")
        oa, ob = self.par(lambda: self.rr("a", "d1", src, label="r05-d1-a"), lambda: self.rr("b", "d2", src, label="r05-d2-b"))
        fs = [self.px(w, "fsck", f"{WS}/{r}") for w, r in (("b", "d1"), ("a", "d2"))]
        ok = oa.get("action") == ob.get("action") == "hydrated" and all(x.get("ok") for x in fs)
        self.res.rec("R05-diff", "PASS" if ok else "FAIL",
                     f"different repos concurrently: A d1={oa.get('action')} B d2={ob.get('action')}; cross-node fsck clean={all(x.get('ok') for x in fs)}")
        self.res.rec(t, "INFO", "see R05-c1/c2/diff rows")

    # ------------------------------------------------------------------ R06
    def r06(self):
        t = "R06"
        for kind in ("flock", "fcntl"):
            for h, c in (("a", "b"), ("b", "a")) if kind == "flock" else (("a", "b"),):
                path = f"{L.WORK}/locks/r06-{kind}-{h}.lock"
                holder = self.kube.popen_exec(PODS[h], ["python3", "-I", "-", "lockhold", path, LOCK_HOLD_S, kind], stdin=self.probe_src)
                first = _read_line(holder, 60)
                if first is None:
                    raise L.HangSuspected(f"NFS I/O hang suspected: lock holder on {h} did not report within 60s")
                t0 = time.monotonic()
                held = (first or {}).get("event") == "HELD"
                c1 = self.px(c, "locktry", path, 3, kind)
                c2 = self.px(c, "locktry", path, 60, kind)
                total = time.monotonic() - t0
                holder.wait(timeout=60)
                ok = held and not c1.get("acquired") and c2.get("acquired")
                self.res.rec(f"R06-{kind}-{h}to{c}", "PASS" if ok else "FAIL",
                             f"holder on {h}: held={held}; contender on {c}: 3s try acquired={c1.get('acquired')} "
                             f"({c1.get('errno')}), then blocking try acquired={c2.get('acquired')} after {c2.get('waited_s')}s "
                             f"(holder released at ~{LOCK_HOLD_S}s; elapsed {total:.1f}s)")
        self.res.rec(t, "INFO", "cross-node flock/fcntl exclusion measured; see R06-* rows")

    # ------------------------------------------------------------------ R07
    def r07(self):
        t = "R07"
        probes = {w: self.px(w, "renameprobe", f"{L.WORK}/scratch", label=f"r07-renameprobe-{w}") for w in ("a", "b")}
        ctl = self.px("a", "renameprobe", LOCAL_TMP, label="r07-renameprobe-emptydir")
        promos = sorted({r.get("promotion") for r in self.rr_log if r.get("promotion")})
        sup = {w: p.get("noreplace_supported") for w, p in probes.items()}
        for w, p in probes.items():
            errs = {k: v.get("errno") for k, v in p.items() if isinstance(v, dict) and "errno" in v}
            self.res.rec(f"R07-{w}", "INFO", f"RENAME_NOREPLACE supported={p.get('noreplace_supported')} errnos={errs} "
                                              f"plain rename onto empty dir: {p.get('plain_rename_dir_onto_empty_dir')}")
        self.res.rec("R07-control", "INFO", f"emptyDir control supported={ctl.get('noreplace_supported')}")
        sane = all(p.get("file_to_existing_file", {}).get("rc") != 0 for p in probes.values())
        ne = {w: p.get("plain_rename_dir_onto_nonempty_dir", {}) for w, p in probes.items()}
        ne_ok = all(v.get("replaced") is False and v.get("errno") in ("ENOTEMPTY", "EEXIST") for v in ne.values())
        self.res.rec("R07-nonempty", "PASS" if ne_ok else "FAIL",
                     f"plain rename(2) of a dir onto an existing NON-empty dir refused with ENOTEMPTY/EEXIST: {ne}; "
                     f"RENAME_NOREPLACE onto non-empty dir: { {w: p.get('noreplace_dir_onto_nonempty_dir') for w, p in probes.items()} }")
        self.res.rec(t, "PASS" if sane and promos and ne_ok else "FAIL",
                     f"supported={sup} (research predicts EINVAL for any renameat2 flag on the Linux NFS client); request-repo promotion "
                     f"methods observed in R04/R05: {promos}; no probe silently replaced an existing file under RENAME_NOREPLACE. "
                     "request-repo's rename-fallback is `lexists(target)` then `os.rename` while holding the per-repo flock: its guarantee "
                     "rests on that lock alone (TOCTOU window; rename onto an EMPTY directory would silently replace it, so an empty "
                     "target must never be pre-created). Not tested here: lock loss after a share-manager restart")

    # ------------------------------------------------------------------ R08
    def r08(self):
        t = "R08"
        s = self.px("a", "mkrepo", f"{L.WORK}/scratch", "race", 20, 2, label="r08-mkrepo")
        self.rr("a", "race", f"file://{L.WORK}/scratch/race.git")
        repo = f"{WS}/race"
        before = self.px("a", "gitinfo", repo)
        clk = [self.px(w, "clock")["time"] for w in ("a", "b")]
        start = clk[0] + 10
        ra, rb = self.par(lambda: self.px("a", "gitrace", repo, 25, "ga", start, timeout=600),
                          lambda: self.px("b", "gitrace", repo, 25, "gb", start, timeout=600))
        self.ev.write("raw/r08-gitrace.json", dict(a=ra, b=rb, clock_a_then_b=clk))
        f = {w: self.px(w, "fsck", repo) for w in ("a", "b")}
        after = self.px("b", "gitinfo", repo)
        expected = (before.get("commits") or 0) + ra.get("commits_ok", 0) + rb.get("commits_ok", 0)
        ok = all(v.get("ok") for v in f.values()) and after.get("commits") == expected
        self.res.rec("R08-git", "PASS" if ok else "FAIL",
                     f"concurrent commits on ONE repo: ok A={ra.get('commits_ok')} B={rb.get('commits_ok')} failures A={ra.get('failures')} "
                     f"B={rb.get('failures')}; commits found={after.get('commits')} expected={expected}; fsck clean={all(v.get('ok') for v in f.values())}")
        d = f"{L.WORK}/scratch/oexcl"
        clk = self.px("a", "clock")["time"]
        oa, ob = self.par(lambda: self.px("a", "oexcl", d, 300, "oa", clk + 8), lambda: self.px("b", "oexcl", d, 300, "ob", clk + 8))
        v = self.px("a", "oexcl_verify", d, 300, "oa,ob")
        won_a, won_b = set(oa.get("won", [])), set(ob.get("won", []))
        ok = not v.get("missing") and not (won_a & won_b) and len(won_a) + len(won_b) == 300 and v["by_label"].get("oa") == len(won_a)
        self.ev.write("raw/r08-oexcl.json", dict(a=oa, b=ob, verify=v))
        self.res.rec("R08-oexcl", "PASS" if ok else "FAIL",
                     f"O_EXCL race over 300 names: A won {len(won_a)}, B won {len(won_b)}, overlap {len(won_a & won_b)}, missing {len(v.get('missing', []))}")
        self.res.rec(t, "INFO", "lock behaviour recorded in R08-git failures (index.lock / ref lock classification)")
        del s

    # ------------------------------------------------------------------ R09
    def r09(self):
        t = "R09"
        repo, wt = f"{WS}/h1", f"{L.WORK}/worktrees"
        steps = {}
        steps["add_a"] = self.gitx("a", repo, "worktree", "add", "-q", "-b", "wt-a", f"{wt}/wt-a").rc
        lst = self.gitx("b", repo, "worktree", "list", "--porcelain")
        steps["list_b_sees_wt_a"] = int(f"{wt}/wt-a" not in lst.out)
        steps["status_b"] = self.gitx("b", f"{wt}/wt-a", "status", "--porcelain").rc
        c = self.px("b", "gitcommit", f"{wt}/wt-a", "wtb", 0, label="r09-commit-b")
        seen = self.px("a", "gitinfo", f"{wt}/wt-a")
        steps["commit_in_wt_visible"] = int(seen.get("head") != c.get("head"))
        dot = seen.get("dotgit_file") or ""
        absolute = dot.startswith("gitdir: /") and "/worktrees/wt-a" in dot
        ra, rb = self.par(lambda: self.gitx("a", repo, "worktree", "add", "-q", "-b", "wt-c", f"{wt}/wt-c"),
                          lambda: self.gitx("b", repo, "worktree", "add", "-q", "-b", "wt-d", f"{wt}/wt-d"))
        concurrent = dict(a=ra.rc, b=rb.rc, a_err=ra.err.strip()[-200:], b_err=rb.err.strip()[-200:])
        if ra.rc:
            self.gitx("a", repo, "worktree", "add", "-q", "-b", "wt-c", f"{wt}/wt-c")
        if rb.rc:
            self.gitx("b", repo, "worktree", "add", "-q", "-b", "wt-d", f"{wt}/wt-d")
        steps["remove_c_from_b"] = self.gitx("b", repo, "worktree", "remove", f"{wt}/wt-c").rc
        steps["prune_a"] = self.gitx("a", repo, "worktree", "prune").rc
        la = self.gitx("a", repo, "worktree", "list", "--porcelain").out
        lb = self.gitx("b", repo, "worktree", "list", "--porcelain").out
        f = {w: self.px(w, "fsck", repo) for w in ("a", "b")}
        self.ev.write("raw/r09-worktree-lists.txt", f"A:\n{la}\nB:\n{lb}\nA .git file: {dot}\nconcurrent add: {concurrent}\n")
        ok = (not any(steps.values()) and la == lb and f"{wt}/wt-d" in la and f"{wt}/wt-c" not in la
              and all(v.get("ok") for v in f.values()))
        self.r09_move()
        self.res.rec(t, "PASS" if ok else "FAIL",
                     f"steps(rc/diff)={steps}; worktree lists identical on both nodes={la == lb}; linked .git file absolute path={absolute} "
                     f"({dot[:60]}); concurrent add rc={concurrent['a']}/{concurrent['b']}; fsck clean={all(v.get('ok') for v in f.values())} (FIND-064)")

    def r09_move(self):
        """INFO: worktrees must be created AFTER promotion at the final path. Renaming the parent repo breaks the absolute
        gitdir links until `git worktree repair`. Uses its own repo `mv1`; never touches h1."""
        wt, a, b = f"{L.WORK}/worktrees/wt-m", f"{WS}/mv1", f"{WS}/mv1-moved"
        self.rr("a", "mv1", f"file://{SRC}/h1.git")
        add = self.gitx("a", a, "worktree", "add", "-q", "-b", "wt-m", wt).rc
        mv = self.px("a", "rename", a, b)
        broken = self.gitx("b", wt, "status", "--porcelain")
        repair = self.gitx("b", b, "worktree", "repair", wt)
        fixed = self.gitx("b", wt, "status", "--porcelain")
        self.res.rec("R09-move", "INFO",
                     f"worktree add rc={add}; parent renamed within the volume ok={mv.get('ok')}; worktree status after rename rc={broken.rc} "
                     f"(expected non-zero: absolute gitdir link broken); `git worktree repair` rc={repair.rc}; status after repair rc={fixed.rc} "
                     f"({broken.err.strip()[:80]!r})")

    # ------------------------------------------------------------------ R10
    def r10(self):
        t = "R10"
        d = f"{L.WORK}/scratch/edges"
        ea = self.px("a", "posixedges", f"{d}-a", "a", label="r10-edges-a")     # one directory per pod: fixed file names
        eb = self.px("b", "posixedges", f"{d}-b", "b", label="r10-edges-b")
        cross_b = self.px("b", "readsha", ea["mmap_file"])
        cross_a = self.px("a", "readsha", eb["mmap_file"])
        mm_ok = cross_b.get("sha256") == ea.get("mmap_sha256") and cross_a.get("sha256") == eb.get("mmap_sha256")
        basics = all(e.get(k, {}).get("ok") for e in (ea, eb) for k in ("hardlink", "symlink", "atomic_replace"))
        self.res.rec("R10-mmap", "PASS" if mm_ok else "FAIL", f"mmap+msync content identical when read on the other node: {mm_ok}")
        self.res.rec("R10-basics", "PASS" if basics else "FAIL",
                     f"hardlink={ea.get('hardlink', {}).get('ok')} symlink={ea.get('symlink', {}).get('ok')} atomic replace="
                     f"{ea.get('atomic_replace', {}).get('ok')} xattr={ea.get('xattr_user', {}).get('ok')} ({ea.get('xattr_user', {}).get('errno')})")
        self.res.rec("R10-umask", "INFO", f"modes by umask (A): {ea.get('umask_modes')}; chmod 444 then access(W)={ea.get('chmod_444_access_w')}; "
                                          f"chmod g+s dir: {ea.get('chmod_g_s_dir', {}).get('ok')}")
        self.res.rec("R10-fsync", "INFO", f"fsync 4KiB ms A={ea.get('fsync_ms')} B={eb.get('fsync_ms')}")
        clk = self.px("a", "clock")["time"]
        p = f"{L.WORK}/scratch/append.log"
        aa, ab = self.par(lambda: self.px("a", "appendrace", p, 500, "pa", clk + 8), lambda: self.px("b", "appendrace", p, 500, "pb", clk + 8))
        v = self.px("a", "appendverify", p, 500, "pa,pb")
        self.ev.write("raw/r10-append.json", dict(a=aa, b=ab, verify=v))
        self.res.rec("R10-append", "INFO", f"O_APPEND from two nodes: expected lines {v.get('expected')}, found {v.get('lines')}, "
                                           f"garbled {v.get('garbled')}, missing per writer {v.get('missing')} (NFS append is not atomic across clients [hypothesis])")
        self.res.rec(t, "INFO", "POSIX edge semantics recorded")

    # ------------------------------------------------------------------ R11
    def r11(self):
        t = "R11"
        dest = f"{L.WORK}/perf"
        runs = {}
        runs["rwx_a"] = self.px("a", "perf", f"{SRC}/big.git", dest, BIG_FILES, PERF_RUNS, "a", timeout=3000, label="r11-perf-rwx-a")
        runs["rwx_b"] = self.px("b", "perf", f"{SRC}/big.git", dest, BIG_FILES, PERF_RUNS, "b", timeout=3000, label="r11-perf-rwx-b")
        mk = self.px("a", "mkrepo", LOCAL_TMP, "ctl", BIG_FILES, BIG_COMMITS, timeout=900)
        runs["emptydir_a"] = self.px("a", "perf", f"{LOCAL_TMP}/ctl.git", LOCAL_TMP, BIG_FILES, PERF_RUNS, "c", timeout=3000,
                                     label="r11-perf-emptydir-a")
        table = {k: {op: L.summarize(v) for op, v in r.get("ops", {}).items()} for k, r in runs.items()}
        self.ev.write("r11-summary.json", dict(files=BIG_FILES, runs=PERF_RUNS, summary=table, control_mkrepo_s=mk.get("seconds")))
        for op in ("clone", "status_clean", "checkout_alt", "checkout_main", "fsck", "small_create", "small_stat", "small_read", "small_delete"):
            m = {k: table[k].get(op, {}).get("median") for k in table}
            ratio = (round(m["rwx_a"] / m["emptydir_a"], 1) if m.get("rwx_a") and m.get("emptydir_a") else None)
            self.res.rec(f"R11-{op}", "INFO", f"median s rwx_a={m['rwx_a']} rwx_b={m['rwx_b']} emptydir={m['emptydir_a']} (rwx_a/emptydir={ratio}x)")
        self.res.rec(t, "LIMITATION", f"{BIG_FILES} files x {PERF_RUNS} runs; no RWO control PVC (only one PVC approved) and EXP-005 recorded no "
                                      "small-file Git timings, so RWX is compared with an emptyDir control only. The emptyDir is node-local ephemeral storage, not Longhorn ext4, "
                                      "so it bounds (lower limit) rather than measures the RWO gap; synthetic size, shared Longhorn cluster")

    # ------------------------------------------------------------------ R12
    def r12(self):
        t = "R12"
        lockp = f"{L.WORK}/locks/r12.lock"
        self.ensure_h1()
        holder = self.kube.popen_exec(PODS["b"], ["python3", "-I", "-", "lockhold", lockp, 900, "flock"], stdin=self.probe_src)
        first = _read_line(holder, 60)
        if first is None:
            raise L.HangSuspected("NFS I/O hang suspected: lock holder on rwx-b did not report within 60s")
        held = first.get("event") == "HELD"
        sha_b = self.px("b", "posixedges", f"{L.WORK}/scratch/r12edges", "r12").get("mmap_sha256")
        before = {w: self.px(w, "fsck", f"{WS}/h1").get("ok") for w in ("a", "b")}
        old_uid = self.need(t, "pod rwx-b", ["get", "pod", PODS["b"]], kind="Pod", name=PODS["b"])["metadata"]["uid"]
        hb = threading.Thread(target=lambda: self._hb(L.WORK + "/scratch/r12-hb-a", HEARTBEAT_S))
        hb.start()
        time.sleep(3)
        t0 = time.monotonic()
        d = self.kube.delete("pod", PODS["b"], wait=True, timeout=L.TIMEOUTS["pod_delete"])
        if d.rc != 0:
            raise L.HangSuspected(f"NFS I/O hang suspected: pod rwx-b still Terminating after {L.TIMEOUTS['pod_delete']}s; not forcing")
        gone = time.monotonic() - t0
        lk = self.px("a", "locktry", lockp, L.TIMEOUTS["lock_after_delete"], "flock", timeout=L.TIMEOUTS["lock_after_delete"] + 60)
        held_released = bool(lk.get("acquired"))
        t1 = time.monotonic()
        self.kube.apply(L.render_pod(self.run_id, "b", self.node_selector, self.herdr_ns))
        pj, dt = wait_until(lambda: (lambda j: j if pod_ready(j) else None)(self.rj(["get", "pod", PODS["b"]])), L.TIMEOUTS["pod_ready"])
        self.tim("r12_pod_b_recreate_ready", time.monotonic() - t1)
        hb.join()
        try:
            holder.kill()
        except OSError:
            pass
        if not pj:
            self.collect("r12-recreate")
            self.stop(t, "recreated pod B not Ready in time")
        self.nodes["b"] = pj["spec"]["nodeName"]
        self.san.add_node(self.nodes["b"])
        if not L.pods_on_different_nodes(self.nodes["a"], self.nodes["b"]):
            self.stop(t, "recreated pod B landed on the same node as A")
        gate = self.px("b", "writegate", L.MOUNT, label="r12-gate-b2")
        ok_gate, why = L.evaluate_gate(gate)
        sha_after = self.px("b", "readsha", f"{L.WORK}/scratch/r12edges/mmap-r12.bin").get("sha256")
        after = {w: self.px(w, "fsck", f"{WS}/h1").get("ok") for w in ("a", "b")}
        again = self.px("b", "locktry", lockp, 5, "flock")
        new_uid = pj["metadata"]["uid"]
        hbres = getattr(self, "_hb_result", {})
        self.ev.write("raw/r12.json", dict(delete_to_gone_s=round(gone, 1), lock_after_delete=lk, heartbeat=hbres,
                                           recreate_ready_s=round(dt, 1), gate=ok_gate, why=why, events=self._events_for(PODS["b"])))
        ok = (held and held_released and sha_b and sha_b == sha_after and all(before.values()) and all(after.values())
              and again.get("acquired") and ok_gate and new_uid != old_uid and not hbres.get("errors"))
        self.res.rec(t, "PASS" if ok else "FAIL",
                     f"graceful delete of rwx-b gone in {gone:.1f}s; B's flock free for A after {lk.get('waited_s')}s; recreated pod Ready in {dt:.1f}s "
                     f"(new UID={new_uid != old_uid}); data sha equal={sha_b == sha_after}; fsck before/after={before}/{after}; "
                     f"UID1000 gate on new pod={ok_gate}; A heartbeat max gap {hbres.get('max_gap_s')}s errors={hbres.get('errors')}")

    def ensure_h1(self):
        """Standalone `recreate` may run without R04: make sure the shared repo exists (read-first, idempotent)."""
        if not self.px("a", "statinfo", f"{WS}/h1").get(f"{WS}/h1"):
            if not self.px("a", "statinfo", f"{SRC}/h1.git").get(f"{SRC}/h1.git"):
                self.px("a", "mkwork", L.MOUNT)
                self.px("a", "mkrepo", SRC, "h1", 300, 5, timeout=900)
            self.rr("a", "h1", f"file://{SRC}/h1.git")

    def attach(self):
        """Rebuild state from an existing run namespace (read-only): PV, node placement; fresh Herdr/volume baseline.
        Fail closed: anything unreadable stops."""
        self.kube.guard_labels("namespace", self.ns)
        pvc = self.need("attach", "scratch PVC", ["get", "pvc", L.PVC_NAME], kind="PersistentVolumeClaim", name=L.PVC_NAME)
        self.pv = pvc["spec"].get("volumeName")
        if not self.pv:
            self.stop("attach", "scratch PVC has no bound volume")
        for w in ("a", "b"):
            t = self.kube.read_state(["get", "pod", PODS[w]], kind="Pod", name=PODS[w])
            if t.state == L.UNKNOWN:
                self.stop("attach", f"pod {PODS[w]} unreadable: {t.reason}")
            if t.state == L.PRESENT:
                self.nodes[w] = t.data["spec"].get("nodeName")
                self.san.add_node(self.nodes[w])
        self.created = True
        self.base_herdr, self.base_vols = self.herdr_now(), self.vols_now()
        if self.base_herdr is None or self.base_vols is None:
            self.stop("attach", "Herdr or Longhorn baseline unreadable")

    def _hb(self, path, seconds):
        self._hb_result = self.px("a", "heartbeat", path, seconds, timeout=seconds + 120)

    def _events_for(self, pod):
        ev = self.rj(["get", "events", "--field-selector", f"involvedObject.name={pod}"]) or {}
        return [dict(reason=e.get("reason"), type=e.get("type"), msg=(e.get("message") or "")[:200]) for e in ev.get("items", [])]

    # ------------------------------------------------------------------ R13
    def r13(self):
        t = "R13"
        self.observe("end-of-tests")
        obs = self.observations
        pods = [tuple((p["uid"], p["restarts"], p["phase"]) for p in o.get("share_manager_pods", [])) for o in obs]
        stable = len(set(pods)) == 1 and pods[0] and all(p[2] == "Running" for p in pods[0])
        svc = all(o.get("service_present") for o in obs)
        cr = all(o.get("sharemanager_cr") for o in obs)
        smn = {self.san.alias(p["node"]) for o in obs for p in o.get("share_manager_pods", [])}
        last = obs[-1].get("share_manager_pods", [{}])[0] if obs and obs[-1].get("share_manager_pods") else {}
        img = f"{last.get('image')} {last.get('image_id')}"
        reps = obs[-1].get("replica_nodes")
        self.res.rec(t, "PASS" if stable and svc and cr else "FAIL",
                     f"share-manager pod(s) unchanged UID/restarts and Running at {len(obs)} checkpoints={bool(stable)}; Service present={svc}; "
                     f"ShareManager CR present={cr}; engines={obs[-1].get('engines')} replicas={obs[-1].get('replicas')}; share-manager node(s)={sorted(smn)}; "
                     f"share-manager image={img}; Longhorn replica nodes={reps}; scratch pods on {self.san.alias(self.nodes.get('a'))}/"
                     f"{self.san.alias(self.nodes.get('b'))}, Herdr node {self.san.alias(self.herdr_node)} (read-only observation; "
                     "share-manager placement is Longhorn-controlled and may be the Herdr node)")

    # ------------------------------------------------------------------ evidence collection (read-only)
    def collect(self, label):
        d = f"collect-{label}"
        for name, args, kw in (("pods", ["get", "pods", "-o", "wide"], {}), ("pvc", ["get", "pvc", "-o", "yaml"], {}),
                               ("events", ["get", "events", "--sort-by=.metadata.creationTimestamp"], {}),
                               ("describe-pods", ["describe", "pods"], {}), ("describe-pvc", ["describe", "pvc"], {})):
            r = self.kube.read(args, **kw)
            self.ev.write(f"{d}/{name}.txt", r.out + (f"\n[stderr] {r.err}" if r.err.strip() else ""))
        if self.pv:
            self.ev.write(f"{d}/longhorn.json", self.share_manager_state())
            pv = self.kube.read(["get", "pv", self.pv, "-o", "yaml"], ns=False)
            self.ev.write(f"{d}/pv.yaml", pv.out)

    # ------------------------------------------------------------------ cleanup + R14
    def cleanup(self):
        return run_cleanup(self.kube, self.ev, self.res, self.pv, self.base_herdr, self.base_vols, self.herdr_ns,
                           self.herdr_pod, sleep=self.sleep)

    # ------------------------------------------------------------------ whole run
    def run(self):
        """Returns exit code. Always ends with collection + guarded cleanup once anything was created."""
        stop_reason, cleanup_rc = None, 0
        try:
            self.r00()
            self.create_resources()
            for fn in (self.r02, self.r03, self.r04, self.r05, self.r06, self.r07, self.r08, self.r09, self.r10,
                       self.r11, self.r12, self.r13):
                name = fn.__name__.upper()
                self.check_global(f"pre-{name}")      # window, node health, upgrade CRs, scratch pods, Herdr, volumes
                fn()
                self.check_global(name)
                self.observe(f"after-{fn.__name__}")
        except StopRun as e:
            stop_reason = str(e)
            if isinstance(e, L.HangSuspected):
                self.res.rec("RUN", "FAIL", stop_reason)
            log(f"STOP CONDITION: {stop_reason}")
        except subprocess.TimeoutExpired as e:
            stop_reason = f"NFS I/O hang suspected: subprocess timed out after {e.timeout}s"
            self.res.rec("RUN", "FAIL", stop_reason)
            log(f"STOP CONDITION: {stop_reason}")
        except Exception as e:  # noqa: BLE001  unexpected: treat as a stop, still clean up
            stop_reason = f"unexpected {type(e).__name__}: {e}"
            self.res.rec("RUN", "FAIL", stop_reason)
        finally:
            left = self.kube.reap()
            if left:
                log(f"terminated {left} local kubectl-exec client(s) still running")
            if self.created:
                try:
                    self.collect("final")
                except Exception as e:  # noqa: BLE001
                    log(f"collect failed: {e}")
                try:
                    cleanup_rc = self.cleanup()
                except Exception as e:  # noqa: BLE001
                    self.res.rec("R14", "FAIL", f"UNVERIFIED: cleanup raised {type(e).__name__}: {e}")
                    cleanup_rc = L.EXIT_UNVERIFIED
        self.ev.write("results.tsv", self.res.tsv())
        self.ev.write("timings.tsv", "step\tseconds\n" + "".join(f"{a}\t{b}\n" for a, b in self.timings))
        self.ev.write("commands.txt", "\n".join(self.kube.trace))
        self.ev.write("summary.json", dict(run_id=self.run_id, image=L.IMAGE, stop=stop_reason, counts=self.res.counts(),
                                           failed=self.res.failed(), withheld=self.ev.withheld, cleanup_rc=cleanup_rc,
                                           request_repo_sha256=hashlib.sha256(self.rr_src.encode()).hexdigest()))
        if cleanup_rc in (L.EXIT_REFUSED, L.EXIT_RESIDUE, L.EXIT_UNVERIFIED):
            return cleanup_rc                      # cleanup refused / residue / unverified: owner action required
        return 3 if stop_reason else (1 if self.res.failed() else 0)


def _count(items):
    out = {}
    for i in items:
        out[i] = out.get(i, 0) + 1
    return out


def _cond(obj, typ):
    for c in obj.get("status", {}).get("conditions", []) or []:
        if c.get("type") == typ:
            return c.get("status")
    return None


def _read_line(proc, timeout):
    q = queue.Queue()
    threading.Thread(target=lambda: q.put(proc.stdout.readline()), daemon=True).start()
    try:
        return json.loads(q.get(timeout=timeout))
    except (queue.Empty, ValueError):
        return None


# ---------------------------------------------------------------------- guarded cleanup (shared by `cleanup` and R14)
OFFLINE_CLEANUP_STEPS = """\
  1. read namespace {ns}; require labels herdrnetes.io/experiment=exp-005-rwx and herdrnetes.io/run-id=<run id>
  2. inventory namespaced objects; REFUSE if any object lacks the labels or is not a Pod/PVC/NetworkPolicy
  3. for each Pod, NetworkPolicy, then PVC: re-check labels, then graceful kubectl delete (no --force, no --grace-period)
  4. delete Namespace {ns} (labels re-checked)
  5. read-only verify: PVC, PV, Longhorn volume, share-manager pod/CR/Service, VolumeAttachment, namespace all gone;
     live Herdr UID/restarts and other Longhorn volumes unchanged. Residue is reported, never deleted by the harness."""

def run_cleanup(kube, ev, res, pv, base_herdr, base_vols, herdr_ns, herdr_pod, sleep=time.sleep):
    """Plan from read-only inventory; print every command; delete only when kube.execute; verify read-only, FAIL CLOSED.
    Exit codes: 0 clean, 4 refused (labels/kinds), 5 residue (objects remain or a delete failed/timed out),
    6 UNVERIFIED (some object could not be positively shown absent), 7 objects gone but Herdr/other volumes changed."""
    ns, run_id = kube.ns, kube.run_id
    if not kube.live:
        text = "\n".join([f"cleanup plan (offline) for run-id {run_id}:"] + OFFLINE_CLEANUP_STEPS.format(ns=ns).splitlines())
        log("\n" + text)
        ev.write("cleanup/plan.txt", text)
        res.rec("R14", "SKIP", "offline dry run: nothing read, nothing deleted")
        return 0
    ns_t = kube.read_state(["get", "namespace", ns], kind="Namespace", name=ns, ns=False)
    unreadable = None
    if ns_t.state == L.ABSENT:
        plan = L.plan_cleanup([], None, run_id)
    elif ns_t.state == L.UNKNOWN:
        unreadable = f"namespace unreadable: {ns_t.reason}"
    else:
        inv_t = kube.read_state(["get", INV_KINDS], is_list=True)
        try:
            if inv_t.state == L.UNKNOWN:
                unreadable = f"inventory unreadable: {inv_t.reason}"
            else:
                plan = L.plan_cleanup(inventory_from(inv_t.data or {"items": []}), ns_t.data, run_id)
        except (KeyError, TypeError, AttributeError) as e:
            unreadable = f"inventory malformed: {type(e).__name__}: {e}"
    if unreadable:
        ev.write("cleanup/plan.txt", f"cleanup plan for run-id {run_id}: UNVERIFIED, {unreadable}")
        res.rec("R14", "FAIL", f"UNVERIFIED: {unreadable}; nothing deleted")
        return L.EXIT_UNVERIFIED
    lines = ["cleanup plan for run-id " + run_id + " in " + ns + ":"]
    lines += [f"  REFUSE: {r}" for r in plan["refusals"]]
    lines += [f"  delete {k}/{n}" for k, n in plan["deletes"]]
    lines += ["  delete namespace " + ns] if plan["delete_ns"] else ["  (namespace not deleted)"]
    if plan.get("note"):
        lines.append("  " + plan["note"])
    text = "\n".join(lines)
    log("\n" + text)
    ev.write("cleanup/plan.txt", text)
    if plan["refusals"]:
        res.rec("R14", "FAIL", f"cleanup REFUSED (nothing deleted): {plan['refusals']}")
        return L.EXIT_REFUSED
    if not kube.execute:
        res.rec("R14", "SKIP", "dry-run: cleanup plan printed, nothing deleted (use --execute --confirm-run-id)")
        return 0
    # establish the PV / Longhorn volume name BEFORE deleting anything (the PVC is the only link to it)
    names, name_known = set(), False
    if pv:
        names.add(pv)
        name_known = True
    pvc_t = kube.read_state(["get", "pvc", L.PVC_NAME], kind="PersistentVolumeClaim", name=L.PVC_NAME)
    if pvc_t.state == L.PRESENT:
        name_known = True                      # a PVC that never bound has no volume: positively nothing to look for
        if (pvc_t.data.get("spec") or {}).get("volumeName"):
            names.add(pvc_t.data["spec"]["volumeName"])
    residue = None
    try:
        for kind, name in plan["deletes"]:
            d = kube.delete(kind, name, wait=True, timeout=L.TIMEOUTS["pod_delete"])
            if d.rc != 0:
                residue = f"{kind}/{name} did not disappear within {L.TIMEOUTS['pod_delete']}s (rc={d.rc}: {d.err.strip()[-120:]})"
                break                      # later deletes would only wait on it (pvc-protection); do not escalate
        if residue is None and plan["delete_ns"]:
            d = kube.delete("namespace", ns)
            if d.rc != 0:
                residue = f"namespace/{ns} delete request failed (rc={d.rc}: {d.err.strip()[-120:]})"
    except L.Refused as e:
        residue = f"cleanup guard refused: {e}"
    except Exception as e:  # noqa: BLE001  outcome of a delete is unknown: never report it as cleaned up
        residue = f"delete outcome unknown: {type(e).__name__}: {e}"
    if residue:
        facts = _cleanup_facts(kube, ns, names, name_known)
        v = L.verify_cleanup(facts)
        ev.write("cleanup/residue.json", dict(reason=residue, verdict=v["verdict"], present=v["present"], unknown=v["unknown"]))
        res.rec("R14", "FAIL", f"RESIDUE: {residue}; present={v['present']} unknown={v['unknown']}. OWNER ACTION REQUIRED: the harness never "
                               "uses --force, --grace-period=0 or finalizer edits, and never touches PV/Longhorn/VolumeAttachment objects")
        log("RESIDUE reported to the owner; nothing was forced.")
        return L.EXIT_RESIDUE
    try:
        return _verify_and_conclude(kube, ev, res, ns, names, name_known, pv, base_herdr, base_vols, herdr_ns, herdr_pod, sleep)
    except Exception as e:  # noqa: BLE001  ANY failure while verifying is UNVERIFIED (exit 6), never CLEAN and never a traceback
        ev.write("cleanup/verify.json", dict(verdict="UNVERIFIED", exception=f"{type(e).__name__}: {e}", volume_names=sorted(names)))
        res.rec("R14", "FAIL", f"UNVERIFIED: verification raised {type(e).__name__}: {e}; not claiming cleanup")
        return L.EXIT_UNVERIFIED


def _verify_and_conclude(kube, ev, res, ns, names, name_known, pv, base_herdr, base_vols, herdr_ns, herdr_pod, sleep):
    # read-only verification: never delete a PV, Longhorn object or VolumeAttachment ourselves. The LAST poll decides:
    # an UNKNOWN is never promoted to ABSENT by polling.
    t0 = time.monotonic()
    while True:
        facts = _cleanup_facts(kube, ns, names, name_known)
        v = L.verify_cleanup(facts)
        if v["verdict"] == "CLEAN" or time.monotonic() - t0 > L.TIMEOUTS["cleanup"]:
            break
        sleep(5)
    waited = round(time.monotonic() - t0, 1)
    # invariants: Herdr and unrelated volumes. With a baseline they must be positively readable and unchanged.
    inv_unknown, inv_stops, inv_infos = [], [], []
    herdr_same = None
    if base_herdr is not None or base_vols is not None:
        now_h, now_v = (None, None)
        try:
            t_h = kube.read_state(["get", "pod", herdr_pod], kind="Pod", name=herdr_pod, ns=False, namespace=herdr_ns)
            now_h = L.herdr_facts(t_h.data) if t_h.state == L.PRESENT else None
            t_v = kube.read_state(["get", "volumes.longhorn.io"], is_list=True, ns=False, namespace=L.LONGHORN_NS)
            now_v = L.longhorn_volume_states(t_v.data or {"items": []}) if t_v.state != L.UNKNOWN else None
        except (ValueError, KeyError, TypeError):
            now_v = None
        if base_herdr is not None and now_h is None:
            inv_unknown.append("live Herdr pod unreadable")
        if base_vols is not None and now_v is None:
            inv_unknown.append("Longhorn volume inventory unreadable")
        if not inv_unknown:
            inv_stops, inv_infos = L.check_invariants(base_herdr, now_h, base_vols, now_v, scratch_volume=pv or next(iter(names), None))
            herdr_same = now_h == base_herdr
    else:
        inv_infos.append("no baseline available (standalone cleanup): Herdr/other volumes not compared")
    ev.write("cleanup/verify.json", dict(
        facts={k: dict(state=t.state, reason=t.reason) for k, t in facts.items()}, verdict=v["verdict"], present=v["present"],
        unknown=v["unknown"], waited_s=waited, herdr_unchanged=herdr_same, invariant_unknown=inv_unknown, invariant_stops=inv_stops,
        invariant_infos=inv_infos, volume_names=sorted(names)))
    if v["verdict"] == "RESIDUE":
        res.rec("R14", "FAIL", f"RESIDUE after {waited}s: {v['present']} (unknown: {v['unknown']}). OWNER ACTION REQUIRED; nothing is forced")
        return L.EXIT_RESIDUE
    if v["verdict"] == "UNVERIFIED" or inv_unknown:
        res.rec("R14", "FAIL", f"UNVERIFIED after {waited}s (fail closed): unknown={v['unknown']} {inv_unknown}; not claiming cleanup")
        return L.EXIT_UNVERIFIED
    ok = not inv_stops
    res.rec("R14", "PASS" if ok else "FAIL",
            f"guarded cleanup; every scratch object positively ABSENT after {waited}s (namespace, PVC, PV, Longhorn volume, share-manager "
            f"pod/CR/Service, VolumeAttachment); Herdr unchanged={herdr_same}; other volumes ok={not inv_stops} {inv_stops}")
    return 0 if ok else 7


def _cleanup_facts(kube, ns, names, name_known):
    """item -> Tri for everything the scratch PVC could have left behind. Reads only; fail closed (UNKNOWN stays UNKNOWN)."""
    rs, lh = kube.read_state, dict(ns=False, namespace=L.LONGHORN_NS)
    facts = {"namespace": rs(["get", "namespace", ns], kind="Namespace", name=ns, ns=False),
             "pvc": rs(["get", "pvc", L.PVC_NAME], kind="PersistentVolumeClaim", name=L.PVC_NAME)}
    names = set(names)

    def listed(args, match, **kw):
        """List read + match. Every item must be an object with metadata.name; anything else makes the whole answer UNKNOWN."""
        t = rs(args, is_list=True, **kw)
        if t.state == L.UNKNOWN:
            return t, set()
        items = (t.data or {}).get("items", [])
        try:
            names_ = [(i.get("metadata") or {}).get("name") for i in items]
            if not all(isinstance(n_, str) and n_ for n_ in names_):
                return Tri(UNKNOWN, None, "unexpected schema: list item without metadata.name"), set()
            hits = [n_ for i, n_ in zip(items, names_, strict=True) if match(i)]
        except (AttributeError, KeyError, TypeError) as e:
            return Tri(UNKNOWN, None, f"unexpected schema in list item: {type(e).__name__}: {e}"), set()
        return (Tri(PRESENT, None, f"listed: {hits}") if hits else Tri(ABSENT, None, "no match in a readable list")), set(hits)

    pv_list, pv_hits = listed(["get", "pv"], lambda i: ((i.get("spec") or {}).get("claimRef") or {}).get("namespace") == ns
                              or i["metadata"]["name"] in names, ns=False)
    lv_list, lv_hits = listed(["get", "volumes.longhorn.io"],
                              lambda i: ((i.get("status") or {}).get("kubernetesStatus") or {}).get("namespace") == ns
                              or (i.get("metadata") or {}).get("name") in names, **lh)
    names |= pv_hits | lv_hits
    facts["pv"] = L.combine(pv_list, *[rs(["get", "pv", n], kind="PersistentVolume", name=n, ns=False) for n in sorted(names)])
    facts["longhorn_volume"] = L.combine(lv_list, *[rs(["get", "volumes.longhorn.io", n], kind="Volume", name=n, **lh) for n in sorted(names)])
    va = rs(["get", "volumeattachments.storage.k8s.io"], is_list=True, ns=False)
    if va.state == L.UNKNOWN:
        facts["volume_attachment"] = va
    elif not (names or name_known):
        facts["volume_attachment"] = Tri(UNKNOWN, None, "volume name never established")
    else:
        try:
            vitems = (va.data or {}).get("items", [])
            if not all(isinstance(i.get("spec"), dict) and isinstance(i["spec"].get("source"), dict) and (i.get("metadata") or {}).get("name")
                       for i in vitems):
                raise ValueError("VolumeAttachment item without metadata.name/spec.source")
            hits = [i["metadata"]["name"] for i in vitems if i["spec"]["source"].get("persistentVolumeName") in names]
            facts["volume_attachment"] = Tri(PRESENT, None, f"listed: {hits}") if hits else Tri(ABSENT, None, "no attachment for the volume")
        except (AttributeError, KeyError, TypeError, ValueError) as e:
            facts["volume_attachment"] = Tri(UNKNOWN, None, f"unexpected schema: {type(e).__name__}: {e}")
    if not names and not name_known:
        unk = Tri(UNKNOWN, None, "volume name never established: cannot look for its share-manager objects")
        facts.update(share_manager_pod=unk, share_manager_cr=unk, share_manager_service=unk)
    elif not names:
        none = Tri(ABSENT, None, "PVC never bound: no volume, nothing to look for")
        facts.update(share_manager_pod=none, share_manager_cr=none, share_manager_service=none)
    else:
        pod_t, cr_t, svc_t = [], [], []
        for n in sorted(names):
            pod_t += [rs(["get", "pod", f"share-manager-{n}"], kind="Pod", name=f"share-manager-{n}", **lh),
                      rs(["get", "pods", "-l", f"longhorn.io/share-manager={n}"], is_list=True, **lh)]
            cr_t.append(rs(["get", "sharemanagers.longhorn.io", n], kind="ShareManager", name=n, **lh))
            svc_t.append(rs(["get", "service", n], kind="Service", name=n, **lh))
        facts.update(share_manager_pod=L.combine(*pod_t), share_manager_cr=L.combine(*cr_t), share_manager_service=L.combine(*svc_t))
    return facts
