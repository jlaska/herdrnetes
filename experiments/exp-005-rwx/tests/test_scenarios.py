"""End-to-end simulation of Runner (R00-R14) against a simulated kubectl backed by LOCAL processes. No cluster.

SimKube keeps every real guard of rwxlib.Kube (validation, label guard, allow-list) and replaces only the final
`kubectl` call: `exec` runs the probe/git/request-repo locally under a temp directory standing in for /rwx, and
get/apply/delete are answered from a small in-memory model of the cluster.
"""
import json
import os
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
NOON = lambda: datetime(2026, 11, 19, 12, 0, tzinfo=timezone.utc)  # noqa: E731  outside the maintenance window


class SimKube(L.Kube):
    def __init__(self, root, node_b="node-x2", herdr_uid="herdr-uid-1", **kw):
        super().__init__("ctx-sim", RUN, live=True, execute=True, echo=lambda *_: None)
        self.root, self.nodes_ab, self.herdr_uid = root, {"rwx-a": "node-x1", "rwx-b": node_b}, herdr_uid
        self.pods, self.pvc, self.ns_exists, self.holders, self.mutations, self.herdr_flip_after = {}, False, False, {}, [], None
        self.generation = 0
        self.nodes_list, self.node_flags, self.manager_tag = list(NODES), {}, "v1.13.0"
        self.crds, self.crs, self.hang_after, self.stuck_pod, self.terminated_after = [], [], None, None, None
        self.herdr_pods = 1
        self.exec_count = 0

    # -- cluster model
    def lab(self):
        return {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: RUN}

    def pod_obj(self, name):
        n = self.pods[name]
        return {"metadata": {"name": name, "namespace": NS, "uid": f"uid-{name}-{n}", "labels": self.lab()},
                "spec": {"nodeName": self.nodes_ab[name]},
                "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                           "containerStatuses": [{"name": "ws", "restartCount": 0, "state": self.pod_state(name)}]}}

    def pod_state(self, name):
        if name == "rwx-a" and self.terminated_after is not None and self.exec_count > self.terminated_after:
            return {"terminated": {"exitCode": 137}}
        return {"running": {}}

    def herdr_obj(self):
        uid = self.herdr_uid if not (self.herdr_flip_after is not None and self.exec_count > self.herdr_flip_after) else "CHANGED"
        return {"metadata": {"uid": uid, "name": "herdr-0", "ownerReferences": [{"kind": "StatefulSet", "name": "herdr"}]},
                "spec": {"nodeName": "node-x3"}, "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                                                      "containerStatuses": [{"name": "herdr", "restartCount": 0, "imageID": "img"}]}}

    def vols(self):
        items = [{"metadata": {"name": "pvc-other"}, "status": {"state": "attached", "robustness": "healthy"}}]
        if self.pvc:
            items.append({"metadata": {"name": "pvc-scratch"}, "spec": {"accessMode": "rwx", "numberOfReplicas": 3},
                          "status": {"state": "attached", "robustness": "healthy", "kubernetesStatus": {"namespace": NS}}})
        return {"items": items}

    NOTFOUND = L.CmdResult(1, "", 'Error from server (NotFound): not found')

    def jr(self, obj):
        return L.CmdResult(0, json.dumps(obj), "")

    def get(self, a):
        """a: list after the 'get' verb, '-o json' removed."""
        kind = a[0]
        name = a[1] if len(a) > 1 and not a[1].startswith("-") else None
        if kind == "namespace" and name == HERDR_NS:
            return self.jr({"metadata": {"name": HERDR_NS}})
        if kind == "namespace":
            return self.jr({"metadata": {"name": NS, "labels": self.lab()}}) if self.ns_exists else self.NOTFOUND
        if kind == "nodes":
            return self.jr({"items": [{"metadata": {"name": n}, "spec": {"unschedulable": self.node_flags.get(n) == "cordoned"},
                                       "status": {"conditions": [{"type": "Ready", "status": "False" if self.node_flags.get(n) == "notready" else "True"}],
                                                  "nodeInfo": {"kubeletVersion": "v1.36.6", "osImage": "Talos", "kernelVersion": "6.18"}}}
                                      for n in self.nodes_list]})
        if kind == "crd":
            return self.jr({"items": [{"metadata": {"name": n}} for n in self.crds]})
        if kind in self.crds:
            return self.jr({"items": [{"metadata": {"name": "x"}, "status": {"phase": ph}} for ph in self.crs]})
        if kind == "storageclass":
            return self.jr({"provisioner": "driver.longhorn.io", "reclaimPolicy": "Delete", "volumeBindingMode": "Immediate",
                            "parameters": {"numberOfReplicas": "3"}})
        if kind == "csidriver":
            return self.jr({"spec": {"fsGroupPolicy": "ReadWriteOnceWithFSType", "attachRequired": True}})
        if kind == "volumes.longhorn.io":
            if name:
                v = [i for i in self.vols()["items"] if i["metadata"]["name"] == name]
                return self.jr(v[0]) if v else self.NOTFOUND
            return self.jr(self.vols())
        if kind == "nodes.longhorn.io":
            return self.jr({"items": [{"status": {"conditions": [{"type": "Ready", "status": "True"}]}}]})
        if kind == "sharemanagers.longhorn.io":
            if name and self.pvc and "rwx-a" in self.pods:
                return self.jr({"status": {"state": "running", "ownerID": "n", "endpoint": "nfs://x"}})
            return self.jr({"items": []}) if not name else self.NOTFOUND
        if kind == "settings.longhorn.io":
            return self.jr({"value": "false"})
        if kind == "pods" and "app.kubernetes.io/name=herdr" in a:
            return self.jr({"items": [self.herdr_obj()] * self.herdr_pods})
        if kind == "pods" and "-l" in a:
            if self.pvc and "rwx-a" in self.pods:
                return self.jr({"items": [{"metadata": {"name": "share-manager-pvc-scratch", "uid": "sm-uid"},
                                           "spec": {"nodeName": "node-x3", "containers": [{"image": "longhornio/longhorn-manager:v1.13.0"}]},
                                           "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                                                      "containerStatuses": [{"restartCount": 0}]}}]})
            return self.jr({"items": []})
        if kind == "pods":
            return self.jr({"items": [{"metadata": {"name": "longhorn-manager-abc"}, "status": {"phase": "Running"},
                                       "spec": {"containers": [{"name": "longhorn-manager", "image": f"longhornio/longhorn-manager:{self.manager_tag}"}]}}]})
        if kind == "service":
            return self.jr({"metadata": {"name": name}}) if self.pvc and "rwx-a" in self.pods else self.NOTFOUND
        if kind in ("engines.longhorn.io", "replicas.longhorn.io"):
            return self.jr({"items": [{}] * (1 if kind.startswith("eng") else 3)} if self.pvc else {"items": []})
        if kind == "volumeattachments.storage.k8s.io":
            return self.jr({"items": [{"spec": {"source": {"persistentVolumeName": "pvc-scratch"}}}] if self.pvc else []})
        if kind == "pv":
            return self.jr({"metadata": {"name": name}}) if self.pvc else self.NOTFOUND
        if kind == "pod" and name == "herdr-0":
            return self.jr(self.herdr_obj())
        if kind == "pod" and name in self.pods:
            return self.jr(self.pod_obj(name))
        if kind in ("pvc", "persistentvolumeclaim") and self.pvc:
            return self.jr({"metadata": {"name": L.PVC_NAME, "namespace": NS, "labels": self.lab()},
                            "spec": {"volumeName": "pvc-scratch"}, "status": {"phase": "Bound"}})
        if kind.startswith("pvc,pod"):
            items = [{"kind": "Pod", "metadata": {"name": n, "labels": self.lab()}} for n in self.pods]
            if self.pvc:
                items.append({"kind": "PersistentVolumeClaim", "metadata": {"name": L.PVC_NAME, "labels": self.lab()}})
            return self.jr({"items": items})
        if kind == "events":
            return self.jr({"items": []})
        return self.NOTFOUND

    # -- the only thing replaced: the final kubectl call
    def _go(self, argv, mutating, input=None, timeout=None):
        self.trace.append(" ".join(argv))
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
            elif kind == "namespace":
                for plist in self.holders.values():
                    for p in plist:
                        p.kill()
                self.holders.clear()
                self.ns_exists = False
                self.pods.clear()
                self.pvc = False
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

    def do_exec(self, rest, input, timeout):
        self.exec_count += 1
        pod = rest[rest.index("-c") - 1]
        if self.hang_after is not None and self.exec_count > self.hang_after:
            return L.CmdResult(124, "", f"timeout after {timeout}s")
        if pod not in self.pods:
            return L.CmdResult(1, "", f'pods "{pod}" not found')
        cmd, env = self.local_cmd(rest[rest.index("--") + 1:])
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.holders.setdefault(pod, []).append(p)       # like a real pod: deleting it ends everything exec'd in it
        out, err = p.communicate(input, timeout=timeout)
        return L.CmdResult(p.returncode, out, err)

    def popen_exec(self, pod, cmd, stdin=None):
        self.trace.append(f"popen {pod} {cmd[:4]}")
        argv, env = self.local_cmd([str(c) for c in cmd])
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        p.stdin.write(stdin)
        p.stdin.close()
        self.holders.setdefault(pod, []).append(p)
        return p


def re_docs(text):
    import re
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


class TestFullSimulation(SimBase):
    def test_full_run_passes_and_cleans_up(self):
        r, kube, res, ev = self.runner()
        rc = r.run()
        rows = {t: (s, d) for t, s, d in res.rows}
        for tid in ["R00", "R02", "R03", "R04", "R05", "R06", "R07", "R08", "R09", "R10", "R11", "R12", "R13", "R14"]:
            self.assertIn(tid, rows, f"{tid} not recorded")
        # R02c asserts NoNewPrivs=1, which only a real pod has; a developer shell reports 0 (local-simulation artefact)
        self.assertEqual(res.failed(), ["R02c"], [x for x in res.rows if x[1] == "FAIL"])
        self.assertEqual(rc, 1)
        self.assertEqual(rows["R14"][0], "PASS", rows["R14"])
        # mutation log: only apply/delete of our objects, namespace deleted last, pod B recreated once
        kinds = [m for m in kube.mutations]
        self.assertEqual(kinds[-1], ("delete", "namespace", NS))
        applies = [m for m in kinds if m[0] == "apply"]
        self.assertEqual(len(applies), 1 + 1 + 2 + 1, "namespace, pvc, pods a+b, recreated pod b (no NetworkPolicy by default)")
        for m in kinds:
            if m[0] == "delete":
                self.assertIn(m[1], ("pod", "persistentvolumeclaim", "namespace"))
        self.assertEqual(kube.pods, {})
        self.assertFalse(kube.pvc or kube.ns_exists)
        # evidence written, sanitized, summary present
        for f in ("results.tsv", "summary.json", "preflight.json", "cleanup/verify.json", "timings.tsv"):
            self.assertTrue(os.path.exists(os.path.join(ev.dir, f)), f)
        self.assertEqual(ev.withheld, [])
        summ = json.load(open(os.path.join(ev.dir, "summary.json")))
        self.assertIsNone(summ["stop"])
        # one shared run (they are slow): no forbidden kubectl usage, exec only into scratch pods, many probes ran
        for line in kube.trace:
            self.assertNotRegex(line, r"--force|--grace-period|--dry-run|--now|\bpatch\b|\bscale\b|\bdrain\b|\bcordon\b|\bchown\b")
            self.assertNotRegex(line, r"get (secrets?|secret/)")
            if " exec " in line:
                self.assertRegex(line, r"exec -i rwx-[ab] -c ws --")
        self.assertGreater(kube.exec_count, 50)
        # restartPolicy Never pods: the observations recorded zero restarts at every checkpoint
        for f in os.listdir(os.path.join(ev.dir, "observe")):
            o = json.load(open(os.path.join(ev.dir, "observe", f)))
            for pod in o["scratch_pods"].values():
                self.assertEqual(pod["restarts"], {"ws": 0})


class TestStopConditions(SimBase):
    @unittest.skipIf(os.getuid() == 0, "root bypasses permissions")
    def test_write_gate_failure_stops_collects_and_cleans_up(self):
        r, kube, res, ev = self.runner()
        os.chmod(self.root, 0o555)
        self.addCleanup(os.chmod, self.root, 0o755)
        rc = r.run()
        self.assertEqual(rc, 3)
        rows = {t: s for t, s, _ in res.rows}
        self.assertEqual(rows.get("R02"), "FAIL")
        self.assertNotIn("R03", rows, "no test runs after the gate fails")
        self.assertEqual(rows["R14"], "PASS", "guarded cleanup ran and verified")
        self.assertEqual(kube.mutations[-1], ("delete", "namespace", NS))
        self.assertEqual(oct(os.stat(self.root).st_mode & 0o777), "0o555", "the harness must not chmod the volume root")
        self.assertTrue(any(os.path.isdir(os.path.join(ev.dir, d)) for d in ("collect-final",)))
        summ = json.load(open(os.path.join(ev.dir, "summary.json")))
        self.assertIn("gate", summ["stop"].lower())
        # no escalation: only applies of our manifests (ns, pvc, pods) and graceful deletes
        self.assertEqual([m for m in kube.mutations if m[0] == "apply"], [("apply", 1)] * 4)

    def test_same_node_stops(self):
        r, kube, res, ev = self.runner(node_b="node-x1")
        rc = r.run()
        self.assertEqual(rc, 3)
        self.assertNotIn("R02", {t for t, _, _ in res.rows})
        self.assertEqual(kube.mutations[-1], ("delete", "namespace", NS))

    def test_herdr_change_stops_midrun(self):
        r, kube, res, ev = self.runner()
        kube.herdr_flip_after = 30
        rc = r.run()
        self.assertEqual(rc, 3)
        self.assertTrue(any("Herdr" in d for _, s, d in res.rows if s == "FAIL"))
        self.assertEqual(kube.mutations[-1], ("delete", "namespace", NS), "cleanup still ran")
        r14 = [d for t, s, d in res.rows if t == "R14"][-1]
        self.assertIn("Herdr unchanged=False", r14)

    def test_preflight_stop_creates_nothing(self):
        r, kube, res, ev = self.runner()
        kube.ns_exists = True   # namespace already exists => stop before any mutation
        rc = r.run()
        self.assertEqual(rc, 3)
        self.assertEqual(kube.mutations, [])


class TestGuards(SimBase):
    """Items 1-6: identity, Herdr-node exclusion, maintenance window, hang handling, gate git smoke, scratch restarts."""

    def stop_row(self, res):
        return [d for _, s, d in res.rows if s == "FAIL" and d.startswith("STOP")] or [d for _, s, d in res.rows if s == "FAIL"]

    def assert_no_mutation(self, kube, rc):
        self.assertEqual(rc, 3)
        self.assertEqual(kube.mutations, [])

    def test_wrong_longhorn_tag_stops_before_creating(self):
        r, kube, res, _ = self.runner(setup=lambda k: setattr(k, "manager_tag", "v1.9.2"))
        self.assert_no_mutation(kube, r.run())
        self.assertIn("longhorn-manager image tag", self.stop_row(res)[0])

    def test_expected_tag_is_configurable(self):
        r, kube, res, _ = self.runner(setup=lambda k: setattr(k, "manager_tag", "v1.9.2"))
        r.expect_longhorn = "v1.9.2"
        r.r00()
        self.assertEqual(res.rows[-1][1], "PASS")

    def test_missing_or_duplicate_herdr_pod_stops(self):
        for n in (0, 2):
            r, kube, res, _ = self.runner(setup=lambda k, n=n: setattr(k, "herdr_pods", n))
            self.assert_no_mutation(kube, r.run())
            self.assertIn("exactly one pod", self.stop_row(res)[0])

    def test_fewer_than_two_candidate_nodes_excluding_herdr_node(self):
        r, kube, res, _ = self.runner(setup=lambda k: setattr(k, "nodes_list", ["node-x1", "node-x3"]))
        self.assert_no_mutation(kube, r.run())
        self.assertIn("excluding the Herdr node", self.stop_row(res)[0])

    def test_preflight_records_identity_and_candidates(self):
        r, kube, res, ev = self.runner()
        r.r00()
        snap = json.load(open(os.path.join(ev.dir, "preflight.json")))
        self.assertEqual(snap["identity"]["observed_tags"], ["v1.13.0"])
        self.assertEqual(len(snap["identity"]["candidate_nodes_excluding_herdr"]), 2)

    def test_maintenance_window_stops(self):
        for hh, mm in ((6, 30), (7, 0), (8, 29)):
            clock = lambda hh=hh, mm=mm: datetime(2026, 11, 19, hh, mm, tzinfo=timezone.utc)  # noqa: E731
            r, kube, res, _ = self.runner(clock=clock)
            self.assert_no_mutation(kube, r.run())
            self.assertIn("maintenance window", self.stop_row(res)[0])

    def test_outside_window_ok(self):
        for hh, mm in ((6, 29), (8, 30), (12, 0), (0, 0)):
            self.assertFalse(L.in_maintenance_window(datetime(2026, 11, 19, hh, mm, tzinfo=timezone.utc)), (hh, mm))

    def test_non_idle_upgrade_cr_stops_and_absent_crd_is_skipped(self):
        def setup(k):
            k.crds, k.crs = ["talosupgrades.tuppr.example"], ["InProgress"]
        r, kube, res, _ = self.runner(setup=setup)
        self.assert_no_mutation(kube, r.run())
        self.assertIn("upgrade CR", self.stop_row(res)[0])
        r, kube, res, _ = self.runner(setup=lambda k: (setattr(k, "crds", ["talosupgrades.tuppr.example"]), setattr(k, "crs", ["Completed"])))
        r.r00()
        self.assertEqual(res.rows[-1][1], "PASS")
        r, kube, res, _ = self.runner()          # no CRD at all
        r.r00()
        self.assertEqual(res.rows[-1][1], "PASS")

    def test_node_not_ready_or_cordoned_stops(self):
        for flag in ("notready", "cordoned"):
            r, kube, res, _ = self.runner(setup=lambda k, flag=flag: k.node_flags.update({"node-x2": flag}))
            self.assert_no_mutation(kube, r.run())
            self.assertIn(flag.replace("notready", "NotReady"), self.stop_row(res)[0])

    def test_node_goes_notready_midrun_stops_and_cleans_up(self):
        r, kube, res, _ = self.runner()
        orig = r.check_environment
        calls = {"n": 0}

        def flaky(label):
            calls["n"] += 1
            if calls["n"] == 8:
                kube.node_flags["node-x2"] = "notready"
            return orig(label)
        r.check_environment = flaky
        self.assertEqual(r.run(), 3)
        self.assertEqual(kube.mutations[-1], ("delete", "namespace", NS))

    def test_exec_timeout_is_hang_stop_with_evidence_and_cleanup(self):
        r, kube, res, ev = self.runner(setup=lambda k: setattr(k, "hang_after", 20))
        rc = r.run()
        self.assertEqual(rc, 3)
        self.assertTrue(any("NFS I/O hang suspected" in d for _, s, d in res.rows if s == "FAIL"))
        self.assertTrue(os.path.isdir(os.path.join(ev.dir, "collect-final")))
        self.assertEqual(kube.mutations[-1], ("delete", "namespace", NS), "graceful cleanup attempted")
        self.assertNotIn("R03", {t for t, _, _ in res.rows}, "no further tests after the hang")
        summ = json.load(open(os.path.join(ev.dir, "summary.json")))
        self.assertIn("hang", summ["stop"])

    def test_subprocess_timeout_expired_is_surfaced_as_hang(self):
        r, kube, res, ev = self.runner()

        def boom():
            raise subprocess.TimeoutExpired("kubectl", 7)
        r.r03 = boom
        self.assertEqual(r.run(), 3)
        self.assertTrue(any("hang suspected" in d for _, s, d in res.rows if s == "FAIL"))
        self.assertEqual(kube.mutations[-1], ("delete", "namespace", NS))

    def test_stuck_terminating_pod_reports_residue_without_force(self):
        r, kube, res, ev = self.runner(setup=lambda k: setattr(k, "stuck_pod", "rwx-b"))
        orig = r.r03

        def stop_now():
            orig()
            raise L.StopRun("test: stop to trigger cleanup")
        r.r03 = stop_now
        rc = r.run()
        self.assertEqual(rc, 5)
        row = [d for t, s, d in res.rows if t == "R14"][-1]
        self.assertIn("RESIDUE", row)
        self.assertIn("OWNER ACTION", row)
        self.assertNotIn(("delete", "namespace", NS), kube.mutations, "namespace not deleted while residue remains")
        self.assertNotIn(("delete", "persistentvolumeclaim", "rwx-scratch"), kube.mutations)
        for line in kube.trace:
            self.assertNotRegex(line, r"--force|--grace-period|patch|finalizers")

    def test_scratch_container_terminating_stops(self):
        r, kube, res, ev = self.runner(setup=lambda k: setattr(k, "terminated_after", 15))
        rc = r.run()
        self.assertEqual(rc, 3)
        self.assertTrue(any("terminated unexpectedly" in d for _, s, d in res.rows if s == "FAIL"))

    def test_par_raises_first_exception_without_waiting_for_slow_workers(self):
        import time as _t
        r, kube, res, _ = self.runner()

        def hang():
            raise L.HangSuspected("NFS I/O hang suspected: test")
        t0 = _t.monotonic()
        with self.assertRaises(L.HangSuspected):
            r.par(lambda: _t.sleep(3), hang)
        self.assertLess(_t.monotonic() - t0, 2.0)

    def test_observations_record_scratch_restarts_and_replica_nodes(self):
        r, kube, res, ev = self.runner()
        r.r00()
        r.create_resources()
        o = r.observe("t")
        self.assertEqual(o["scratch_pods"]["a"]["restarts"], {"ws": 0})
        self.assertIn("replica_nodes", o)
        self.assertEqual(len(o["share_manager_pods"]), 1)
        self.assertIn("image", o["share_manager_pods"][0])


if __name__ == "__main__":
    unittest.main()
