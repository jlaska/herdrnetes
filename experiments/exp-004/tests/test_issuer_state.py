#!/usr/bin/env python3
"""Deterministic unit tests for the issuer's token state machine (EXP-004, no network, stdlib only).

    python3 -I tests/test_issuer_state.py -v

issuer.gh is replaced by an in-process fake whose delete() blocks on threading.Event objects the
test controls. Ordering is never established by sleeping: a test knows a revoker is waiting because
make_issuer() wraps issuer.lock.wait_for to count entries (a revoker that enters wait_for with its
predicate false is blocked on the condition). The only real time is the short deadlines in the
"deadline expiry" tests, which are what is being tested.

RevocationAccounting invariant: an unresolved or failed revocation is never counted as success.
ReinstatePersistence invariant: a client must not regain authorization unless the reinstatement
state has been durably committed (mock backend; os.replace / save_state patched to fail or block).

    python3 -I tests/test_issuer_state.py ReinstatePersistence -v   # one class
"""

import importlib.util
import json
import os
import tempfile
import threading
import time
import unittest
import hashlib
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("issuer", os.path.join(HERE, "..", "harness", "issuer.py"))
issuer_mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(issuer_mod)

SAFETY = 20  # seconds: only a stuck test ever waits this long


class FakeGH:
    """Stands in for issuer.GitHub. delete() blocks until the test releases that token (or all)."""

    def __init__(self):
        self.calls = []  # tokens, one entry per DELETE received
        self.started = {}  # token -> Event set when its DELETE has begun
        self.gates = {}  # token -> Event; delete() waits on it (absent: no gate)
        self.status = {}  # token -> HTTP status to answer (default 204)
        self.default_status = 204
        self.issuer = None
        self.lock_was_free = []  # one bool per DELETE: could another thread take issuer.lock?
        self._mu = threading.Lock()

    def started_event(self, token):
        with self._mu:
            return self.started.setdefault(token, threading.Event())

    def gate(self, token):
        with self._mu:
            return self.gates.setdefault(token, threading.Event())

    def delete(self, token):
        got = []
        probe = threading.Thread(target=lambda: got.append(self._try_lock()))
        probe.start()
        probe.join(SAFETY)
        with self._mu:
            self.calls.append(token)
            self.lock_was_free.append(bool(got and got[0]))
        self.started_event(token).set()
        g = self.gates.get(token)
        if g is not None:
            assert g.wait(SAFETY), "test left a DELETE gate closed"
        return self.status.get(token, self.default_status)

    def _try_lock(self):
        if self.issuer.lock.acquire(blocking=False):
            self.issuer.lock.release()
            return True
        return False


def make_issuer(tmpdir, backend="github", gh_timeout=10, settle=None):
    """Issuer with the fake GitHub client installed. -> (issuer, fake_gh).
    wait_for is wrapped: issuer.waits is the number of wait_for entries and issuer.wait_event(n)
    blocks until at least n entries have happened."""
    state = os.path.join(tmpdir, "revoked.json")
    with open(state, "w") as f:
        f.write("[]")
    os.chmod(state, 0o600)
    policy = {"ttl_seconds": 3600,
              "github": {"api_url": "http://127.0.0.1:1", "app_id": "Iv1.synthetic", "owner": "acme",
                         "installation_id": 42, "private_key_file": os.path.join(tmpdir, "unused.pem")},
              "clients": {"c1": {"secret_sha256": "0" * 64, "repos": {"acme/a": "write"}},
                          "c2": {"secret_sha256": "0" * 64, "repos": {"acme/a": "write"}}}}
    iss = issuer_mod.Issuer(policy, b"", "admin-synthetic", state, backend, gh_timeout)
    fake = FakeGH()
    fake.issuer = iss
    if backend == "github":
        iss.gh = fake
    if settle is not None:
        iss.settle_timeout = settle
    iss.waits, cond, orig = 0, threading.Condition(), iss.lock.wait_for
    iss.waits_cond = cond

    def counted(predicate, timeout=None):
        with cond:
            iss.waits += 1
            cond.notify_all()
        return orig(predicate, timeout)

    def wait_event(n):
        with cond:
            assert cond.wait_for(lambda: iss.waits >= n, SAFETY), "revoker never started waiting"

    iss.lock.wait_for, iss.wait_event = counted, wait_event
    return iss, fake


def add_token(iss, name, client="c1", ttl=3600, state=None):
    tok = "ghs_synthetic_" + name
    iss.finish_mint(tok, int(time.time()) + ttl, "acme/a", "write", client)
    if state:
        iss.tokens[tok]["state"] = state
    return tok


class Run(threading.Thread):
    """Run fn in a thread, capture its result or the issuer_mod.Refuse message."""

    def __init__(self, fn, *args, **kw):
        super().__init__(daemon=True)
        self.fn, self.args, self.kw, self.result, self.error = fn, args, kw, None, None
        self.start()

    def run(self):
        try:
            self.result = self.fn(*self.args, **self.kw)
        except issuer_mod.Refuse as e:
            self.error = str(e)

    def finish(self):
        self.join(SAFETY)
        assert not self.is_alive(), "thread did not finish"
        return self


class RevocationAccounting(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.iss, self.gh = make_issuer(self._td.name)

    def open_gate(self, tok):
        self.gh.gate(tok)  # creates the gate if the DELETE has not started yet
        self.gh.gates[tok].set()

    def pending_revoke(self, tok, status=204):
        """Start revoke_token(tok) and park it inside DELETE. -> its Run."""
        self.gh.status[tok] = status
        self.gh.gate(tok)
        t = Run(self.iss.revoke, tok)
        self.assertTrue(self.gh.started_event(tok).wait(SAFETY))
        self.assertEqual(self.iss.tokens[tok]["state"], "revoking")
        return t

    # --- single-token races ---------------------------------------------------------------
    def test_concurrent_revoke_waits_and_reports_real_success(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok)
        b = Run(self.iss.revoke, tok)
        self.iss.wait_event(1)
        self.assertTrue(b.is_alive(), "second revoker must wait, not answer early")
        self.open_gate(tok)
        a.finish(), b.finish()
        self.assertEqual(a.result, {"revoked": 1})
        self.assertEqual(b.result, {"revoked": 1, "note": "revoked by a concurrent request"})
        self.assertEqual(self.gh.calls, [tok])

    def test_concurrent_revoke_reports_real_failure_and_does_not_retry(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok, status=500)
        b = Run(self.iss.revoke, tok)
        self.iss.wait_event(1)
        self.open_gate(tok)
        a.finish(), b.finish()
        self.assertIn("revocation failed at GitHub (HTTP 500)", a.error)
        self.assertIsNone(b.result, "a concurrent failure must never be reported as revoked")
        self.assertIn("concurrent revocation failed at GitHub (HTTP 500)", b.error)
        self.assertEqual(self.gh.calls, [tok], "a failure concurrent with us is not retried by us")
        self.assertEqual(self.iss.tokens[tok]["state"], "failed")
        # a LATER revoke, after the failure completed, does retry
        self.gh.status[tok] = 204
        self.assertEqual(self.iss.revoke(tok), {"revoked": 1})
        self.assertEqual(self.gh.calls, [tok, tok])

    def test_unreachable_failure_message(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok, status=None)
        b = Run(self.iss.revoke, tok)
        self.iss.wait_event(1)
        self.open_gate(tok)
        a.finish(), b.finish()
        self.assertIn("(HTTP unreachable)", b.error)

    def test_revoke_deadline_expiry_is_unknown_not_success(self):
        iss, gh = make_issuer(self._td.name, settle=0.2)
        tok = add_token(iss, "a")
        gh.gate(tok)
        a = Run(iss.revoke, tok)
        self.assertTrue(gh.started_event(tok).wait(SAFETY))
        with self.assertRaises(issuer_mod.Refuse) as cm:
            iss.revoke(tok)
        self.assertIn("revocation outcome unknown", str(cm.exception))
        self.assertEqual(iss.tokens[tok]["state"], "revoking")
        gh.gates[tok].set()
        a.finish()

    def test_already_revoked_is_not_deleted_again(self):
        tok = add_token(self.iss, "a")
        self.assertEqual(self.iss.revoke(tok), {"revoked": 1})
        self.assertEqual(self.iss.revoke(tok), {"revoked": 1, "note": "already revoked"})
        self.assertEqual(self.gh.calls, [tok])

    def test_401_counts_as_revoked_other_statuses_do_not(self):
        t1, t2 = add_token(self.iss, "a"), add_token(self.iss, "b")
        self.gh.status[t1], self.gh.status[t2] = 401, 403
        self.assertEqual(self.iss.revoke(t1), {"revoked": 1})
        with self.assertRaises(issuer_mod.Refuse):
            self.iss.revoke(t2)
        self.assertEqual((self.iss.tokens[t1]["state"], self.iss.tokens[t2]["state"]), ("revoked", "failed"))

    def test_many_concurrent_revokers_one_delete(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok)
        n = 8
        others = [Run(self.iss.revoke, tok) for _ in range(n)]
        self.iss.wait_event(n)
        self.open_gate(tok)
        a.finish()
        notes = [o.finish().result.get("note") for o in others]
        self.assertEqual(self.gh.calls, [tok], "exactly one DELETE however many revokers")
        self.assertEqual(notes, ["revoked by a concurrent request"] * n)

    # --- revoke_all / shutdown ------------------------------------------------------------
    def test_revoke_all_waits_for_pending_revoke_and_counts_it(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok)
        b = Run(self.iss.revoke_all)
        self.iss.wait_event(1)
        self.assertTrue(b.is_alive(), "revoke_all must not report while a DELETE is pending")
        self.open_gate(tok)
        a.finish(), b.finish()
        self.assertEqual(self.gh.calls, [tok])
        self.assertEqual({k: b.result[k] for k in ("revoked", "failed", "unresolved", "concurrent", "ok")},
                         {"revoked": 1, "failed": 0, "unresolved": 0, "concurrent": 1, "ok": True})

    def test_revoke_all_reports_concurrent_failure(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok, status=500)
        b = Run(self.iss.revoke_all)
        self.iss.wait_event(1)
        self.open_gate(tok)
        a.finish(), b.finish()
        self.assertFalse(b.result["ok"])
        self.assertEqual((b.result["failed"], b.result["revoked"]), (1, 0))
        self.assertIn("fallback", b.result)

    def test_revoke_all_deadline_expiry_is_unresolved_never_ok(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok)
        res = self.iss.revoke_all(deadline=time.monotonic() + 0.2)
        self.assertEqual((res["revoked"], res["failed"], res["unresolved"]), (0, 0, 1))
        self.assertFalse(res["ok"])
        self.assertIn("fallback", res)
        self.open_gate(tok)
        a.finish()

    def test_unresolved_own_delete_when_workers_still_running(self):
        tok = add_token(self.iss, "a")
        self.gh.gate(tok)
        res = self.iss.revoke_all(deadline=time.monotonic() + 0.2)  # our own DELETE is stuck
        self.assertEqual(res["unresolved"], 1)
        self.assertFalse(res["ok"])
        self.open_gate(tok)

    def test_revoke_all_concurrent_callers_delete_each_token_once(self):
        toks = [add_token(self.iss, str(i)) for i in range(5)]
        for t in toks:
            self.gh.gate(t)
        first = Run(self.iss.revoke_all)
        for t in toks:
            self.assertTrue(self.gh.started_event(t).wait(SAFETY))
        others = [Run(self.iss.revoke_all) for _ in range(3)]
        self.iss.wait_event(1 + 3)
        for t in toks:
            self.open_gate(t)
        results = [r.finish().result for r in [first] + others]
        self.assertEqual(sorted(self.gh.calls), sorted(toks), "one DELETE per token")
        for r in results:
            self.assertEqual((r["revoked"], r["failed"], r["unresolved"], r["ok"]), (5, 0, 0, True))
        self.assertEqual([r["concurrent"] for r in results], [0, 5, 5, 5])

    def test_shutdown_waits_for_pending_delete_then_clean(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok)
        s = Run(self.iss.shutdown, 0)
        self.iss.wait_event(2)  # 1: drain wait (immediately true), 2: waiting for the DELETE
        self.assertTrue(s.is_alive(), "shutdown must not finish while a DELETE is pending")
        self.open_gate(tok)
        a.finish(), s.finish()
        clean, res = s.result
        self.assertTrue(clean)
        self.assertEqual((res["failed"], res["unresolved"], res["residual"], res["inflight_abandoned"]),
                         (0, 0, 0, 0))

    def test_shutdown_not_clean_when_pending_delete_fails(self):
        tok = add_token(self.iss, "a")
        a = self.pending_revoke(tok, status=500)
        s = Run(self.iss.shutdown, 0)
        self.iss.wait_event(2)
        self.open_gate(tok)
        a.finish(), s.finish()
        clean, res = s.result
        self.assertFalse(clean)
        self.assertFalse(res["ok"])
        self.assertEqual((res["failed"], res["residual"]), (1, 1))
        self.assertIn("fallback", res)

    def test_shutdown_deadline_expiry_is_not_clean(self):
        iss, gh = make_issuer(self._td.name, settle=0.2)
        tok = add_token(iss, "a")
        gh.gate(tok)
        a = Run(iss.revoke, tok)
        self.assertTrue(gh.started_event(tok).wait(SAFETY))
        clean, res = iss.shutdown(0)
        self.assertFalse(clean)
        self.assertEqual((res["unresolved"], res["residual"], res["ok"]), (1, 1, False))
        gh.gates[tok].set()
        a.finish()

    def test_shutdown_inflight_mint_abandoned_is_not_clean(self):
        add_token(self.iss, "a")
        self.iss.inflight = 1  # a mint that never returns
        clean, res = self.iss.shutdown(0.05)
        self.assertFalse(clean)
        self.assertEqual(res["inflight_abandoned"], 1)
        self.assertEqual((res["failed"], res["residual"]), (0, 0))  # tokens were revoked; still not clean

    def test_shutdown_invariant_scan_catches_what_counters_miss(self):
        tok = add_token(self.iss, "a")
        orig = self.iss._execute

        def lie(claimed, targets, deadline, expired=0):
            orig(claimed, targets, deadline, expired)
            with self.iss.lock:  # a record slips back to failed after the counters were taken
                self.iss.tokens[tok]["state"] = "failed"
            return {"revoked": 1, "failed": 0, "unresolved": 0, "concurrent": 0, "expired_skipped": 0,
                    "ok": True}

        self.iss._execute = lie
        clean, res = self.iss.shutdown(0)
        self.assertFalse(clean)
        self.assertEqual(res["residual"], 1)

    def test_shutdown_clean_after_concurrent_revocations(self):
        toks = [add_token(self.iss, str(i)) for i in range(3)]
        runs = [Run(self.iss.revoke, t) for t in toks]
        [r.finish() for r in runs]
        clean, res = self.iss.shutdown(0)
        self.assertTrue(clean)
        self.assertEqual((res["revoked"], res["failed"], res["unresolved"], res["residual"]), (0, 0, 0, 0))
        self.assertEqual(sorted(self.gh.calls), sorted(toks))

    def test_expired_tokens_are_skipped_with_skew(self):
        gone = add_token(self.iss, "gone", ttl=-3600)  # expired beyond the 60 s skew
        skew = add_token(self.iss, "skew", ttl=-30)  # expired by the clock but inside the skew: still live
        res = self.iss.revoke_all()
        self.assertEqual((res["revoked"], res["expired_skipped"], res["ok"]), (1, 1, True))
        self.assertEqual(self.gh.calls, [skew])
        self.assertEqual(self.iss.tokens[gone]["state"], "active")
        clean, r = self.iss.shutdown(0)  # `gone` is expired: not residual
        self.assertTrue(clean, r)

    def test_failed_token_is_retried_by_later_revoke_all(self):
        tok = add_token(self.iss, "a")
        self.gh.status[tok] = 500
        self.assertFalse(self.iss.revoke_all()["ok"])
        self.gh.status[tok] = 204
        res = self.iss.revoke_all()
        self.assertEqual((res["revoked"], res["ok"]), (1, True))
        self.assertEqual(self.gh.calls, [tok, tok])

    # --- revoke_client / finish_mint / handler paths --------------------------------------
    def test_revoke_client_reflects_pending_revoke_token_failure(self):
        tok = add_token(self.iss, "a", client="c1")
        other = add_token(self.iss, "b", client="c2")
        a = self.pending_revoke(tok, status=500)
        b = Run(self.iss.revoke_client, {"client": "c1"})
        self.iss.wait_event(1)
        self.assertTrue(b.is_alive())
        self.open_gate(tok)
        a.finish(), b.finish()
        self.assertFalse(b.result["ok"])
        self.assertEqual((b.result["failed"], b.result["revoked"], b.result["unresolved"]), (1, 0, 0))
        self.assertEqual(self.iss.tokens[other]["state"], "active", "other client's token untouched")
        self.assertNotIn(other, self.gh.calls)

    def test_revoke_client_reflects_pending_revoke_token_success(self):
        tok = add_token(self.iss, "a", client="c1")
        a = self.pending_revoke(tok)
        b = Run(self.iss.revoke_client, {"client": "c1"})
        self.iss.wait_event(1)
        self.open_gate(tok)
        a.finish(), b.finish()
        self.assertEqual((b.result["revoked"], b.result["failed"], b.result["ok"]), (1, 0, True))
        self.assertEqual(self.gh.calls, [tok])
        with open(self.iss.state) as f:
            self.assertEqual(json.load(f), ["c1"])

    def test_revoke_client_deadline_expiry_is_unresolved(self):
        iss, gh = make_issuer(self._td.name, settle=0.2)
        tok = add_token(iss, "a", client="c1")
        gh.gate(tok)
        a = Run(iss.revoke, tok)
        self.assertTrue(gh.started_event(tok).wait(SAFETY))
        res = iss.revoke_client({"client": "c1"})
        self.assertEqual((res["unresolved"], res["ok"]), (1, False))
        gh.gates[tok].set()
        a.finish()

    def test_finish_mint_self_kill_is_tracked_as_revoking(self):
        tok = "ghs_synthetic_late"
        self.gh.gate(tok)
        self.iss.closing = True
        a = Run(self.iss.finish_mint, tok, int(time.time()) + 3600, "acme/a", "write", "c1")
        self.assertTrue(self.gh.started_event(tok).wait(SAFETY))
        self.assertEqual(self.iss.tokens[tok]["state"], "revoking")  # born revoking: nobody double-DELETEs
        b = Run(self.iss.revoke, tok)
        self.iss.wait_event(1)
        self.open_gate(tok)
        a.finish(), b.finish()
        self.assertIn("issuer shutting down", a.error)
        self.assertEqual(b.result, {"revoked": 1, "note": "revoked by a concurrent request"})
        self.assertEqual(self.gh.calls, [tok])

    def test_finish_mint_self_kill_failure_is_reported(self):
        tok = "ghs_synthetic_late"
        self.gh.status[tok] = 500
        self.iss.closing = True
        with self.assertRaises(issuer_mod.Refuse) as cm:
            self.iss.finish_mint(tok, int(time.time()) + 3600, "acme/a", "write", "c1")
        self.assertIn(issuer_mod.DEL_FAILED, str(cm.exception))
        self.assertEqual(self.iss.tokens[tok]["state"], "failed")

    def test_undelivered_token_kill_overlapping_shutdown(self):
        """handler: response write fails -> issuer.revoke(token) while shutdown's revoke_all runs."""
        tok = add_token(self.iss, "a")
        self.gh.gate(tok)
        s = Run(self.iss.shutdown, 0)  # claims the token, DELETE parked
        self.assertTrue(self.gh.started_event(tok).wait(SAFETY))
        h = Run(self.iss.revoke, tok)  # handler's undelivered-token kill
        self.iss.wait_event(3)  # shutdown: drain + execute waits; handler: its wait
        self.open_gate(tok)
        s.finish(), h.finish()
        self.assertTrue(s.result[0])
        self.assertEqual(h.result["note"], "revoked by a concurrent request")
        self.assertEqual(self.gh.calls, [tok])

    def test_unexpected_exception_in_delete_leaves_failed_not_revoking(self):
        tok = add_token(self.iss, "a")

        def boom(_t):
            raise RuntimeError("synthetic")

        self.gh.delete = boom
        with self.assertRaises(RuntimeError):
            self.iss.revoke(tok)
        self.assertEqual(self.iss.tokens[tok]["state"], "failed")
        res = self.iss.revoke_all()  # retried, still failing -> failed, not stuck revoking
        self.assertEqual((res["failed"], res["unresolved"], res["ok"]), (1, 0, False))

    # --- locking ----------------------------------------------------------------------------
    def test_no_lock_held_during_delete(self):
        a, b, c = (add_token(self.iss, n) for n in "abc")
        self.iss.revoke(a)
        self.iss.revoke_all()
        self.iss.closing = True
        with self.assertRaises(issuer_mod.Refuse):
            self.iss.finish_mint("ghs_synthetic_late", int(time.time()) + 3600, "acme/a", "write", "c1")
        self.iss.revoke_client({"client": "c1"})
        self.iss.shutdown(0)
        self.assertGreaterEqual(len(self.gh.lock_was_free), 3)
        self.assertTrue(all(self.gh.lock_was_free), "issuer.lock was held during a DELETE")
        self.assertEqual(self.iss.tokens[b]["state"], "revoked")

    def test_stuck_delete_does_not_block_other_issuer_operations(self):
        tok = add_token(self.iss, "a")
        self.pending_revoke(tok)
        other = add_token(self.iss, "b")  # finish_mint needs the lock: must not block
        self.assertEqual(self.iss.tokens[other]["state"], "active")
        self.open_gate(tok)

    def test_workers_are_daemon_threads(self):
        add_token(self.iss, "a")
        self.gh.delete = lambda t: 204  # the lock probe in FakeGH.delete would start a non-worker thread
        seen = []
        orig = threading.Thread.start

        def spy(t):
            seen.append(t.daemon)
            return orig(t)

        threading.Thread.start = spy
        try:
            self.iss.revoke_all()
        finally:
            threading.Thread.start = orig
        self.assertEqual(seen, [True])



class LeadReview(unittest.TestCase):
    """Lead (Opus) review of the merged fixes: a mint response with an unparseable expires_at."""

    def test_unparseable_expiry_is_not_treated_as_expired(self):
        with tempfile.TemporaryDirectory() as d:
            iss, fake = make_issuer(d)
            gh = issuer_mod.GitHub(iss.policy["github"])
            gh.call = lambda *a, **k: (201, {"token": "ghs_synthetic_noexp", "expires_at": "garbage"})
            orig, issuer_mod.make_jwt = issuer_mod.make_jwt, lambda *a, **k: "synthetic.jwt"
            try:
                tok, exp, broader = gh.mint("acme/a", {"contents": "write", "metadata": "read"})
            finally:
                issuer_mod.make_jwt = orig
            self.assertTrue(broader)  # malformed -> refused and killed, never delivered
            self.assertGreater(exp, time.time() + 3500)  # not 0: still counted as possibly live
            fake.status[tok] = 500  # the kill DELETE fails
            with self.assertRaises(issuer_mod.Refuse):
                iss.finish_mint(tok, exp, "acme/a", "write", "c1", broader)
            self.assertEqual(iss.tokens[tok]["state"], "failed")
            res = iss.revoke_all()  # retried, still failing: must be reported
            self.assertFalse(res["ok"])
            self.assertEqual(res["failed"], 1)
            clean, res = iss.shutdown(0)
            self.assertFalse(clean)
            self.assertGreaterEqual(res["residual"], 1)


# --- ReinstatePersistence (fix B) ---
JOIN = 10  # bounded join timeout, seconds


def _mk_issuer_b(tmpdir, initial=()):
    """Mock-backend Issuer with two synthetic clients and a 0600 state file holding `initial`."""
    state = os.path.join(tmpdir, "revoked.json")
    with open(state, "w") as f:
        json.dump(sorted(initial), f)
    os.chmod(state, 0o600)
    clients = {c: {"secret_sha256": hashlib.sha256(f"synthetic-{c}".encode()).hexdigest(),
                   "repos": {"acme/a": "write"}} for c in ("agent-rw", "agent-ro")}
    policy = {"clients": clients, "ttl_seconds": 3600}
    return issuer_mod.Issuer(policy, b"synthetic-root-key", "synthetic-admin", state, backend="mock"), state


def _mint(iss, client):
    return iss.mint({"client": client, "secret": f"synthetic-{client}", "repo": "acme/a",
                     "access": "read"}, os.geteuid())


def _file_set(state):
    with open(state) as f:
        return set(json.load(f))


class ReinstatePersistence(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.iss, self.state = _mk_issuer_b(self._td.name, initial=["agent-rw"])

    def refused(self, client, text=None):
        with self.assertRaises(issuer_mod.Refuse) as cm:
            _mint(self.iss, client)
        if text:
            self.assertIn(text, str(cm.exception))

    def test_a_failed_save_keeps_client_revoked_and_fails_closed(self):
        self.refused("agent-rw")
        with mock.patch.object(issuer_mod.os, "replace", side_effect=OSError("synthetic")):
            with self.assertRaises(issuer_mod.Refuse) as cm:
                self.iss.reinstate_client({"client": "agent-rw"})
        self.assertIn("reinstatement NOT persisted", str(cm.exception))
        self.assertIn("remains revoked", str(cm.exception))
        self.assertTrue(self.iss.state_broken)
        self.assertIn("agent-rw", self.iss.revoked_clients)
        self.assertEqual(_file_set(self.state), {"agent-rw"})
        self.refused("agent-rw")                       # the reinstated client still cannot mint
        self.refused("agent-ro", "refuses all mints")  # nor can anyone else
        with self.assertRaises(issuer_mod.Refuse) as cm:  # and a second reinstate is refused
            self.iss.reinstate_client({"client": "agent-rw"})
        self.assertIn("run recover_state first", str(cm.exception))

    def test_b_mint_refused_while_save_pending_then_succeeds(self):
        entered, release = threading.Event(), threading.Event()
        real_save = self.iss.save_state

        def blocking_save(clients):
            entered.set()
            self.assertTrue(release.wait(JOIN))
            return real_save(clients)

        self.iss.save_state = blocking_save
        out = {}
        t = threading.Thread(target=lambda: out.update(self.iss.reinstate_client({"client": "agent-rw"})))
        t.start()
        try:
            self.assertTrue(entered.wait(JOIN))
            # Save in flight: the in-memory set must not have been changed or mutated in place.
            self.assertIn("agent-rw", self.iss.revoked_clients)
            self.refused("agent-rw", "revoked")
        finally:
            release.set()
            t.join(JOIN)
        self.assertFalse(t.is_alive())
        self.assertEqual(out, {"reinstated": 1})
        self.assertNotIn("agent-rw", _file_set(self.state))
        self.assertTrue(_mint(self.iss, "agent-rw")["token"].startswith("ghs_mock_"))

    def test_b2_failed_pending_save_never_authorizes(self):
        entered, release = threading.Event(), threading.Event()

        def failing_save(clients):
            entered.set()
            self.assertTrue(release.wait(JOIN))
            raise OSError("synthetic")

        self.iss.save_state = failing_save
        errs = []

        def run():
            try:
                self.iss.reinstate_client({"client": "agent-rw"})
            except issuer_mod.Refuse as e:
                errs.append(str(e))

        t = threading.Thread(target=run)
        t.start()
        try:
            self.assertTrue(entered.wait(JOIN))
            self.refused("agent-rw")
        finally:
            release.set()
            t.join(JOIN)
        self.assertEqual(len(errs), 1)
        self.refused("agent-rw")

    def test_c_recover_state_clears_broken_only_after_write(self):
        with mock.patch.object(issuer_mod.os, "replace", side_effect=OSError("synthetic")):
            with self.assertRaises(issuer_mod.Refuse):
                self.iss.reinstate_client({"client": "agent-rw"})
            self.assertTrue(self.iss.state_broken)
            with self.assertRaises(issuer_mod.Refuse) as cm:  # recovery write fails too
                self.iss.recover_state({})
            self.assertIn("recovery save failed", str(cm.exception))
            self.assertTrue(self.iss.state_broken)
            self.refused("agent-ro", "refuses all mints")
        out = self.iss.recover_state({})
        self.assertEqual(out, {"recovered": 1, "revoked_clients": 1})
        self.assertFalse(self.iss.state_broken)
        self.assertEqual(_file_set(self.state), {"agent-rw"})   # failed reinstatement NOT applied
        self.refused("agent-rw", "revoked")
        self.assertIn("token", _mint(self.iss, "agent-ro"))
        self.iss.reinstate_client({"client": "agent-rw"})        # a fresh reinstate now works
        self.assertEqual(_file_set(self.state), set())
        self.assertIn("token", _mint(self.iss, "agent-rw"))

    def test_c2_recover_state_is_admin_only(self):
        self.assertIn("recover_state", issuer_mod.ADMIN_OPS)
        with self.assertRaises(issuer_mod.Refuse):
            self.iss.handle({"op": "recover_state", "admin": "wrong"}, os.geteuid())
        self.assertEqual(self.iss.handle({"op": "recover_state", "admin": "synthetic-admin"},
                                         os.geteuid())["recovered"], 1)

    def test_d_concurrent_revoke_and_reinstate_end_consistent(self):
        for i in range(40):
            barrier = threading.Barrier(2)

            def go(fn):
                barrier.wait(JOIN)
                fn({"client": "agent-rw"})

            ts = [threading.Thread(target=go, args=(self.iss.revoke_client,)),
                  threading.Thread(target=go, args=(self.iss.reinstate_client,))]
            for t in ts:
                t.start()
            for t in ts:
                t.join(JOIN)
            self.assertFalse(any(t.is_alive() for t in ts))
            self.assertFalse(self.iss.state_broken)
            self.assertEqual(self.iss.revoked_clients, _file_set(self.state), f"iteration {i}")


if __name__ == "__main__":
    unittest.main()
