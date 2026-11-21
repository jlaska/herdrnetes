"""Unit tests for harness/rwxlib.py and scenarios.py logic (EXP-005-RWX). No cluster, no kubectl."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "harness"))
import rwxlib as L  # noqa: E402
import scenarios as S  # noqa: E402

RUN = "20261119a"
NS = L.namespace_for(RUN)


class Recorder:
    """Fake kubectl runner: records argv, returns canned CmdResults."""

    def __init__(self, responses=None):
        self.calls, self.responses = [], responses or {}

    def __call__(self, argv, input=None, timeout=None):
        self.calls.append(argv)
        for key, res in self.responses.items():
            if key in " ".join(argv):
                return res
        return L.CmdResult(0, "{}", "")


def kube(live=True, execute=False, runner=None, run=RUN):
    return L.Kube("ctx-test", run, live=live, execute=execute, runner=runner or Recorder(), echo=lambda *_: None)


class TestRunIdAndNames(unittest.TestCase):
    def test_valid(self):
        for ok in ("20261119a", "a", "r-1", "a" * 24):
            self.assertEqual(L.valid_run_id(ok), ok)
        self.assertEqual(NS, "herdrnetes-exp005-rwx-20261119a")

    def test_invalid(self):
        for bad in ("", "A1", "-a", "a-", "a_b", "a" * 25, "a b", "../x", "x;rm", None):
            with self.assertRaises(L.Refused, msg=repr(bad)):
                L.valid_run_id(bad)

    def test_namespace_fits_63(self):
        self.assertLessEqual(len(L.namespace_for("a" * 24)), 63)

    def test_node_selector(self):
        self.assertEqual(L.parse_node_selector(""), {})
        self.assertEqual(L.parse_node_selector("topology.kubernetes.io/zone=z1"), {"topology.kubernetes.io/zone": "z1"})
        with self.assertRaises(L.Refused):
            L.parse_node_selector("a=b,c=d")


class TestModes(unittest.TestCase):
    def test_offline_never_runs_runner(self):
        r = Recorder()
        k = kube(live=False, runner=r)
        k.read(["get", "nodes"], ns=False)
        k.apply(L.render("pvc", RUN))
        k.delete("pod", "rwx-a")
        k.exec("rwx-a", ["true"])
        self.assertEqual(r.calls, [])
        self.assertGreaterEqual(len(k.trace), 4)

    def test_live_without_execute_never_mutates(self):
        lab = {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: RUN}
        r = Recorder({"get pod rwx-a": L.CmdResult(0, json.dumps({"metadata": {"name": "rwx-a", "namespace": NS, "labels": lab}}), ""),
                      f"get namespace {NS}": L.CmdResult(0, json.dumps({"metadata": {"name": NS, "labels": lab}}), "")})
        k = kube(live=True, execute=False, runner=r)
        k.apply(L.render("pvc", RUN))
        k.delete("pod", "rwx-a")
        k.delete("namespace", NS)
        self.assertFalse(any("delete" in c or "apply" in c for c in r.calls), r.calls)  # reads only
        self.assertTrue(any("get" in c for c in r.calls))

    def test_execute_runs_apply(self):
        r = Recorder()
        k = kube(execute=True, runner=r)
        k.apply(L.render("pvc", RUN))
        self.assertEqual(r.calls[0][:5], ["kubectl", "--context", "ctx-test", "apply", "-f"])

    def test_live_requires_context(self):
        with self.assertRaises(L.Refused):
            L.Kube(None, RUN, live=True)
        L.Kube(None, RUN, live=False)  # offline needs none


class TestMutationGuards(unittest.TestCase):
    def check_refused(self, argv):
        with self.assertRaises(L.Refused, msg=str(argv)):
            L.validate_mutation(argv, NS, RUN)

    def test_allowed(self):
        self.assertEqual(L.validate_mutation(["apply", "-f", "-"], NS, RUN), "apply")
        self.assertEqual(L.validate_mutation(["delete", "pod", "rwx-b", "--wait=true", "--timeout=120s"], NS, RUN), "delete-pod")
        self.assertEqual(L.validate_mutation(["delete", "persistentvolumeclaim", "rwx-scratch"], NS, RUN), "delete-persistentvolumeclaim")
        self.assertEqual(L.validate_mutation(["delete", "namespace", NS, "--wait=false"], NS, RUN), "delete-namespace")

    def test_refused(self):
        for argv in (["delete", "pod", "rwx-b", "--force"], ["delete", "pod", "rwx-b", "--grace-period=0"],
                     ["delete", "pod", "rwx-b", "--now"], ["delete", "pod", "--all"], ["delete", "pod", "-l", "a=b"],
                     ["delete", "pv", "pvc-123"], ["delete", "volumes.longhorn.io", "pvc-1"],
                     ["delete", "pod", "x", "--cascade=orphan"], ["delete", "namespace", "herdrnetes-exp"],
                     ["delete", "namespace", "kube-system"], ["delete", "pod", "../x"], ["delete", "storageclass", "longhorn"],
                     ["apply", "-f", "x.yaml"], ["apply", "-f", "-", "--server-side"], ["patch", "pod", "x"],
                     ["scale", "deploy/x"], ["delete", "pod", "x", "--dry-run=server"], ["drain", "node"], ["cordon", "n"],
                     ["delete", "pod", "x", "-A"], ["exec", "-n", "kube-system", "p", "--", "sh"], ["edit", "pod"],
                     ["label", "pod", "x", "a=b"], ["annotate", "pod", "x", "a=b"], ["replace", "-f", "-"]):
            self.check_refused(argv)

    def test_apply_refuses_foreign_manifest(self):
        k = kube(execute=True)
        with self.assertRaises(L.Refused):
            k.apply(L.render("pvc", RUN).replace(NS, "default"))
        with self.assertRaises(L.Refused):
            k.apply("apiVersion: storage.k8s.io/v1\nkind: StorageClass\nmetadata:\n  name: x\n")

    def test_delete_guard_requires_labels(self):
        def runner_for(labels):
            doc = {"metadata": {"name": "rwx-b", "namespace": NS, "labels": labels}}
            return Recorder({"get pod rwx-b": L.CmdResult(0, json.dumps(doc), "")})
        good = {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: RUN}
        r = runner_for(good)
        kube(execute=True, runner=r).delete("pod", "rwx-b")
        self.assertTrue(any(c[3] == "-n" and "delete" in c for c in r.calls))
        for bad in ({}, {L.EXP_LABEL: L.EXPERIMENT}, {L.EXP_LABEL: "exp-005", L.RUN_LABEL: RUN},
                    {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: "other"}):
            r = runner_for(bad)
            with self.assertRaises(L.Refused):
                kube(execute=True, runner=r).delete("pod", "rwx-b")
            self.assertFalse(any("delete" in c for c in r.calls))

    def test_delete_guard_wrong_namespace(self):
        doc = {"metadata": {"name": "rwx-b", "namespace": "other", "labels": {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: RUN}}}
        r = Recorder({"get pod rwx-b": L.CmdResult(0, json.dumps(doc), "")})
        with self.assertRaises(L.Refused):
            kube(execute=True, runner=r).delete("pod", "rwx-b")

    def test_namespace_delete_checks_labels(self):
        doc = {"metadata": {"name": NS, "labels": {}}}
        r = Recorder({f"get namespace {NS}": L.CmdResult(0, json.dumps(doc), "")})
        with self.assertRaises(L.Refused):
            kube(execute=True, runner=r).delete("namespace", NS)

    def test_exec_only_scratch_pods(self):
        k = kube()
        with self.assertRaises(L.Refused):
            k.exec("herdr-0", ["id"])
        with self.assertRaises(L.Refused):
            k.exec("share-manager-x", ["id"])


class TestReadGuards(unittest.TestCase):
    def test_reads(self):
        for argv in (["get", "nodes"], ["describe", "pods"], ["version", "-o", "json"], ["auth", "can-i", "create", "pods"],
                     ["config", "get-contexts", "-o", "name"], ["get", "pods", "-l", "a=b", "-o", "json"]):
            self.assertTrue(L.validate_read(argv))

    def test_refused_reads(self):
        for argv in (["get", "secrets"], ["get", "secret", "x"], ["describe", "secrets"], ["get", "pods", "-w"],
                     ["delete", "pod", "x"], ["apply", "-f", "-"], ["get", "pods", "--dry-run=server"], ["exec", "p"],
                     ["get", "pods", "--raw", "/x"], ["get", "pods", "--as", "root"], ["logs", "p", "--kubeconfig", "x"]):
            with self.assertRaises(L.Refused, msg=str(argv)):
                L.validate_read(argv)

    def test_no_secret_kind_in_inventory_list(self):
        self.assertNotRegex(S.INV_KINDS, r"secret")


class TestEnvironmentGuards(unittest.TestCase):
    def mgr(self, *tags):
        return {"items": [{"metadata": {"name": f"longhorn-manager-{i}"},
                           "spec": {"containers": [{"name": "longhorn-manager", "image": f"longhornio/longhorn-manager:{t}"}]}}
                          for i, t in enumerate(tags)] + [{"metadata": {"name": "instance-manager-x"}, "spec": {"containers": [{"name": "x", "image": "a:v0"}]}}]}

    def herdr(self, name="herdr-0", owner="StatefulSet"):
        return {"items": [{"metadata": {"name": name, "ownerReferences": [{"kind": owner}]}}]}

    def test_image_tag(self):
        self.assertEqual(L.image_tag("longhornio/longhorn-manager:v1.13.0"), "v1.13.0")
        self.assertEqual(L.image_tag("registry:5000/x/y:v2@sha256:ab"), "v2")
        self.assertEqual(L.image_tag("registry:5000/x/y@sha256:ab"), "")
        self.assertEqual(L.image_tag("x/y"), "")

    def test_identity_ok_and_failures(self):
        ok = L.identity_stops("v1.13.0", L.longhorn_manager_tags(self.mgr("v1.13.0", "v1.13.0")), {"metadata": {}}, self.herdr(), "herdr-0")
        self.assertEqual(ok, [])
        self.assertTrue(L.identity_stops("v1.13.0", L.longhorn_manager_tags(self.mgr("v1.13.0", "v1.12.0")), {"metadata": {}}, self.herdr(), "herdr-0"))
        self.assertTrue(L.identity_stops("v1.13.0", [], {"metadata": {}}, self.herdr(), "herdr-0"))
        self.assertTrue(L.identity_stops("v1.13.0", ["v1.13.0"], {"__error__": "nf"}, self.herdr(), "herdr-0"))
        self.assertTrue(L.identity_stops("v1.13.0", ["v1.13.0"], {"metadata": {}}, {"items": []}, "herdr-0"))
        self.assertTrue(L.identity_stops("v1.13.0", ["v1.13.0"], {"metadata": {}}, {"items": self.herdr()["items"] * 2}, "herdr-0"))
        self.assertTrue(L.identity_stops("v1.13.0", ["v1.13.0"], {"metadata": {}}, self.herdr("other-0"), "herdr-0"))
        self.assertTrue(L.identity_stops("v1.13.0", ["v1.13.0"], {"metadata": {}}, self.herdr(owner="Deployment"), "herdr-0"))

    def node(self, name, ready=True, cordoned=False, taints=None):
        return {"metadata": {"name": name}, "spec": {"unschedulable": cordoned, **({"taints": taints} if taints else {})},
                "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}}

    def test_candidate_nodes_exclude_herdr_node_and_unhealthy(self):
        nodes = {"items": [self.node("a"), self.node("b"), self.node("h"), self.node("c", cordoned=True), self.node("d", ready=False),
                           self.node("e", taints=[{"key": "x"}])]}
        self.assertEqual(L.candidate_nodes(nodes, "h"), ["a", "b"])
        self.assertEqual(len(L.node_health_stops(nodes)), 2)
        self.assertEqual(L.node_health_stops({"items": [self.node("a")]}), [])

    def test_window(self):
        from datetime import datetime, timezone
        f = lambda h, m: L.in_maintenance_window(datetime(2026, 1, 1, h, m, tzinfo=timezone.utc))  # noqa: E731
        self.assertEqual([f(6, 29), f(6, 30), f(7, 0), f(10, 29), f(10, 30)], [False, True, True, True, False])

    def test_upgrade_crds_and_phases(self):
        crds = {"items": [{"metadata": {"name": "talosupgrades.tuppr.example"}}, {"metadata": {"name": "kubernetesupgrades.tuppr.example"}},
                          {"metadata": {"name": "volumes.longhorn.io"}}]}
        self.assertEqual(len(L.upgrade_crd_names(crds)), 2)
        self.assertEqual(L.upgrade_crd_names({"items": []}), [])
        self.assertEqual(L.upgrade_stops([("c", "n", "Completed")]), [])
        for ph in ("InProgress", "Pending", "Failed", "Upgrading", "weird", "", None, "Idle", "Ready"):   # only the observed 'Completed' is idle
            self.assertTrue(L.upgrade_stops([("c", "n", ph)]), ph)

    def pod(self, **kw):
        base = {"status": {"phase": "Running", "containerStatuses": [{"name": "ws", "restartCount": 0, "state": {"running": {}}}]}}
        base["status"].update(kw)
        return base

    def test_scratch_pod_stops(self):
        self.assertEqual(L.scratch_pod_stops(self.pod(), "rwx-a"), [])
        self.assertTrue(L.scratch_pod_stops(self.pod(phase="Failed"), "rwx-a"))
        self.assertTrue(L.scratch_pod_stops(self.pod(containerStatuses=[{"name": "ws", "restartCount": 1}]), "rwx-a"))
        self.assertTrue(L.scratch_pod_stops(self.pod(containerStatuses=[{"name": "ws", "restartCount": 0, "state": {"terminated": {}}}]), "rwx-a"))
        self.assertTrue(L.scratch_pod_stops({"__error__": "x"}, "rwx-a"))


class TestHangHandling(unittest.TestCase):
    def test_exec_timeout_raises_hang_suspected_a_stoprun(self):
        r = Recorder({"exec": L.CmdResult(124, "", "timeout after 30s")})
        with self.assertRaises(L.HangSuspected) as cm:
            kube(runner=r).exec("rwx-a", ["python3", "-I", "-", "locktry"], timeout=30)
        self.assertIn("NFS I/O hang suspected", str(cm.exception))
        self.assertTrue(issubclass(L.HangSuspected, L.StopRun))

    def test_non_timeout_failure_is_not_a_hang(self):
        r = Recorder({"exec": L.CmdResult(1, "", "boom")})
        self.assertEqual(kube(runner=r).exec("rwx-a", ["true"]).rc, 1)

    def test_subprocess_runner_reports_timeouts_as_rc124(self):
        res = L.subprocess_runner([sys.executable, "-c", "import time; time.sleep(5)"], timeout=0.5)
        self.assertEqual(res.rc, 124)
        self.assertTrue(res.err.startswith("timeout"))

    def test_reap_terminates_leftover_local_clients(self):
        import subprocess as sp
        k = L.Kube("c", RUN, live=True, popen=lambda argv, **kw: sp.Popen([sys.executable, "-c", "import time; time.sleep(60)"], **kw),
                   echo=lambda *_: None)
        k.popen_exec("rwx-a", ["true"], stdin="")
        self.assertEqual(k.reap(), 1)
        self.assertEqual(k.procs, [])


class TestInvariants(unittest.TestCase):
    H = {"uid": "u1", "restarts": {"herdr": 0, "ovis": 4}}

    def test_unchanged(self):
        stops, _ = L.check_invariants(self.H, dict(self.H), {"v1": ("attached", "healthy")}, {"v1": ("attached", "healthy")})
        self.assertEqual(stops, [])

    def test_herdr_uid_or_restart_change_stops(self):
        s, _ = L.check_invariants(self.H, {"uid": "u2", "restarts": self.H["restarts"]}, {"v": ("a", "healthy")}, {"v": ("a", "healthy")})
        self.assertTrue(any("UID" in x for x in s))
        s, _ = L.check_invariants(self.H, {"uid": "u1", "restarts": {"herdr": 1, "ovis": 4}}, {"v": ("a", "healthy")}, {"v": ("a", "healthy")})
        self.assertTrue(any("restart" in x for x in s))
        s, _ = L.check_invariants(self.H, None, {"v": ("a", "healthy")}, {"v": ("a", "healthy")})
        self.assertTrue(s)

    def test_other_volume_degraded_stops_but_scratch_ignored(self):
        base = {"v1": ("attached", "healthy"), "scratch": ("detached", "unknown")}
        s, _ = L.check_invariants(None, None, base, {"v1": ("attached", "degraded"), "scratch": ("attached", "degraded")}, "scratch", baseline_required=False)
        self.assertEqual(len(s), 1)
        self.assertIn("v1", s[0])

    def test_benign_robustness_transition_is_info(self):
        s, i = L.check_invariants(None, None, {"v1": ("detached", "unknown")}, {"v1": ("attached", "healthy")}, baseline_required=False)
        self.assertEqual(s, [])
        self.assertTrue(i)

    def test_same_node_stops(self):
        s, _ = L.check_invariants(None, None, {}, {}, nodes_a_b=("n1", "n1"), baseline_required=False)
        self.assertTrue(s)
        s, _ = L.check_invariants(None, None, {}, {}, nodes_a_b=("n1", "n2"), baseline_required=False)
        self.assertEqual(s, [])

    def test_helpers(self):
        self.assertTrue(L.pods_on_different_nodes("a", "b"))
        self.assertFalse(L.pods_on_different_nodes("a", "a"))
        self.assertFalse(L.pods_on_different_nodes(None, "a"))
        pj = {"metadata": {"uid": "x"}, "status": {"containerStatuses": [{"name": "c", "restartCount": 2}]}}
        self.assertEqual(L.herdr_facts(pj), {"uid": "x", "restarts": {"c": 2}})
        self.assertIsNone(L.herdr_facts({"__error__": "nf"}))


class TestGate(unittest.TestCase):
    def good(self):
        steps = {s: dict(ok=True) for s in ("create_write_fsync", "rename_file", "mkdir_rename_dir", "git_smoke")}
        steps["owner_is_caller"] = dict(ok=True, file_uid=1000, file_gid=1000)
        return dict(uid=1000, gid=1000, steps=steps, root_stat=dict(is_dir=True, uid=0, gid=0, mode=0o777))

    def test_ok(self):
        self.assertEqual(L.evaluate_gate(self.good())[0], True)

    def test_write_failure_stops(self):
        g = self.good()
        g["steps"]["create_write_fsync"] = dict(ok=False, errno="EACCES")
        ok, why = L.evaluate_gate(g)
        self.assertFalse(ok)
        self.assertIn("EACCES", " ".join(why))

    def test_rename_failure_stops(self):
        g = self.good()
        g["steps"]["rename_file"] = dict(ok=False, errno="EPERM")
        self.assertFalse(L.evaluate_gate(g)[0])

    def test_unexpected_ownership_stops(self):
        g = self.good()
        g["root_stat"]["uid"] = 65534
        self.assertFalse(L.evaluate_gate(g)[0])
        g = self.good()
        g["uid"] = 0
        self.assertFalse(L.evaluate_gate(g)[0])

    def test_empty_probe_output_stops(self):
        self.assertFalse(L.evaluate_gate({})[0])
        self.assertFalse(L.evaluate_gate(dict(uid=1000, gid=1000, steps={}, root_stat={"is_dir": True, "uid": 0, "gid": 0}))[0])


class TestCleanupPlan(unittest.TestCase):
    NSOBJ = {"metadata": {"name": NS, "labels": {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: RUN}}}
    LAB = {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: RUN}

    def inv(self, *items):
        return [dict(kind=k, name=n, labels=lab) for k, n, lab in items]

    def test_happy_path_order(self):
        inv = self.inv(("PersistentVolumeClaim", "rwx-scratch", self.LAB), ("Pod", "rwx-b", self.LAB), ("Pod", "rwx-a", self.LAB),
                       ("ConfigMap", "kube-root-ca.crt", {}), ("ServiceAccount", "default", {}))
        p = L.plan_cleanup(inv, self.NSOBJ, RUN)
        self.assertEqual(p["refusals"], [])
        self.assertEqual(p["deletes"], [("pod", "rwx-a"), ("pod", "rwx-b"), ("persistentvolumeclaim", "rwx-scratch")])
        self.assertTrue(p["delete_ns"])

    def test_refuses_unlabelled_object(self):
        p = L.plan_cleanup(self.inv(("Pod", "x", {})), self.NSOBJ, RUN)
        self.assertTrue(p["refusals"])
        self.assertFalse(p["delete_ns"])

    def test_refuses_other_run_id_object(self):
        p = L.plan_cleanup(self.inv(("Pod", "x", {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: "zzz"})), self.NSOBJ, RUN)
        self.assertTrue(p["refusals"])

    def test_refuses_unexpected_kinds(self):
        for kind in ("Deployment", "StatefulSet", "Job", "Service", "Secret", "Role"):
            p = L.plan_cleanup(self.inv((kind, "x", self.LAB)), self.NSOBJ, RUN)
            self.assertTrue(p["refusals"], kind)

    def test_refuses_unlabelled_namespace(self):
        for labels in ({}, {L.EXP_LABEL: L.EXPERIMENT}, {L.EXP_LABEL: "exp-005", L.RUN_LABEL: RUN},
                       {L.EXP_LABEL: L.EXPERIMENT, L.RUN_LABEL: "other"}):
            p = L.plan_cleanup([], {"metadata": {"name": NS, "labels": labels}}, RUN)
            self.assertTrue(p["refusals"], labels)
            self.assertFalse(p["delete_ns"])

    def test_refuses_wrong_namespace_name(self):
        p = L.plan_cleanup([], {"metadata": {"name": "herdrnetes-exp", "labels": self.LAB}}, RUN)
        self.assertTrue(p["refusals"])

    def test_absent_namespace_is_noop(self):
        p = L.plan_cleanup([], None, RUN)
        self.assertEqual((p["refusals"], p["deletes"], p["delete_ns"]), ([], [], False))


class TestSanitizer(unittest.TestCase):
    def san(self):
        return L.Sanitizer(["talos-abc-1", "talos-abc-2"], ["mycluster", "corp.example"], context_name="admin@mycluster")

    def test_nodes_become_aliases_stable(self):
        s = self.san()
        out = s.text("pod on talos-abc-2 and talos-abc-1; talos-abc-1.lab.internal")
        self.assertIn("<node-2>", out)
        self.assertIn("<node-1>", out)
        self.assertNotIn("talos-abc", out)
        self.assertEqual(s.alias("talos-abc-1"), "<node-1>")

    def test_ips_domains_apiserver_context(self):
        s = self.san()
        raw = ("source 10.43.12.7:/pvc-1 clientaddr=192.168.1.5 server https://api.lab.internal:6443 host fileserver.home "
               "ctx admin@mycluster cluster mycluster ipv6 fd00:1::2 mac aa:bb:cc:dd:ee:ff user /home/jlaska/x 127.0.0.1")
        out = s.text(raw)
        for leak in ("10.43", "192.168", "api.lab.internal", "fileserver.home", "mycluster", "fd00", "aa:bb", "jlaska"):
            self.assertNotIn(leak, out)
        self.assertIn("127.0.0.1", out)
        self.assertIn("<apiserver>", out)
        self.assertEqual(s.leaks(out), [])

    def test_tokens_and_keys(self):
        s = self.san()
        raw = ("Authorization: Bearer abcdef123456\ntoken: s3cr3tvalue\npassword=hunter2\n"
               "jwt eyJhbGciOiJI.eyJzdWIiOiIx.abcdefghijk ghp_" + "a" * 30 + "\n"
               "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\nautomountServiceAccountToken: false\n")
        out = s.text(raw)
        for leak in ("abcdef123456", "s3cr3tvalue", "hunter2", "eyJhbGci", "ghp_", "AAAA"):
            self.assertNotIn(leak, out)
        self.assertIn("automountServiceAccountToken: false", out)
        self.assertEqual(s.leaks(out), [])

    def test_leaks_detected_on_unsanitized(self):
        s = self.san()
        self.assertIn("node name", s.leaks("on talos-abc-1"))
        self.assertIn("ipv4", s.leaks("1.2.3.4"))
        self.assertIn("token", s.leaks("ghp_" + "b" * 30))

    def test_plain_text_and_digests_survive(self):
        s = self.san()
        t = "image ghcr.io/x@sha256:" + "ab" * 32 + " at 12:34:56 git 2.47.3 pvc-6f1c2d3e-aaaa-bbbb-cccc-1234567890ab"
        self.assertEqual(s.text(t), t)

    def test_evidence_writer_sanitizes_and_withholds(self):
        s = self.san()
        with tempfile.TemporaryDirectory() as d:
            ev = L.Evidence(d, RUN, s)
            p = ev.write("raw/a.txt", "node talos-abc-1 ip 10.0.0.9")
            txt = open(p).read()
            self.assertNotIn("talos", txt)
            self.assertNotIn("10.0.0.9", txt)
            # force a residual leak: a sanitizer whose own rules miss a pattern the scanner catches
            s2 = L.Sanitizer(["n1"])
            s2.text = lambda x: x  # simulate a sanitizer bug
            ev2 = L.Evidence(d, "b1", s2)
            self.assertIsNone(ev2.write("x.txt", "host n1 ip 10.1.2.3"))
            self.assertTrue(os.path.exists(os.path.join(ev2.dir, "x.txt.WITHHELD")))
            self.assertFalse(os.path.exists(os.path.join(ev2.dir, "x.txt")))
            with open(os.path.join(ev2.dir, "x.txt.WITHHELD")) as f:
                self.assertNotIn("10.1.2.3", f.read())

    def test_evidence_rejects_path_escape_and_disabled_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            ev = L.Evidence(d, RUN, L.Sanitizer())
            for bad in ("../x", "/etc/x", "a/../../x"):
                with self.assertRaises(L.Refused):
                    ev.write(bad, "x")
            off = L.Evidence(d, "off1", L.Sanitizer(), enabled=False)
            self.assertIsNone(off.write("x", "y"))
            self.assertFalse(os.path.exists(os.path.join(d, "off1")))

    def test_dict_payload(self):
        with tempfile.TemporaryDirectory() as d:
            ev = L.Evidence(d, RUN, self.san())
            p = ev.write("a.json", {"node": "talos-abc-1"})
            self.assertIn("<node-1>", open(p).read())


class TestStats(unittest.TestCase):
    def test_summarize(self):
        s = L.summarize([3, 1, 2, 10, 4])
        self.assertEqual((s["n"], s["min"], s["median"], s["max"]), (5, 1.0, 3.0, 10.0))
        self.assertEqual(L.summarize([]), {"n": 0})
        self.assertEqual(L.summarize([2, 4])["median"], 3.0)

    def test_parse_probe_output(self):
        self.assertEqual(L.parse_probe_output("noise\n{\"a\": 1}\n"), {"a": 1})
        self.assertEqual(L.parse_probe_output("nothing"), {})
        self.assertEqual(L.parse_probe_output('{"a":1}\ntrailing junk {x}'), {"a": 1})

    def test_results(self):
        r = L.Results(echo=lambda *_: None)
        r.rec("R01", "PASS", "x")
        r.rec("R02", "FAIL", "y")
        self.assertEqual(r.failed(), ["R02"])
        self.assertEqual(r.counts(), {"PASS": 1, "FAIL": 1})
        with self.assertRaises(ValueError):
            r.rec("R03", "MAYBE")

    def test_matrix_complete(self):
        self.assertEqual([m[0] for m in L.MATRIX], [f"R{i:02d}" for i in range(15)])


class TestPlanDocs(unittest.TestCase):
    def test_plan_md_covers_every_test(self):
        text = open(os.path.join(L.EXP_DIR, "PLAN.md")).read()
        for tid, _ in L.MATRIX:
            self.assertIn(f"| {tid} |", text, f"{tid} missing from PLAN.md matrix")

    def test_scenarios_define_every_test_method(self):
        for name in ("r00", "create_resources", "r02", "r03", "r04", "r05", "r06", "r07", "r08", "r09", "r10", "r11", "r12", "r13"):
            self.assertTrue(hasattr(S.Runner, name), name)


if __name__ == "__main__":
    unittest.main()
