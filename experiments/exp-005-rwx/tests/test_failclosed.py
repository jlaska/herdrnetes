"""Fail-closed regression tests (EXP-005-RWX, PR #35 review blockers A, B, C). Deterministic and offline: a simulated kubectl
(tests/simkube.py) with failure injection; no cluster, no kubectl, no signing keys (all git is hermetic).

Run alone:  uv run --with pyyaml python -m unittest discover -s tests -p 'test_failclosed.py' -v

A  cleanup verification: only a clear NotFound / empty valid list is ABSENT; everything else is UNKNOWN -> UNVERIFIED (exit 6)
B  preflight and between-test invariants: any unreadable required input STOPs; nothing unreadable looks healthy/empty/unchanged
C  R02 positively proves NFSv4 + identity + non-root git on BOTH pods before R03-R14 may run
"""
import json
import os
import subprocess
import unittest

import simkube as K  # noqa: E402  (puts the harness on sys.path; must come first)
import rwxlib as L  # noqa: E402
import scenarios as S  # noqa: E402
from simkube import NS, PV, SimKube  # noqa: E402

# ---- failure injections: name -> CmdResult | exception factory
FORBIDDEN = L.CmdResult(1, "", 'Error from server (Forbidden): volumes.longhorn.io is forbidden: User "x" cannot list resource')
REFUSED = L.CmdResult(1, "", "The connection to the server localhost:8080 was refused - did you specify the right host or port?")
NO_TYPE = L.CmdResult(1, "", "error: the server doesn't have a resource type \"sharemanagers\"")
SERVER_5XX = L.CmdResult(1, "", "Error from server (InternalError): an error on the server (\"\") has prevented the request from succeeding")
EMPTY = L.CmdResult(0, "", "")
MALFORMED = L.CmdResult(0, '{"apiVersion": "v1", "items": [', "")
WRONG_SCHEMA = L.CmdResult(0, json.dumps({"kind": "Status", "status": "Failure", "message": "weird"}), "")
RC124 = L.CmdResult(124, "", "timeout after 60s")
TIMEOUT_EXC = subprocess.TimeoutExpired("kubectl", 60)
MODES = {"forbidden": FORBIDDEN, "refused": REFUSED, "no-resource-type": NO_TYPE, "5xx": SERVER_5XX, "empty": EMPTY,
         "malformed": MALFORMED, "wrong-schema": WRONG_SCHEMA, "timeout-rc124": RC124, "timeout-exception": TIMEOUT_EXC}
# "notfound" is the one answer that means ABSENT; it has its own tests (test_cleanup_notfound_*, test_*_notfound_*)
ALL_MODE_WORDS = ("notfound", "forbidden", "refused", "5xx", "no_resource_type", "timeout", "empty", "malformed", "wrong_schema")


def add_per_mode(cls, base, fn):
    """Generate one visible test method per failure mode (so `unittest -v` shows the coverage): test_<base>__<mode>."""
    for mode, inj in MODES.items():
        def t(self, mode=mode, inj=inj):
            fn(self, mode, inj)
        t.__name__ = f"test_{base}__{mode.replace('-', '_')}"
        t.__doc__ = f"{base}: failure mode {mode}"
        setattr(cls, t.__name__, t)

# cleanup-verification item -> command-line substrings of the reads that establish it (each is injected separately)
CLEANUP_READS = {
    "namespace": ["get namespace herdrnetes-exp005-rwx-20261119a -o json"],
    "pvc": ["get pvc rwx-scratch -o json"],
    "pv": ["get pv -o json", f"get pv {PV} -o json"],
    "longhorn_volume": ["get volumes.longhorn.io -o json", f"get volumes.longhorn.io {PV} -o json"],
    "share_manager_pod": [f"get pod share-manager-{PV} -o json", "get pods -l longhorn.io/share-manager="],
    "share_manager_cr": [f"get sharemanagers.longhorn.io {PV} -o json"],
    "share_manager_service": [f"get service {PV} -o json"],
    "volume_attachment": ["get volumeattachments.storage.k8s.io -o json"],
}


class CleanupBase(unittest.TestCase):
    def setUp(self):
        self._t = L.TIMEOUTS["cleanup"]
        L.TIMEOUTS["cleanup"] = 0.3                 # verification polling budget for tests (real value 300 s)
        self.addCleanup(lambda: L.TIMEOUTS.__setitem__("cleanup", self._t))
        self.tmp = __import__("tempfile").TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def cluster(self, with_np=True):
        k = SimKube(os.path.join(self.tmp.name, "rwx"))
        k.ns_exists, k.pvc, k.netpol = True, True, with_np
        k.pods = {"rwx-a": 1, "rwx-b": 2}
        k.nodes_ab = {"rwx-a": "node-x1", "rwx-b": "node-x2"}
        return k

    def go(self, kube, pv=PV, base=True):
        san = L.Sanitizer()
        ev = L.Evidence(os.path.join(self.tmp.name, "ev"), K.RUN, san)
        res = L.Results(echo=lambda *_: None)
        bh = L.herdr_facts(kube.herdr_obj()) if base else None
        bv = L.longhorn_volume_states(K.lst(kube.vols())) if base else None
        rc = S.run_cleanup(kube, ev, res, pv, bh, bv, K.HERDR_NS, "herdr-0", sleep=lambda *_: None)
        verify = None
        path = os.path.join(ev.dir, "cleanup", "verify.json")
        if os.path.exists(path):
            verify = K.jload(path)
        return rc, res, verify, ev


class TestClassifyRead(unittest.TestCase):
    """Pure tri-state classifier."""

    def c(self, r, **kw):
        return L.classify_read(r, **kw).state

    def test_not_found_is_absent_only_for_single_object(self):
        nf = L.CmdResult(1, "", 'Error from server (NotFound): pods "x" not found')
        self.assertEqual(self.c(nf, kind="Pod", name="x"), L.ABSENT)
        self.assertEqual(self.c(nf, is_list=True), L.UNKNOWN)

    def test_every_other_failure_is_unknown(self):
        for name, r in MODES.items():
            if isinstance(r, BaseException):
                continue
            self.assertEqual(self.c(r, kind="Pod", name="x"), L.UNKNOWN, name)
            self.assertEqual(self.c(r, is_list=True), L.UNKNOWN, name)

    def test_valid_empty_list_is_absent_nonempty_present(self):
        self.assertEqual(self.c(L.CmdResult(0, json.dumps(K.lst([])), ""), is_list=True), L.ABSENT)
        self.assertEqual(self.c(L.CmdResult(0, json.dumps(K.lst([K.obj("Pod", "p")])), ""), is_list=True), L.PRESENT)

    def test_list_schema_violations_are_unknown(self):
        for body in ({"kind": "List"}, {"kind": "List", "items": "x"}, {"kind": "List", "items": [1]}, {"items": []},
                     {"kind": "Pod", "items": []}, [], "x"):
            self.assertEqual(self.c(L.CmdResult(0, json.dumps(body), ""), is_list=True), L.UNKNOWN, body)

    def test_object_schema_violations_are_unknown(self):
        ok = K.obj("Pod", "p")
        self.assertEqual(self.c(L.CmdResult(0, json.dumps(ok), ""), kind="Pod", name="p"), L.PRESENT)
        self.assertEqual(self.c(L.CmdResult(0, json.dumps(ok), ""), kind="Service", name="p"), L.UNKNOWN)
        self.assertEqual(self.c(L.CmdResult(0, json.dumps(ok), ""), kind="Pod", name="other"), L.UNKNOWN)

    def test_dry_run_is_unknown(self):
        self.assertEqual(self.c(L.CmdResult(0, "", "dry-run")), L.UNKNOWN)

    def test_combine(self):
        A, P, U = L.Tri(L.ABSENT, None, ""), L.Tri(L.PRESENT, None, "p"), L.Tri(L.UNKNOWN, None, "u")
        self.assertEqual(L.combine(A, A).state, L.ABSENT)
        self.assertEqual(L.combine(A, U).state, L.UNKNOWN)
        self.assertEqual(L.combine(U, P).state, L.PRESENT)

    def test_kube_read_state_catches_subprocess_timeout(self):
        def boom(argv, input=None, timeout=None):
            raise TIMEOUT_EXC
        t = L.Kube("c", K.RUN, live=True, runner=boom, echo=lambda *_: None).read_state(["get", "nodes"], is_list=True, ns=False)
        self.assertEqual(t.state, L.UNKNOWN)
        self.assertIn("timeout", t.reason)

    def test_verify_cleanup_verdicts(self):
        A = L.Tri(L.ABSENT, None, "")
        allabs = {i: A for i in L.CLEANUP_ITEMS}
        self.assertEqual(L.verify_cleanup(allabs)["verdict"], "CLEAN")
        self.assertEqual(L.verify_cleanup({k: v for k, v in allabs.items() if k != "pv"})["verdict"], "UNVERIFIED", "missing item")
        self.assertEqual(L.verify_cleanup({**allabs, "pv": L.Tri(L.UNKNOWN, None, "x")})["verdict"], "UNVERIFIED")
        self.assertEqual(L.verify_cleanup({**allabs, "pv": L.Tri(L.PRESENT, None, "x")})["verdict"], "RESIDUE")
        self.assertEqual(L.verify_cleanup({})["verdict"], "UNVERIFIED")
        self.assertEqual([L.cleanup_exit_code(v) for v in ("CLEAN", "RESIDUE", "UNVERIFIED")], [0, 5, 6])


class TestCleanupFailClosed(CleanupBase):
    """BLOCKER A."""

    def test_baseline_everything_gone_is_clean(self):
        rc, res, v, _ = self.go(self.cluster())
        self.assertEqual(rc, 0, res.rows)
        self.assertEqual(res.rows[-1][1], "PASS")
        self.assertEqual(v["verdict"], "CLEAN")
        self.assertEqual(v["unknown"], [])

    def _unverified_for_mode(self, mode, inj):
        for item, keys in CLEANUP_READS.items():
            for key in keys:
                with self.subTest(item=item, read=key, mode=mode):
                    k = self.cluster()
                    k.fail_post = {key: inj}
                    rc, res, v, _ = self.go(k)
                    self.assertEqual(rc, L.EXIT_UNVERIFIED, (rc, res.rows[-1]))
                    self.assertNotEqual(res.rows[-1][1], "PASS")
                    self.assertEqual(v["verdict"], "UNVERIFIED")
                    self.assertIn(item, [u[0] for u in v["unknown"]], v["unknown"])
                    self.assertTrue(all(u[1] for u in v["unknown"]), "each unknown carries its reason")

    def test_cleanup_notfound_is_absent_for_each_object(self):
        # the baseline cluster answers NotFound for everything after deletion: all eight items positively ABSENT
        _, _, v, _ = self.go(self.cluster())
        self.assertEqual(sorted(v["facts"]), sorted(L.CLEANUP_ITEMS))
        self.assertTrue(all(f["state"] == L.ABSENT for f in v["facts"].values()), v["facts"])

    def test_mixed_all_absent_but_one_unknown(self):
        k = self.cluster()
        k.fail_post = {"get service": REFUSED}
        rc, res, v, _ = self.go(k)
        self.assertEqual(rc, 6)
        self.assertEqual([u[0] for u in v["unknown"]], ["share_manager_service"])
        self.assertEqual(v["present"], [])

    def test_present_leftover_is_residue_exit_5(self):
        for left in ("pv", "volume", "sm-pod", "svc", "va"):
            with self.subTest(left=left):
                k = self.cluster()
                k.leftover = {left}
                rc, res, v, _ = self.go(k)
                self.assertEqual(rc, L.EXIT_RESIDUE, (left, res.rows[-1]))
                self.assertEqual(v["verdict"], "RESIDUE")
                self.assertNotEqual(res.rows[-1][1], "PASS")

    def test_present_and_unknown_together_is_residue_with_unknowns_listed(self):
        k = self.cluster()
        k.leftover = {"pv"}
        k.fail_post = {"get volumeattachments": FORBIDDEN}
        rc, _, v, _ = self.go(k)
        self.assertEqual(rc, 5)
        self.assertTrue(v["present"] and v["unknown"])

    def test_polling_never_turns_a_final_unknown_into_absent(self):
        k = self.cluster()
        polls = {"n": 0}

        def always_unknown():
            polls["n"] += 1
            return REFUSED
        k.fail_post = {"get volumeattachments": always_unknown}
        rc, _, v, _ = self.go(k)
        self.assertGreater(polls["n"], 1, "verification re-polled")
        self.assertEqual(rc, 6)
        self.assertEqual(v["facts"]["volume_attachment"]["state"], L.UNKNOWN)

    def test_transient_unknown_then_positive_absent_may_settle_to_clean(self):
        k = self.cluster()
        calls = {"n": 0}

        def flaky():
            calls["n"] += 1
            return REFUSED if calls["n"] == 1 else K.NOT_FOUND
        k.fail_post = {f"get service {PV} -o json": flaky}
        rc, _, v, _ = self.go(k)
        self.assertEqual((rc, v["verdict"]), (0, "CLEAN"))

    def _unreadable_before_delete(self, mode, inj):
        for key in ("get namespace herdrnetes-exp005-rwx-20261119a", "get pvc,pod,"):
            with self.subTest(read=key, mode=mode):
                k = self.cluster()
                k.fail = {key: inj}
                rc, res, _, _ = self.go(k)
                self.assertEqual(rc, 6)
                self.assertEqual([m for m in k.mutations if m[0] == "delete"], [])

    def test_delete_failure_or_timeout_is_never_reported_as_cleaned(self):
        for target in ("pod rwx-b", "persistentvolumeclaim rwx-scratch", "networkpolicy default-deny-all", "namespace " + NS):
            for mode, inj in (("rc1", L.CmdResult(1, "", "error: timed out waiting for the condition")), ("timeout-rc124", RC124),
                              ("timeout-exception", TIMEOUT_EXC), ("forbidden", FORBIDDEN)):
                with self.subTest(target=target, mode=mode):
                    k = self.cluster()
                    k.fail = {f"delete {target}": inj}
                    rc, res, _, _ = self.go(k)
                    self.assertEqual(rc, L.EXIT_RESIDUE, res.rows[-1])
                    self.assertEqual(res.rows[-1][1], "FAIL")
                    self.assertIn("RESIDUE", res.rows[-1][2])
                    for line in k.trace:
                        self.assertNotRegex(line, r"--force|--grace-period|finalizers|patch")

    def test_unknown_pv_name_cannot_be_called_clean(self):
        k = self.cluster()
        k.pvc = False                      # the PVC is already gone and no volume name is known (standalone cleanup)
        rc, res, v, _ = self.go(k, pv=None, base=False)
        self.assertEqual(rc, 6)
        self.assertIn("share_manager_cr", [u[0] for u in v["unknown"]])
        k2 = self.cluster()
        k2.pvc = False
        rc2, _, v2, _ = self.go(k2, pv=PV, base=False)        # with --pv-name the check is possible
        self.assertEqual((rc2, v2["verdict"]), (0, "CLEAN"))

    def test_herdr_or_volume_inventory_unreadable_after_cleanup_is_unverified(self):
        for key in ("get pod herdr-0", "get volumes.longhorn.io -o json"):
            with self.subTest(read=key):
                k = self.cluster()
                k.fail_post = {key: REFUSED}
                rc, res, v, _ = self.go(k)
                self.assertEqual(rc, 6)
                self.assertNotEqual(res.rows[-1][1], "PASS")

    def test_changed_herdr_after_clean_cleanup_is_exit_7(self):
        k = self.cluster()
        base_h = L.herdr_facts(k.herdr_obj())
        k.herdr_uid = "different"
        san, res = L.Sanitizer(), L.Results(echo=lambda *_: None)
        ev = L.Evidence(os.path.join(self.tmp.name, "ev2"), K.RUN, san)
        rc = S.run_cleanup(k, ev, res, PV, base_h, L.longhorn_volume_states(K.lst(k.vols())), K.HERDR_NS, "herdr-0", sleep=lambda *_: None)
        self.assertEqual(rc, 7)
        self.assertEqual(res.rows[-1][1], "FAIL")

    def test_exact_name_and_selector_both_checked_for_share_manager_pod(self):
        k = self.cluster()
        self.go(k)
        self.assertTrue(any(f"get pod share-manager-{PV}" in line for line in k.trace))
        self.assertTrue(any("-l longhorn.io/share-manager=" in line for line in k.trace))

    def test_exit_codes_documented(self):
        with open(os.path.join(L.HERE, "rwx")) as fh:
            doc = fh.read()
        for needle in ("4 cleanup refused", "5 residue", "6 cleanup UNVERIFIED", "7 cleanup verified"):
            self.assertIn(needle, doc)


class TestPreflightFailClosed(K.SimBase):
    """BLOCKER B: R00."""

    def r00_stops(self, setup=None, **kw):
        r, kube, res, _ = self.runner(setup=setup, **kw)
        with self.assertRaises(L.StopRun):
            r.r00()
        self.assertEqual(kube.mutations, [], "preflight never mutates")
        return kube, res

    def test_baseline_passes(self):
        r, kube, res, ev = self.runner()
        r.r00()
        self.assertEqual(res.rows[-1][1], "PASS")

    def _volume_inventory_fails(self, mode, inj):
        self.r00_stops(lambda k: k.fail.update({"get volumes.longhorn.io -o json": inj}))

    def test_empty_longhorn_volume_inventory_is_suspicious_not_healthy(self):
        kube, res = self.r00_stops(lambda k: k.fail.update({"get volumes.longhorn.io -o json": L.CmdResult(0, json.dumps(K.lst([])), "")}))
        self.assertIn("not found or empty", res.rows[-1][2])

    def _other_required_reads(self, mode, inj):
        required = ["get nodes.longhorn.io -o json", "get settings.longhorn.io rwx-volume-fast-failover", "get storageclass longhorn",
                    "get csidriver driver.longhorn.io", "get nodes -o json", "get pods -o json", "get crd -o json",
                    "get pods -l app.kubernetes.io/name=herdr", "get sharemanagers.longhorn.io -o json",
                    "get namespace herdrnetes-exp -o json", "version -o json", "get pod herdr-0"]
        for key in required:
            with self.subTest(read=key, mode=mode):
                self.r00_stops(lambda k, key=key: k.fail.update({key: inj}))

    def test_herdr_baseline_unreadable_stops(self):
        # the pod LIST succeeds (identity) but the baseline read of the pod itself fails
        kube, res = self.r00_stops(lambda k: k.fail.update({"get pod herdr-0": REFUSED}))
        self.assertIn("baseline", res.rows[-1][2])

    def test_longhorn_node_not_ready_or_unschedulable_stops(self):
        bad = L.CmdResult(0, json.dumps(K.lst([K.obj("Node", "n", status={"conditions": [{"type": "Ready", "status": "True"},
                                                                                         {"type": "Schedulable", "status": "False"}]})])), "")
        self.r00_stops(lambda k: k.fail.update({"get nodes.longhorn.io -o json": bad}))

    def test_permission_check_not_yes_stops(self):
        for out in ("no\n", "", "yes-ish"):
            with self.subTest(out=out):
                self.r00_stops(lambda k, out=out: k.fail.update({"auth can-i create namespaces": L.CmdResult(1, out, "")}))

    def _crd_list_fails(self, mode, inj):
        self.r00_stops(lambda k: k.fail.update({"get crd -o json": inj}))

    def _cr_list_fails(self, mode, inj):
        for crd in ("talosupgrades.tuppr.example", "kubernetesupgrades.tuppr.example"):
            with self.subTest(crd=crd, mode=mode):
                self.r00_stops(lambda k, crd=crd: k.fail.update({f"get {crd} -A": inj}))

    def test_crd_list_missing_an_expected_upgrade_crd_stops(self):
        """D-10: a readable CRD list lacking either expected upgrade CRD is 'state unavailable', not idle."""
        for keep in ([], ["talosupgrades.tuppr.example"], ["kubernetesupgrades.tuppr.example"]):
            with self.subTest(crds=keep):
                kube, res = self.r00_stops(lambda k, keep=keep: setattr(k, "crds", keep))
                self.assertIn("upgrade controller state unavailable", res.rows[-1][2])

    def test_readable_but_empty_cr_list_for_an_expected_crd_stops(self):
        """PREFLIGHT.md observed one Completed object of each kind, so an empty list is not the normal state."""
        empty = L.CmdResult(0, json.dumps(K.lst([])), "")
        kube, res = self.r00_stops(lambda k: k.fail.update({"get talosupgrades.tuppr.example -A": empty}))
        self.assertIn("upgrade controller state unavailable", res.rows[-1][2])

    def test_both_upgrade_crds_present_and_completed_proceeds_and_records_vocabulary(self):
        r, kube, res, ev = self.runner()
        r.r00()
        self.assertEqual(res.rows[-1][1], "PASS")
        snap = K.jload(os.path.join(ev.dir, "preflight.json"))
        self.assertEqual(snap["identity"]["upgrade_cr_phases_observed"], ["kubernetesupgrades=Completed", "talosupgrades=Completed"])

    def test_upgrade_cr_phase_missing_empty_or_active_stops(self):
        for phases in ([None], [""], ["InProgress"], ["Completed", None], ["Idle"]):
            with self.subTest(phases=phases):
                self.r00_stops(lambda k, phases=phases: setattr(k, "crs", phases))

    def test_namespace_must_be_positively_absent(self):
        for mode in ("forbidden", "refused", "malformed", "timeout-exception"):
            with self.subTest(mode=mode):
                self.r00_stops(lambda k, mode=mode: k.fail.update({f"get namespace {NS}": MODES[mode]}))

    def test_maintenance_window_extends_over_the_three_hour_tuppr_window(self):
        from datetime import datetime, timezone
        for hh, mm in ((7, 0), (9, 59), (10, 29)):
            with self.subTest(t=(hh, mm)):
                self.r00_stops(clock=lambda hh=hh, mm=mm: datetime(2026, 11, 20, hh, mm, tzinfo=timezone.utc))


class TestInvariantsFailClosed(K.SimBase):
    """BLOCKER B: checks between tests (check_global)."""

    def ready(self):
        r, kube, res, ev = self.runner()
        r.r00()
        r.create_resources()
        r.check_global("baseline")           # healthy: must not stop
        return r, kube, res

    def stops(self, inj):
        r, kube, res = self.ready()
        kube.fail.update(inj)
        with self.assertRaises(L.StopRun) as cm:
            r.check_global("T")
        return str(cm.exception)

    def _inventory_unreadable(self, mode, inj):
        self.assertIn("inventory", self.stops({"get volumes.longhorn.io -o json": inj}))

    def test_empty_inventory_after_baseline_with_volumes_stops(self):
        msg = self.stops({"get volumes.longhorn.io -o json": L.CmdResult(0, json.dumps(K.lst([])), "")})
        self.assertIn("empty", msg)

    def _herdr_read_fails(self, mode, inj):
        self.assertIn("Herdr", self.stops({"get pod herdr-0": inj}))

    def test_node_list_and_upgrade_reads_unreadable_stop(self):
        for key in ("get nodes -o json", "get crd -o json"):
            for mode in ("forbidden", "timeout-exception", "malformed"):
                with self.subTest(read=key, mode=mode):
                    self.stops({key: MODES[mode]})

    def test_scratch_pod_unreadable_stops(self):
        for mode in ("forbidden", "timeout-exception", "empty"):
            with self.subTest(mode=mode):
                self.assertIn("unreadable", self.stops({"get pod rwx-a -o json": MODES[mode]}))

    def test_disk_probe_failure_stops(self):
        self.assertIn("unreadable", self.stops({" - df ": L.CmdResult(1, "", "boom")}))

    def test_missing_baseline_stops(self):
        stops, _ = L.check_invariants(None, {"uid": "u", "restarts": {}}, None, {"v": ("a", "healthy")})
        self.assertTrue(stops)
        stops, _ = L.check_invariants({"uid": "u", "restarts": {}}, {"uid": "u", "restarts": {}}, {"v": ("a", "healthy")}, None)
        self.assertTrue(any("unreadable" in s for s in stops))

    def test_longhorn_volume_states_rejects_unreadable_input(self):
        for bad in (None, {}, {"__error__": "x"}, {"items": "no"}):
            with self.assertRaises(ValueError):
                L.longhorn_volume_states(bad)

    def test_share_manager_observation_unreadable_stops_observe(self):
        r, kube, res = self.ready()
        for key in ("get sharemanagers.longhorn.io", "get service", "get replicas.longhorn.io", "get engines.longhorn.io",
                    "get pods -l longhorn.io/share-manager="):
            with self.subTest(read=key):
                kube.fail = {key: REFUSED}
                with self.assertRaises(L.StopRun):
                    r.observe("x")
        kube.fail = {}
        r.observe("ok")

    def test_attach_without_readable_baseline_stops(self):
        r, kube, res, _ = self.runner()
        kube.ns_exists, kube.pvc, kube.pods = True, True, {"rwx-a": 1, "rwx-b": 2}
        kube.fail = {"get pod herdr-0": REFUSED}
        with self.assertRaises(L.StopRun):
            r.attach()


class TestR02PositiveGate(K.SimBase):
    """BLOCKER C: both pods must positively prove NFSv4 + identity + non-root git before any later test starts."""

    def assert_blocks_r03(self, setup=None, needle=None):
        r, kube, res, ev = self.runner(setup=setup)
        rc = r.run()
        rows = {t: s for t, s, _ in res.rows}
        self.assertEqual(rc, 3, [x for x in res.rows if x[1] == "FAIL"])
        self.assertEqual(rows.get("R02"), "FAIL")
        self.assertFalse([t for t in rows if t.startswith(("R03", "R04", "R05", "R06", "R07", "R08", "R09", "R10", "R11", "R12", "R13"))],
                         "no test after R02 may start")
        self.assertEqual(kube.mutations[-1], ("delete", "namespace", NS), "guarded cleanup ran")
        if needle:
            self.assertIn(needle, " ".join(d for _, s, d in res.rows if s == "FAIL"))
        return res

    def test_baseline_passes_and_records_both_pods(self):
        r, kube, res, ev = self.runner()
        r.r00()
        r.create_resources()
        r.r02()
        rows = {t: s for t, s, _ in res.rows}
        self.assertEqual(rows["R02"], "PASS")
        for pod in ("a", "b"):
            for key in ("identity", "nfsv4", "gate"):
                self.assertEqual(rows[f"R02-{pod}-{key}"], "PASS")

    def test_wrong_fstype_on_one_pod_stops(self):
        for fs in ("ext4", "overlay", "tmpfs", "nfs", "xfs", None):
            for pod in ("rwx-a", "rwx-b"):
                with self.subTest(fstype=fs, pod=pod):
                    self.assert_blocks_r03(lambda k, fs=fs, pod=pod: k.mounts.update({pod: {"fstype": fs}}), "expected nfs4")

    def test_nfs_version_must_be_exactly_4_1(self):
        for vers in (None, "3", "4.0", "4.2", "4", "garbage", 4.1):
            with self.subTest(vers=vers):
                self.assert_blocks_r03(lambda k, vers=vers: k.mounts.update({"rwx-b": {"vers": vers}}), "vers")

    def test_nfs_4_1_on_both_pods_passes(self):
        r, kube, res, ev = self.runner(setup=lambda k: k.mounts.update({"rwx-a": {"vers": "4.1"}, "rwx-b": {"vers": "4.1"}}))
        r.r00()
        r.create_resources()
        r.r02()
        self.assertEqual(res.rows[-1][1], "PASS")

    def test_nfs_4_2_is_rejected(self):
        self.assert_blocks_r03(lambda k: k.mounts.update({"rwx-a": {"vers": "4.2"}, "rwx-b": {"vers": "4.2"}}), "expected exactly one of ('4.1',)")

    def test_sources_differ_between_pods_stops(self):
        self.assert_blocks_r03(lambda k: k.mounts.update({"rwx-b": {"source": "other-svc:/pvc-2"}}), "same NFS export")

    def test_uid_gid_mismatch_on_one_pod_stops(self):
        for pod in ("rwx-a", "rwx-b"):
            for field, val in (("uid", 1001), ("gid", 0), ("uid", 0)):
                with self.subTest(pod=pod, field=field, val=val):
                    self.assert_blocks_r03(lambda k, pod=pod, field=field, val=val: k.patch.update(
                        {(pod, "identity"): lambda o, field=field, val=val: dict(o, **{field: val})}), "uid/gid")

    def test_no_new_privs_or_capabilities_missing_on_second_pod_stops(self):
        self.assert_blocks_r03(lambda k: k.patch.update({("rwx-b", "identity"): lambda o: dict(o, no_new_privs="0")}), "NoNewPrivs")
        self.assert_blocks_r03(lambda k: k.patch.update({("rwx-b", "identity"): lambda o: dict(o, cap_eff="0000000000000400")}), "capabilities")

    def test_created_file_not_owned_by_1000_stops(self):
        def patch(o):
            o["steps"]["owner_is_caller"]["file_uid"] = 65534
            return o
        self.assert_blocks_r03(lambda k: k.patch.update({("rwx-b", "writegate"): patch}), "numerically")

    def test_git_smoke_failing_only_on_pod_b_stops(self):
        def patch(o):
            o["steps"]["git_smoke"] = dict(ok=False, errno="GIT", msg="git clone rc=128: fatal: Permission denied")
            o["ok"] = False
            return o
        res = self.assert_blocks_r03(lambda k: k.patch.update({("rwx-b", "writegate"): patch}), "Permission denied")
        self.assertIn("pod b", " ".join(d for _, s, d in res.rows if s == "FAIL"))

    def test_gate_step_missing_stops(self):
        def patch(o):
            del o["steps"]["git_smoke"]
            return o
        self.assert_blocks_r03(lambda k: k.patch.update({("rwx-a", "writegate"): patch}), "git_smoke missing")

    def test_unparseable_probe_output_stops(self):
        for pod, sub in (("rwx-a", "identity"), ("rwx-b", "identity"), ("rwx-a", "mountinfo"), ("rwx-b", "mountinfo"),
                         ("rwx-a", "writegate"), ("rwx-b", "writegate")):
            with self.subTest(pod=pod, probe=sub):
                self.assert_blocks_r03(lambda k, pod=pod, sub=sub: k.patch.update({(pod, sub): lambda o: None}), "unparseable")

    def test_mount_not_a_mount_point_of_its_own_stops(self):
        self.assert_blocks_r03(lambda k: k.patch.update({("rwx-a", "mountinfo"): lambda o: dict(o, mount=dict(o["mount"], mount_point="/"))}),
                               "mount point")

    def test_pure_evaluators(self):
        good = {"mount": {"mount_point": L.MOUNT, "fstype": "nfs4", "source": "s:/p", "mount_options": "rw", "super_options": "rw"},
                "nfs_options": {"vers": "4.1"}}
        self.assertTrue(L.evaluate_mount(good)[0])
        for bad in (None, {}, {"mount": None}, {"mount": {}}, dict(good, nfs_options={}), dict(good, nfs_options=None)):
            self.assertFalse(L.evaluate_mount(bad)[0], bad)
        self.assertTrue(L.evaluate_identity({"uid": 1000, "gid": 1000, "no_new_privs": "1", "cap_eff": "0000000000000000"})[0])
        for bad in (None, {}, {"uid": 1000, "gid": 1000}, {"uid": 1000, "gid": 1000, "no_new_privs": "1"},
                    {"uid": 1000, "gid": 1000, "no_new_privs": "1", "cap_eff": ""}):
            self.assertFalse(L.evaluate_identity(bad)[0], bad)


class TestMalformedAnswersNeverRaise(CleanupBase):
    """Malformed list items and arbitrary exceptions during cleanup verification are UNVERIFIED (exit 6), never a traceback or CLEAN."""

    def run_with(self, k):
        rc, res, v, _ = self.go(k)
        self.assertEqual(rc, 6, res.rows[-1])
        self.assertNotEqual(res.rows[-1][1], "PASS")
        return v

    def test_pv_list_item_without_metadata_is_unverified(self):
        k = self.cluster()
        k.fail_post = {"get pv -o json": L.CmdResult(0, json.dumps(K.lst([{"spec": {"claimRef": {"namespace": "x"}}}])), "")}
        v = self.run_with(k)
        self.assertIn("pv", [u[0] for u in v["unknown"]])

    def test_pv_list_item_with_non_dict_spec_or_non_dict_item_is_unverified(self):
        for item in ({"metadata": {"name": "p"}, "spec": "oops"}, {"metadata": "oops"}, {"metadata": {"name": 5}}):
            with self.subTest(item=item):
                k = self.cluster()
                k.fail_post = {"get pv -o json": L.CmdResult(0, json.dumps(K.lst([item])), "")}
                self.run_with(k)
        k = self.cluster()
        k.fail_post = {"get pv -o json": L.CmdResult(0, json.dumps({"kind": "List", "items": ["not-a-dict"]}), "")}
        self.run_with(k)

    def test_volume_attachment_item_without_spec_is_unverified(self):
        for item in (K.obj("VolumeAttachment", "va1"), K.obj("VolumeAttachment", "va1", spec="oops"),
                     K.obj("VolumeAttachment", "va1", spec={"source": "oops"}), {"spec": {"source": {}}}):
            with self.subTest(item=item):
                k = self.cluster()
                k.fail_post = {"get volumeattachments.storage.k8s.io": L.CmdResult(0, json.dumps(K.lst([item])), "")}
                v = self.run_with(k)
                self.assertIn("volume_attachment", [u[0] for u in v["unknown"]])

    def test_longhorn_volume_list_item_without_metadata_is_unverified(self):
        k = self.cluster()
        k.fail_post = {"get volumes.longhorn.io -o json": L.CmdResult(0, json.dumps(K.lst([{"status": {}}])), "")}
        v = self.run_with(k)
        self.assertIn("longhorn_volume", [u[0] for u in v["unknown"]])

    def test_arbitrary_exception_during_verification_is_unverified_exit_6(self):
        for exc in (RuntimeError("boom"), KeyError("metadata"), ValueError("x"), ZeroDivisionError()):
            with self.subTest(exc=type(exc).__name__):
                k = self.cluster()
                k.fail_post = {"get service": exc}
                rc, res, v, _ = self.go(k)
                self.assertEqual(rc, 6)
                self.assertIn("UNVERIFIED", res.rows[-1][2])
                self.assertIn(type(exc).__name__, res.rows[-1][2])
                self.assertEqual(v["verdict"], "UNVERIFIED")
                self.assertIn(type(exc).__name__, v["exception"])

    def test_standalone_rwx_cleanup_path_never_tracebacks(self):
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("rwx_cli", os.path.join(L.HERE, "rwx"))
        spec = importlib.util.spec_from_loader("rwx_cli", loader)
        cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cli)

        class R:
            res = L.Results(echo=lambda *_: None)

            def cleanup(self):
                raise RuntimeError("kaboom")
        self.assertEqual(cli.safe_cleanup(R()), 6)
        self.assertEqual(R.res.rows[-1][1], "FAIL")
        self.assertIn("UNVERIFIED", R.res.rows[-1][2])

        class Refusing:
            res = L.Results(echo=lambda *_: None)

            def cleanup(self):
                raise L.Refused("nope")
        self.assertEqual(cli.safe_cleanup(Refusing()), 4)


class TestEvaluatorsNeverRaise(unittest.TestCase):
    """evaluate_gate / evaluate_mount / evaluate_identity return failure reasons for wrongly typed probe output."""

    def good_gate(self):
        steps = {s: dict(ok=True) for s in ("create_write_fsync", "rename_file", "mkdir_rename_dir", "git_smoke")}
        steps["owner_is_caller"] = dict(ok=True, file_uid=1000, file_gid=1000)
        return dict(uid=1000, gid=1000, steps=steps, root_stat=dict(is_dir=True, uid=0, gid=0, mode=0o777))

    def test_gate_wrong_types(self):
        cases = {"steps list": dict(self.good_gate(), steps=[1, 2]), "steps string": dict(self.good_gate(), steps="ok"),
                 "steps None": dict(self.good_gate(), steps=None), "step value not dict": dict(self.good_gate(), steps={"git_smoke": "ok"}),
                 "step value None": dict(self.good_gate(), steps={"git_smoke": None}), "root_stat list": dict(self.good_gate(), root_stat=[1]),
                 "root_stat string": dict(self.good_gate(), root_stat="x"), "root_stat None": dict(self.good_gate(), root_stat=None),
                 "uid string": dict(self.good_gate(), uid="1000"), "uid float": dict(self.good_gate(), uid=1000.0),
                 "mode string": dict(self.good_gate(), root_stat=dict(is_dir=True, uid=5, gid=5, mode="777")),
                 "msg not string": dict(self.good_gate(), steps=dict(self.good_gate()["steps"], git_smoke=dict(ok=False, msg=["x"]))),
                 "file_uid string": dict(self.good_gate(), steps=dict(self.good_gate()["steps"], owner_is_caller=dict(ok=True, file_uid="1000"))),
                 "a list": [], "a string": "x", "None": None, "an int": 5}
        self.assertTrue(L.evaluate_gate(self.good_gate())[0])
        for name, case in cases.items():
            with self.subTest(case=name):
                ok, why = L.evaluate_gate(case)
                self.assertFalse(ok)
                self.assertTrue(why and all(isinstance(w, str) for w in why))

    def test_mount_wrong_types(self):
        good = {"mount": {"mount_point": L.MOUNT, "fstype": "nfs4", "source": "s:/p"}, "nfs_options": {"vers": "4.1"}}
        self.assertTrue(L.evaluate_mount(good)[0])
        cases = {"mount list": dict(good, mount=[1]), "mount string": dict(good, mount="x"), "fstype list": dict(good, mount=dict(good["mount"], fstype=["nfs4"])),
                 "fstype int": dict(good, mount=dict(good["mount"], fstype=4)), "mount_point list": dict(good, mount=dict(good["mount"], mount_point=[L.MOUNT])),
                 "source int": dict(good, mount=dict(good["mount"], source=5)), "source list": dict(good, mount=dict(good["mount"], source=["a"])),
                 "vers int": dict(good, nfs_options={"vers": 4}), "vers float": dict(good, nfs_options={"vers": 4.1}),
                 "vers list": dict(good, nfs_options={"vers": ["4.1"]}), "vers dict": dict(good, nfs_options={"vers": {}}),
                 "options list": dict(good, nfs_options=["vers=4.1"]), "options None": dict(good, nfs_options=None),
                 "a list": [], "None": None, "a string": "x"}
        for name, case in cases.items():
            with self.subTest(case=name):
                ok, why, _ = L.evaluate_mount(case)
                self.assertFalse(ok)
                self.assertTrue(why and all(isinstance(w, str) for w in why))

    def test_identity_wrong_types(self):
        good = {"uid": 1000, "gid": 1000, "no_new_privs": "1", "cap_eff": "0000000000000000"}
        self.assertTrue(L.evaluate_identity(good)[0])
        cases = {"uid str": dict(good, uid="1000"), "gid None": dict(good, gid=None), "uid float": dict(good, uid=1000.0),
                 "uid bool": dict(good, uid=True), "cap_eff int": dict(good, cap_eff=0), "cap_eff list": dict(good, cap_eff=["0"]),
                 "cap_eff None": dict(good, cap_eff=None), "nnp int": dict(good, no_new_privs=1), "a list": [], "None": None, "a str": "x"}
        for name, case in cases.items():
            with self.subTest(case=name):
                ok, why = L.evaluate_identity(case)
                self.assertFalse(ok)
                self.assertTrue(why and all(isinstance(w, str) for w in why))

    def test_missing_upgrade_crds_helper_and_crd_names_tolerate_malformed_items(self):
        self.assertEqual(L.missing_upgrade_crds({"items": [{"metadata": {"name": "talosupgrades.x"}}]}), ["kubernetesupgrade"])
        self.assertEqual(L.missing_upgrade_crds({"items": [{}, {"metadata": None}]}), ["talosupgrade", "kubernetesupgrade"])
        self.assertEqual(L.upgrade_crd_names({"items": [{}, {"metadata": {"name": 5}}, {"metadata": {"name": "talosupgrades.x"}}]}), ["talosupgrades.x"])


class TestEveryFailureModeIsVisible(unittest.TestCase):
    """Makes coverage of each failure mode visible in `unittest -v` output (and fails if a mode loses its tests)."""

    def test_each_mode_has_generated_test_methods(self):
        names = " ".join(dir(TestCleanupFailClosed) + dir(TestPreflightFailClosed) + dir(TestInvariantsFailClosed))
        for word in ALL_MODE_WORDS:
            self.assertIn(word, names, f"no visible test method for failure mode {word}")
        for base in ("cleanup_unverified", "cleanup_unreadable_before_delete", "preflight_volume_inventory", "preflight_required_reads",
                     "preflight_crd_list", "preflight_cr_list", "invariants_volume_inventory", "invariants_herdr_read"):
            for mode in MODES:
                owner = TestCleanupFailClosed if base.startswith("cleanup") else TestPreflightFailClosed if base.startswith("preflight") else TestInvariantsFailClosed
                self.assertTrue(hasattr(owner, f"test_{base}__{mode.replace('-', '_')}"), (base, mode))


add_per_mode(TestCleanupFailClosed, "cleanup_unverified", TestCleanupFailClosed._unverified_for_mode)
add_per_mode(TestCleanupFailClosed, "cleanup_unreadable_before_delete", TestCleanupFailClosed._unreadable_before_delete)
add_per_mode(TestPreflightFailClosed, "preflight_volume_inventory", TestPreflightFailClosed._volume_inventory_fails)
add_per_mode(TestPreflightFailClosed, "preflight_required_reads", TestPreflightFailClosed._other_required_reads)
add_per_mode(TestPreflightFailClosed, "preflight_crd_list", TestPreflightFailClosed._crd_list_fails)
add_per_mode(TestPreflightFailClosed, "preflight_cr_list", TestPreflightFailClosed._cr_list_fails)
add_per_mode(TestInvariantsFailClosed, "invariants_volume_inventory", TestInvariantsFailClosed._inventory_unreadable)
add_per_mode(TestInvariantsFailClosed, "invariants_herdr_read", TestInvariantsFailClosed._herdr_read_fails)


if __name__ == "__main__":
    unittest.main()
