"""End-to-end simulation of Runner (R00-R14) against a simulated kubectl backed by LOCAL processes. No cluster.

SimKube keeps every real guard of rwxlib.Kube (validation, label guard, allow-list) and replaces only the final
`kubectl` call: `exec` runs the probe/git/request-repo locally under a temp directory standing in for /rwx, and
get/apply/delete are answered from a small in-memory model of the cluster.
"""
import os
import subprocess
import unittest
from datetime import datetime, timezone

import simkube as K  # noqa: E402  (puts the harness on sys.path; must come first)
import rwxlib as L  # noqa: E402
from simkube import NOON, NS  # noqa: E402,F401


class TestFullSimulation(K.SimBase):
    def test_full_run_passes_and_cleans_up(self):
        r, kube, res, ev = self.runner()
        rc = r.run()
        rows = {t: (s, d) for t, s, d in res.rows}
        for tid in ["R00", "R02", "R03", "R04", "R05", "R06", "R07", "R08", "R09", "R10", "R11", "R12", "R13", "R14"]:
            self.assertIn(tid, rows, f"{tid} not recorded")
        self.assertEqual(res.failed(), [], [x for x in res.rows if x[1] == "FAIL"])
        self.assertEqual(rc, 0)
        self.assertEqual(rows["R14"][0], "PASS", rows["R14"])
        # mutation log: only apply/delete of our objects, namespace deleted last, pod B recreated once
        kinds = [m for m in kube.mutations]
        self.assertEqual(kinds[-1], ("delete", "namespace", NS))
        applies = [m for m in kinds if m[0] == "apply"]
        self.assertEqual(len(applies), 1 + 1 + 1 + 2 + 1, "namespace, NetworkPolicy (default on), pvc, pods a+b, recreated pod b")
        self.assertIn(("delete", "networkpolicy", "default-deny-all"), kinds)
        for m in kinds:
            if m[0] == "delete":
                self.assertIn(m[1], ("pod", "persistentvolumeclaim", "networkpolicy", "namespace"))
        self.assertEqual(kube.pods, {})
        self.assertFalse(kube.pvc or kube.ns_exists)
        # evidence written, sanitized, summary present
        for f in ("results.tsv", "summary.json", "preflight.json", "cleanup/verify.json", "timings.tsv"):
            self.assertTrue(os.path.exists(os.path.join(ev.dir, f)), f)
        self.assertEqual(ev.withheld, [])
        summ = K.jload(os.path.join(ev.dir, "summary.json"))
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
            o = K.jload(os.path.join(ev.dir, "observe", f))
            for pod in o["scratch_pods"].values():
                self.assertEqual(pod["restarts"], {"ws": 0})


class TestStopConditions(K.SimBase):
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
        summ = K.jload(os.path.join(ev.dir, "summary.json"))
        self.assertIn("gate", summ["stop"].lower())
        # no escalation: only applies of our manifests (ns, pvc, pods) and graceful deletes
        self.assertEqual([m for m in kube.mutations if m[0] == "apply"], [("apply", 1)] * 5)

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


class TestGuards(K.SimBase):
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
            self.assertRegex(self.stop_row(res)[0], "exactly one pod|Herdr pod list")

    def test_fewer_than_two_candidate_nodes_excluding_herdr_node(self):
        r, kube, res, _ = self.runner(setup=lambda k: setattr(k, "nodes_list", ["node-x1", "node-x3"]))
        self.assert_no_mutation(kube, r.run())
        self.assertIn("excluding the Herdr node", self.stop_row(res)[0])

    def test_preflight_records_identity_and_candidates(self):
        r, kube, res, ev = self.runner()
        r.r00()
        snap = K.jload(os.path.join(ev.dir, "preflight.json"))
        self.assertEqual(snap["identity"]["observed_tags"], ["v1.13.0"])
        self.assertEqual(len(snap["identity"]["candidate_nodes_excluding_herdr"]), 2)

    def test_maintenance_window_stops(self):
        for hh, mm in ((6, 30), (7, 0), (8, 29)):
            clock = lambda hh=hh, mm=mm: datetime(2026, 11, 19, hh, mm, tzinfo=timezone.utc)  # noqa: E731
            r, kube, res, _ = self.runner(clock=clock)
            self.assert_no_mutation(kube, r.run())
            self.assertIn("maintenance window", self.stop_row(res)[0])

    def test_outside_window_ok(self):
        for hh, mm in ((6, 29), (10, 30), (12, 0), (0, 0)):
            self.assertFalse(L.in_maintenance_window(datetime(2026, 11, 19, hh, mm, tzinfo=timezone.utc)), (hh, mm))

    def test_non_idle_upgrade_cr_stops_and_completed_proceeds(self):
        r, kube, res, _ = self.runner(setup=lambda k: setattr(k, "crs", ["InProgress"]))
        self.assert_no_mutation(kube, r.run())
        self.assertIn("upgrade CR", self.stop_row(res)[0])
        r, kube, res, _ = self.runner()          # both CRDs present, Completed (the default, as observed in PREFLIGHT.md)
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
        summ = K.jload(os.path.join(ev.dir, "summary.json"))
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
