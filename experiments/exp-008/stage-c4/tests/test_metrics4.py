"""Offline unit tests for stage-c4/metrics4.py (stdlib unittest; synthetic transcripts and task logs only).

Run: uv run --no-project python -I -m unittest discover -s experiments/exp-008/stage-c4/tests
"""
import hashlib
import importlib.util
import itertools
import json
import os
import random
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location("metrics4", os.path.join(HERE, "..", "metrics4.py"))
m4 = importlib.util.module_from_spec(_s)
_s.loader.exec_module(m4)

T0 = 1_800_000_000_000  # ms


def ts(ms):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


class TB:
    """Synthetic transcript builder (Claude Code 2.1.323-like entry shapes; one content block per entry)."""

    def __init__(self, sid="00000000-0000-4000-8000-000000000001"):
        self.lines, self.n, self.sid, self.last = [], 0, sid, None

    def _add(self, e, t):
        self.n += 1
        e.setdefault("uuid", f"u{self.n:04d}")
        e["parentUuid"] = self.last
        e["sessionId"] = self.sid
        e["timestamp"] = ts(t)
        self.last = e["uuid"]
        self.lines.append(json.dumps(e))
        return e

    def user(self, text, t):
        return self._add({"type": "user", "message": {"role": "user", "content": text}}, t)

    def real_text(self, text, t, model="claude-haiku-5-5", mid=None):
        return self._add({"type": "assistant", "message": {"id": mid or f"msg_{self.n}", "model": model, "role": "assistant",
                                                           "content": [{"type": "text", "text": text}],
                                                           "usage": {"input_tokens": 10, "output_tokens": 5}}}, t)

    def tool(self, cmd, t, tid=None, mid=None):
        return self._add({"type": "assistant", "message": {"id": mid or f"msg_{self.n}", "model": "claude-haiku-5-5", "role": "assistant",
                                                           "content": [{"type": "tool_use", "id": tid or f"toolu_{self.n}", "name": "Bash", "input": {"command": cmd}}],
                                                           "usage": {"input_tokens": 10, "output_tokens": 5}}}, t)

    def result(self, tid, text, t, is_error=False, interrupted=False):
        e = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": text, "is_error": is_error}]}}
        if interrupted:
            e["toolUseResult"] = {"toolDenialKind": "interrupted"}
            e["toolDenialKind"] = "interrupted"
        return self._add(e, t)

    def synthetic(self, text, t):
        return self._add({"type": "assistant", "message": {"id": f"syn_{self.n}", "model": "<synthetic>", "role": "assistant",
                                                           "content": [{"type": "text", "text": text}]}}, t)

    def api_error(self, t):
        return self._add({"type": "assistant", "isApiErrorMessage": True,
                          "message": {"id": f"err_{self.n}", "model": "<synthetic>", "role": "assistant", "content": [{"type": "text", "text": "API Error: 529"}]}}, t)

    def meta(self, typ, t):
        return self._add({"type": typ}, t)

    def data(self):
        return ("\n".join(self.lines) + "\n").encode()


def ents(tb):
    return m4.parse_lines(tb.data())


class Predicate(unittest.TestCase):
    def test_real_entry(self):
        tb = TB(); tb.real_text("hi", T0)
        self.assertTrue(m4.is_real_model_entry(ents(tb)[0]))

    def test_negatives(self):
        good = {"type": "assistant", "message": {"id": "m", "model": "claude-haiku-5-5", "usage": {"input_tokens": 1, "output_tokens": 1}}}
        cases = {
            "api-error": dict(good, isApiErrorMessage=True),
            "error-field": dict(good, error="rate_limit"),
            "synthetic": {"type": "assistant", "message": dict(good["message"], model="<synthetic>")},
            "missing-usage": {"type": "assistant", "message": {"id": "m", "model": "claude-haiku-5-5"}},
            "usage-not-int": {"type": "assistant", "message": dict(good["message"], usage={"input_tokens": "1", "output_tokens": 1})},
            "usage-negative": {"type": "assistant", "message": dict(good["message"], usage={"input_tokens": -1, "output_tokens": 1})},
            "usage-bool": {"type": "assistant", "message": dict(good["message"], usage={"input_tokens": True, "output_tokens": 1})},
            "other-model": {"type": "assistant", "message": dict(good["message"], model="claude-sonnet-5-5")},
            "dated-model": {"type": "assistant", "message": dict(good["message"], model="claude-haiku-5-5-20261001")},
            "no-model": {"type": "assistant", "message": {"id": "m", "usage": good["message"]["usage"]}},
            "no-id": {"type": "assistant", "message": {"model": "claude-haiku-5-5", "usage": good["message"]["usage"]}},
            "empty-id": {"type": "assistant", "message": dict(good["message"], id="")},
            "message-not-dict": {"type": "assistant", "message": "x"},
            "user": {"type": "user", "message": good["message"]},
            "malformed": {"_bad": True},
            "not-a-dict": [],
        }
        self.assertTrue(m4.is_real_model_entry(good))
        for name, e in cases.items():
            with self.subTest(name):
                self.assertFalse(m4.is_real_model_entry(e))

    def test_h4_api_errors_only_is_not_ok(self):
        tb = TB(); tb.user("task", T0); tb.api_error(T0 + 1); tb.api_error(T0 + 2); tb.synthetic("x", T0 + 3)
        r = m4.h4(ents(tb))
        self.assertFalse(r["ok"]); self.assertEqual(r["api_error_entries"], 2); self.assertEqual(r["real_model_entries"], 0)
        tb.real_text("ok", T0 + 4)
        self.assertTrue(m4.h4(ents(tb))["ok"])

    def test_malformed_lines(self):
        e = m4.parse_lines(b'{"type":"assistant"\n{"type":"user","message":{"content":"x"}}\n[1,2]\n')
        self.assertTrue(e[0]["_bad"]); self.assertFalse(e[1].get("_bad")); self.assertTrue(e[2]["_bad"])
        self.assertEqual(m4.h4(e)["malformed_lines"], 2)


class Offsets(unittest.TestCase):
    def test_after_clean_boundary(self):
        tb = TB(); tb.user("a", T0); d1 = tb.data(); tb.real_text("b", T0 + 1)
        self.assertEqual([e["type"] for e in m4.after(tb.data(), len(d1))], ["assistant"])

    def test_after_torn_boundary_is_sealed_not_counted(self):
        tb = TB(); tb.user("a", T0); tb.real_text("b", T0 + 1)
        full = tb.data()
        cut = full[: len(full) - 7]  # R captured mid-line
        later = full + b'{"type":"cost-state"}\n'
        e = m4.after(later, len(cut))
        self.assertEqual([x.get("type") for x in e], ["cost-state"])

    def test_partial_final_line_flag(self):
        e = m4.parse_lines(b'{"type":"user"}\n{"type":"assi')
        self.assertTrue(e[-1]["_bad"] and e[-1]["_partial"])


class Probe(unittest.TestCase):
    TOK, CW = "PROBE-1a2b3c4d", "heron0a1b2c"

    def base(self):
        tb = TB(); tb.user("task", T0)
        tb.user(f"Reply on one line exactly: {self.TOK} CODEWORD=<the codeword I gave you> LAST=<n>. Do not run any tool", T0 + 1000)
        return tb

    def test_pass_and_continuation_after_reply(self):
        tb = self.base(); tb.real_text(f"{self.TOK} CODEWORD={self.CW} LAST=7", T0 + 2000, mid="m1"); tb.tool("./step.sh 8 abc", T0 + 2001, mid="m1")
        r = m4.probe4(ents(tb), self.TOK, self.CW, {7})
        self.assertTrue(r["pass"]); self.assertEqual(r["tool_use_before_reply"], 0); self.assertEqual(r["first_action"], "text")

    def test_exact_one_line_format_only(self):
        """The first token-bearing text must BE the reply line: prefix, suffix, extra lines and malformed values fail."""
        good = f"{self.TOK} CODEWORD={self.CW} LAST=7"
        cases = {
            "exact": (good, True), "surrounding-whitespace": (f"  {good}\n", True),
            "prefix-text": (f"Sure! {good}", False), "suffix-text": (f"{good} and continuing", False),
            "trailing-period": (good + ".", False), "codeword-punctuation": (f"{self.TOK} CODEWORD={self.CW}. LAST=7", False),
            "two-lines": (f"{good}\nNext I will run step 8.", False), "line-before": (f"Here it is:\n{good}", False),
            "last-not-number": (f"{self.TOK} CODEWORD={self.CW} LAST=seven", False), "last-negative": (f"{self.TOK} CODEWORD={self.CW} LAST=-7", False),
            "last-leading-zero": (f"{self.TOK} CODEWORD={self.CW} LAST=07", False), "last-empty": (f"{self.TOK} CODEWORD={self.CW} LAST=", False),
            "codeword-empty": (f"{self.TOK} CODEWORD= LAST=7", False), "codeword-placeholder": (f"{self.TOK} CODEWORD=<the codeword> LAST=7", False),
            "fields-swapped": (f"{self.TOK} LAST=7 CODEWORD={self.CW}", False), "double-space": (f"{self.TOK}  CODEWORD={self.CW} LAST=7", False),
            "lowercase-keys": (f"{self.TOK} codeword={self.CW} last=7", False), "token-repeated": (f"{self.TOK} {self.TOK} CODEWORD={self.CW} LAST=7", False),
            "markdown": (f"`{good}`", False),
        }
        for name, (txt, want) in cases.items():
            with self.subTest(name):
                tb = self.base(); tb.real_text(txt, T0 + 2000)
                r = m4.probe4(ents(tb), self.TOK, self.CW, {7})
                self.assertEqual(r["pass"], want, txt); self.assertEqual(r["format_ok"], want, txt)

    def test_later_exact_line_does_not_rescue_a_malformed_first_reply(self):
        tb = self.base(); tb.real_text(f"Answer: {self.TOK} CODEWORD={self.CW} LAST=7", T0 + 2000)
        tb.real_text(f"{self.TOK} CODEWORD={self.CW} LAST=7", T0 + 3000)
        self.assertFalse(m4.probe4(ents(tb), self.TOK, self.CW, {7})["pass"])

    def test_wrong_token_in_exact_format(self):
        tb = self.base(); tb.real_text(f"{self.TOK} CODEWORD={self.CW} LAST=7".replace(self.TOK, self.TOK) + "", T0 + 2000)
        tb2 = self.base(); tb2.real_text(f"PROBE-deadbeef CODEWORD={self.CW} LAST=7 {self.TOK}", T0 + 2000)
        self.assertFalse(m4.probe4(ents(tb2), self.TOK, self.CW, {7})["pass"])

    def test_tool_before_reply(self):
        tb = self.base(); tb.tool("./step.sh 8 abc", T0 + 1500); tb.real_text(f"{self.TOK} CODEWORD={self.CW} LAST=7", T0 + 2000)
        r = m4.probe4(ents(tb), self.TOK, self.CW, {7})
        self.assertFalse(r["pass"]); self.assertEqual(r["first_action"], "tool"); self.assertEqual(r["tool_use_before_reply"], 1)

    def test_wrong_codeword_last_format(self):
        for txt, field in ((f"{self.TOK} CODEWORD=heron999 LAST=7", "codeword_ok"), (f"{self.TOK} CODEWORD={self.CW} LAST=6", "last_ok"),
                           (f"{self.TOK} the codeword is {self.CW}, last 7", "format_ok")):
            tb = self.base(); tb.real_text(txt, T0 + 2000)
            r = m4.probe4(ents(tb), self.TOK, self.CW, {7})
            with self.subTest(field):
                self.assertFalse(r[field]); self.assertFalse(r["pass"])

    def test_synthetic_or_error_reply_ignored(self):
        tb = self.base(); tb.synthetic(f"{self.TOK} CODEWORD={self.CW} LAST=7", T0 + 2000)
        r = m4.probe4(ents(tb), self.TOK, self.CW, {7})
        self.assertFalse(r["reply"]); self.assertFalse(r["pass"])

    def test_not_delivered_and_queued_only(self):
        tb = TB(); tb.user("task", T0)
        self.assertFalse(m4.probe4(ents(tb), self.TOK, self.CW, {7})["delivered"])
        tb._add({"type": "queue-operation", "operation": "enqueue", "content": self.TOK}, T0 + 1)
        r = m4.probe4(ents(tb), self.TOK, self.CW, {7})
        self.assertTrue(r["queued_only"]); self.assertFalse(r["pass"])

    def test_queued_command_attachment_is_delivery(self):
        tb = TB(); tb.user("task", T0); tb._add({"type": "attachment", "attachment": {"type": "queued_command", "prompt": f"x {self.TOK}"}}, T0 + 1)
        tb.real_text(f"{self.TOK} CODEWORD={self.CW} LAST=3", T0 + 2)
        self.assertTrue(m4.probe4(ents(tb), self.TOK, self.CW, {3, 4})["pass"])


# ---------------------------------------------------------------- C4b fixtures
def ledger_lines(n):
    out, prev = [], None
    for i in range(1, n + 1):
        p = hashlib.sha256((prev + "\n").encode()).hexdigest()[:16] if prev is not None else hashlib.sha256(b"").hexdigest()[:16]
        line = f"n={i} t={ts(T0 + i * 46000)} tokhash=0123456789abcdef prev={p}"
        out.append(line); prev = line
    return out


class State:
    """A task directory pair (R and pre) plus transcripts, for C4b and C4c."""

    def __init__(self, d, done=7):
        self.d, self.n = d, done + 1
        self.R, self.P = os.path.join(d, "R"), os.path.join(d, "pre")
        os.makedirs(self.R); os.makedirs(self.P)
        att = [f"attempt n={i} t={ts(T0 + i * 46000)} prior_attempts=0 sleep=45 pid=1 ppid={100 + i} pstart={i}" for i in range(1, self.n + 1)]
        prog = [f"done n={i} t={ts(T0 + i * 46000 + 45000)} pid=1" for i in range(1, done + 1)]
        self.logs = {"attempts": att, "progress": prog, "refusals": [], "ledger": ledger_lines(done), "locks": []}
        self.tb = TB()
        self.tb.user("task", T0)
        self.tb.user("Remember this codeword: heron0a1b2c. Reply on one line exactly: PROBE-00000000 ...", T0 + 10)
        for i in range(1, self.n + 1):
            tid = f"toolu_s{i}"
            self.tb.tool(f"./step.sh {i} tok{i:04d}", T0 + i * 46000 - 100, tid=tid)
            if i < self.n:
                self.tb.result(tid, f"STEP {i} OK. NEXT: ./step.sh {i + 1} tok{i + 1:04d}", T0 + i * 46000 + 45000)
        self.write(self.R, self.logs)
        self.write(self.P, self.logs)
        self.Rt, self.Pt = os.path.join(d, "R.jsonl"), os.path.join(self.P, "transcript.jsonl")
        open(self.Rt, "wb").write(self.tb.data()); open(self.Pt, "wb").write(self.tb.data())
        self.V = {"pvc_uid": "pvc-u", "pv": "pv-1", "volume_handle": "h1"}
        self.tok = "a" * 64

    @staticmethod
    def write(dirp, logs):
        for k, v in logs.items():
            open(os.path.join(dirp, f"{k}.log"), "w").write("".join(x + "\n" for x in v))

    def bundle(self, **kw):
        b = {"R_dir": self.R, "pre_dir": self.P, "R_transcript": self.Rt, "pre_transcript": self.Pt, "V_before": dict(self.V), "V_after": dict(self.V),
             "R_state_id_sha256": "s" * 64, "R_token_file_sha256": self.tok, "precheck_present": True,
             "precheck": {"state_id_sha256": "s" * 64, "next_token_hash_file_sha256": self.tok}}
        b.update(kw)
        return b

    def pre_append(self, name, line):
        with open(os.path.join(self.P, f"{name}.log"), "a") as f:
            f.write(line + "\n")

    def pre_transcript_append(self, raw: bytes):
        with open(self.Pt, "ab") as f:
            f.write(raw)


class C4b(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.s = State(self.t.name)

    def tearDown(self):
        self.t.cleanup()

    def test_intact(self):
        r = m4.c4b(self.s.bundle())
        self.assertEqual(r["value"], "intact"); self.assertEqual(r["in_flight_step"], 8); self.assertFalse(r["chain_broken_by_fault"])

    def test_tail_allowance_and_torn_line(self):
        self.s.pre_transcript_append(json.dumps({"type": "api-request", "uuid": "x1", "parentUuid": self.s.tb.last}).encode() + b'\n{"type":"cost-sta')
        r = m4.c4b(self.s.bundle())
        self.assertEqual(r["value"], "intact-with-allowance"); self.assertTrue(r["transcript"]["tail_partial_final"])

    def test_tail_limits(self):
        for raw, why in ((b'{"type":"user","message":{"content":"x"}}\n', "tail-unexpected-entry"),
                         (b"".join(json.dumps({"type": "cost-state"}).encode() + b"\n" for _ in range(6)), "tail-too-many-entries"),
                         (json.dumps({"type": "assistant", "pad": "x" * 70000}).encode() + b"\n", "tail-too-large"),
                         (json.dumps({"type": "cost-state", "uuid": "z", "parentUuid": "nope"}).encode() + b"\n", "tail-parent-discontinuity"),
                         (b'{"type": broken}\n{"type":"cost-state"}\n', "tail-unexpected-entry")):
            with self.subTest(why):
                t = tempfile.TemporaryDirectory(); s = State(t.name); s.pre_transcript_append(raw)
                r = m4.c4b(s.bundle())
                self.assertEqual(r["value"], "corrupt"); self.assertIn(why, r["reasons"]); t.cleanup()

    def tail(self, entries):
        """C4b on a fresh State whose frozen transcript gains <entries> (dicts or raw bytes) after R."""
        t = tempfile.TemporaryDirectory(); s = State(t.name); last = s.tb.last
        for e in entries:
            if isinstance(e, bytes):
                s.pre_transcript_append(e); continue
            e = dict(e); e.setdefault("parentUuid", last); last = e.get("uuid", last)
            s.pre_transcript_append(json.dumps(e).encode() + b"\n")
        r = m4.c4b(s.bundle()); t.cleanup(); return r

    def test_D1_five_entry_bounded_allowance(self):
        meta = lambda typ, i: {"type": typ, "uuid": f"m{i}"}
        asst = lambda i: {"type": "assistant", "uuid": f"a{i}", "message": {"id": f"x{i}", "model": "claude-haiku-5-5", "content": [{"type": "text", "text": "x"}], "usage": {"input_tokens": 1, "output_tokens": 1}}}
        tres = lambda i: {"type": "user", "uuid": f"r{i}", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_s3", "content": "x"}]}}
        three = [meta("api-request", 1), meta("cost-state", 2), meta("last-prompt", 3)]
        ok = lambda r: self.assertEqual(r["value"], "intact-with-allowance", r["reasons"])
        bad = lambda r, why: (self.assertEqual(r["value"], "corrupt"), self.assertIn(why, r["reasons"]))
        ok(self.tail(three))                                                             # three (previously accepted)
        ok(self.tail([asst(1), meta("cost-state", 2), meta("last-prompt", 3)]))           # an assistant row within 1-3 (approved)
        ok(self.tail(three + [meta("cost-state", 4)]))                                    # four with metadata
        ok(self.tail(three + [meta("cost-state", 4), meta("api-request", 5)]))            # five with metadata
        bad(self.tail(three + [meta("cost-state", 4), meta("cost-state", 5), meta("last-prompt", 6)]), "tail-too-many-entries")  # six
        bad(self.tail(three + [asst(4)]), "tail-entry-4-5-not-metadata")                  # assistant at position 4
        bad(self.tail(three + [meta("cost-state", 4), asst(5)]), "tail-entry-4-5-not-metadata")  # assistant at position 5
        bad(self.tail(three + [tres(4)]), "tail-entry-4-5-not-metadata")                  # tool result at position 4
        bad(self.tail(three + [{"type": "progress", "uuid": "p4"}]), "tail-entry-4-5-not-metadata")  # unknown type at 4
        bad(self.tail([{"type": "progress", "uuid": "p1"}]), "tail-unexpected-entry")     # unknown type at 1
        bad(self.tail([tres(1)]), "tail-unexpected-entry")                                # another call's result at 1
        bad(self.tail(three + [b'{"type":"cost-st']), "tail-entry-4-5-not-metadata")       # torn line at 4: type unrecognizable
        ok(self.tail([meta("api-request", 1), b'{"type":"cost-st']))                       # torn final line at 2: allowed
        tool_asst = {"type": "assistant", "uuid": "t1", "message": {"id": "y", "model": "claude-haiku-5-5", "usage": {"input_tokens": 1, "output_tokens": 1},
                     "content": [{"type": "tool_use", "id": "toolu_new", "name": "Bash", "input": {"command": "./step.sh 9 x"}}]}}
        bad(self.tail([tool_asst]), "tail-tool-activity")                                 # a requested tool call at 1-3 is new work
        bad(self.tail([meta("api-request", 1), tool_asst]), "tail-tool-activity")
        own_plus = {"type": "user", "uuid": "o1", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_s8", "content": "x"}, {"type": "text", "text": "extra"}]}}
        bad(self.tail([own_plus]), "tail-unexpected-entry")                               # own result with an extra block
        bad(self.tail(three + [{"type": "cost-state", "uuid": "m4", "parentUuid": "nope"}]), "tail-parent-discontinuity")
        bad(self.tail(three + [{"type": "cost-state", "uuid": "m4", "pad": "x" * 66000}]), "tail-too-large")
        t = tempfile.TemporaryDirectory(); s = State(t.name)                              # broken byte prefix
        orig = open(s.Pt, "rb").read()                                                     # read BEFORE truncating
        self.assertTrue(orig.endswith(b"\n") and len(orig) > 10)
        open(s.Pt, "wb").write(orig[:-6] + b"XXXXX\n" + json.dumps(meta("cost-state", 1)).encode() + b"\n")
        bad(m4.c4b(s.bundle()), "transcript-prefix-changed"); t.cleanup()

    def test_D1_allowance_never_hides_state_corruption(self):
        """A permitted five-entry tail does not mask a changed log, a broken chain or a lost volume."""
        three_plus = [{"type": "api-request", "uuid": "m1"}, {"type": "cost-state", "uuid": "m2"}, {"type": "last-prompt", "uuid": "m3"},
                      {"type": "cost-state", "uuid": "m4"}, {"type": "api-request", "uuid": "m5"}]
        for what in ("refusals", "ledger-chain", "lost"):
            with self.subTest(what):
                t = tempfile.TemporaryDirectory(); s = State(t.name); last = s.tb.last
                for e in three_plus:
                    e = dict(e, parentUuid=last); last = e["uuid"]; s.pre_transcript_append(json.dumps(e).encode() + b"\n")
                kw = {}
                if what == "refusals":
                    s.pre_append("refusals", "refused n=3 t=x reason=expected-n=8")
                elif what == "ledger-chain":
                    bad = s.logs["ledger"][:]; bad[2] = bad[2].replace("tokhash=0123", "tokhash=9999")
                    State.write(s.R, dict(s.logs, ledger=bad)); State.write(s.P, dict(s.logs, ledger=bad))
                else:
                    kw = {"V_after": dict(s.V, pvc_uid="other")}
                r = m4.c4b(s.bundle(**kw))
                self.assertIn(r["value"], ("corrupt", "lost")); self.assertNotIn(r["value"], ("intact", "intact-with-allowance")); t.cleanup()

    def test_in_flight_partial_states(self):
        s = self.s
        r = m4.c4b(s.bundle(precheck={"state_id_sha256": "s" * 64, "next_token_hash_file_sha256": "b" * 64}))
        self.assertEqual((r["value"], r["in_flight_state"], r["chain_broken_by_fault"]), ("intact-with-allowance", 1, True))
        s.pre_append("progress", f"done n=8 t={ts(T0 + 9 * 46000)} pid=1")
        r = m4.c4b(s.bundle(precheck={"state_id_sha256": "s" * 64, "next_token_hash_file_sha256": "b" * 64}))
        self.assertEqual((r["in_flight_state"], r["chain_broken_by_fault"]), (2, True))
        s.pre_append("ledger", ledger_lines(8)[-1])
        r = m4.c4b(s.bundle(precheck={"state_id_sha256": "s" * 64, "next_token_hash_file_sha256": "b" * 64}))
        self.assertEqual((r["value"], r["in_flight_state"], r["chain_broken_by_fault"]), ("intact-with-allowance", 3, True))
        s.pre_transcript_append(json.dumps({"type": "assistant", "uuid": "q", "parentUuid": s.tb.last,
                                            "message": {"content": [{"type": "text", "text": "STEP 8 OK. NEXT: ./step.sh 9 x"}]}}).encode() + b"\n")
        r = m4.c4b(s.bundle(precheck={"state_id_sha256": "s" * 64, "next_token_hash_file_sha256": "b" * 64}))
        self.assertEqual((r["in_flight_state"], r["chain_broken_by_fault"]), (3, False))

    def test_impossible_write_orders_are_corrupt(self):
        s = self.s; s.pre_append("progress", f"done n=8 t={ts(T0)} pid=1")  # done without a token rotation
        r = m4.c4b(s.bundle())
        self.assertEqual(r["value"], "corrupt")

    def test_unexpected_changes_are_corrupt(self):
        for name, line in (("attempts", "attempt n=9 t=x"), ("refusals", "refused n=3 t=x reason=expected-n=8"), ("locks", "stale-lock-broken n=8"),
                           ("progress", "done n=5 t=x"), ("ledger", "n=99 t=x prev=0")):
            with self.subTest(name):
                t = tempfile.TemporaryDirectory(); s = State(t.name); s.pre_append(name, line)
                self.assertEqual(m4.c4b(s.bundle())["value"], "corrupt"); t.cleanup()

    def test_rewritten_log_and_prefix(self):
        s = self.s
        lines = s.logs["progress"][:]; lines[2] = lines[2].replace("pid=1", "pid=2")
        State.write(s.P, dict(s.logs, progress=lines))
        self.assertIn("progress-unexpected", m4.c4b(s.bundle())["reasons"])
        t = tempfile.TemporaryDirectory(); s2 = State(t.name)
        orig = open(s2.Pt, "rb").read(); self.assertTrue(len(orig) > 10); open(s2.Pt, "wb").write(b"X" + orig[1:])  # read before truncating
        self.assertIn("transcript-prefix-changed", m4.c4b(s2.bundle())["reasons"]); t.cleanup()

    def test_broken_chain(self):
        s = self.s; bad = s.logs["ledger"][:]; bad[3] = bad[3].replace("tokhash=0123", "tokhash=9999")
        State.write(s.R, dict(s.logs, ledger=bad)); State.write(s.P, dict(s.logs, ledger=bad))
        self.assertIn("ledger-chain-broken", m4.c4b(s.bundle())["reasons"])

    def test_lost(self):
        s = self.s
        for kw in ({"V_after": dict(s.V, pvc_uid="other")}, {"V_after": dict(s.V, pv="pv-2")}, {"V_after": dict(s.V, volume_handle="h2")},
                   {"precheck": {"next_token_hash_file_sha256": s.tok}}, {"precheck": {"state_id_sha256": "t" * 64, "next_token_hash_file_sha256": s.tok}},
                   {"V_before": {}}):
            with self.subTest(str(kw)[:40]):
                self.assertEqual(m4.c4b(s.bundle(**kw))["value"], "lost")

    def test_launcher_refusal_mapping(self):
        s = self.s
        for why, val in (("partial state (repo=present state-id=absent)", "lost"), ("session id missing or malformed", "lost"),
                         ("transcript for the recorded session is missing or not unique", "lost"), ("state id unreadable or malformed", "lost"),
                         ("ledger chain broken at line 3", "corrupt"), ("step.sh differs from the package", "corrupt"),
                         ("ANTHROPIC_API_KEY is absent, not an OpenShell placeholder", "unmeasured"), ("", "unmeasured")):
            with self.subTest(why):
                self.assertEqual(m4.c4b(s.bundle(precheck_present=False, launcher_refusal=why))["value"], val)

    def test_relaunch_in_fresh_mode_is_lost(self):
        self.assertEqual(m4.c4b(self.s.bundle(launch_mode="fresh"))["value"], "lost")

    def test_measurement_failure_is_unmeasured_not_corrupt(self):
        r = m4.c4b(self.s.bundle(precheck_present=False, precheck_listed=True))
        self.assertEqual((r["value"], r["reasons"]), ("unmeasured", ["precheck-listed-but-not-copied"]))
        self.assertIn(r["value"], m4.C4B_VALUES)

    def test_in_flight_completed_with_its_tool_result_in_the_tail(self):
        s = self.s; tok = {"state_id_sha256": "s" * 64, "next_token_hash_file_sha256": "b" * 64}
        s.pre_append("progress", f"done n=8 t={ts(T0 + 9 * 46000)} pid=1"); s.pre_append("ledger", ledger_lines(8)[-1])
        s.pre_transcript_append(json.dumps({"type": "user", "uuid": "r8", "parentUuid": s.tb.last, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_s8", "content": "STEP 8 OK. NEXT: ./step.sh 9 abcd"}]}}).encode() + b"\n")
        r = m4.c4b(s.bundle(precheck=tok))
        self.assertEqual((r["value"], r["in_flight_state"], r["chain_broken_by_fault"]), ("intact-with-allowance", 3, False))
        t = tempfile.TemporaryDirectory(); s2 = State(t.name)  # a tool result for ANOTHER call is still unexpected
        s2.pre_transcript_append(json.dumps({"type": "user", "uuid": "r1", "parentUuid": s2.tb.last, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_s3", "content": "x"}]}}).encode() + b"\n")
        self.assertEqual(m4.c4b(s2.bundle())["value"], "corrupt"); t.cleanup()

    def test_not_restartable(self):
        self.assertEqual(m4.c4b({"not_restartable": "stop-rc1"})["value"], "not-restartable")

    def test_reference_without_single_in_flight(self):
        s = self.s; State.write(s.R, dict(s.logs, attempts=s.logs["attempts"][:-1])); State.write(s.P, dict(s.logs, attempts=s.logs["attempts"][:-1]))
        self.assertEqual(m4.c4b(s.bundle())["value"], "corrupt")


# ---------------------------------------------------------------- C4c fixtures: one per Resume value, then totality
CW, TOK = "heron0a1b2c", "PROBE-feedf00d"


class Run:
    """A resumed run built on State: the post-resume segment is appended to the final transcript and task logs."""

    def __init__(self, d, done=7):
        self.s = State(d, done)
        self.n = self.s.n
        self.F = os.path.join(d, "final"); os.makedirs(self.F)
        self.flogs = {k: list(v) for k, v in self.s.logs.items()}
        self.tb = self.s.tb
        self.tb.lines = list(self.tb.lines)
        self.t = T0 + 20 * 60000  # resume start
        self.inputs = []

    def interrupted(self):
        self.tb.result(f"toolu_s{self.n}", "[Tool call interrupted: ...]", self.t + 10, is_error=True, interrupted=True)
        self.tb.synthetic("No response requested.", self.t + 11)

    def probe(self, reply="ok", tool_first=False, t=60000):
        self.interrupted()
        self.tb.user(f"Reply on one line exactly: {TOK} CODEWORD=<the codeword I gave you> LAST=<n>.", self.t + t)
        self.inputs.append(self.t + t)
        if tool_first:
            self.tb.tool(f"./step.sh {self.n} tok{self.n:04d}", self.t + t + 500)
        if reply == "ok":
            self.tb.real_text(f"{TOK} CODEWORD={CW} LAST={self.n - 1}", self.t + t + 1000)
        elif reply == "wrong":
            self.tb.real_text(f"{TOK} CODEWORD=heron999 LAST={self.n - 1}", self.t + t + 1000)

    def cont(self, t=200000):
        self.tb.user("Continue the task.", self.t + t); self.inputs.append(self.t + t)

    def step(self, k, tok=None, t=None, prior=0, cmd=None):
        t = t or self.t + 205000 + (k - self.n) * 46000
        self.tb.tool(cmd or f"./step.sh {k} {tok or f'tok{k:04d}'}", t - 100, tid=f"toolu_r{k}_{t}")
        self.flogs["attempts"].append(f"attempt n={k} t={ts(t)} prior_attempts={prior} sleep=45 pid=1 ppid=9{k} pstart={k}")
        self.flogs["progress"].append(f"done n={k} t={ts(t + 45000)} pid=1")

    def continue_steps(self, t0=None):
        self.step(self.n, prior=1, t=t0)
        self.step(self.n + 1); self.step(self.n + 2)

    def refuse(self, k, reason):
        self.flogs["refusals"].append(f"refused n={k} t={ts(self.t + 250000)} reason={reason} pid=1")

    def bundle(self, **kw):
        State.write(self.F, self.flogs)
        ft = os.path.join(self.s.d, "final.jsonl"); open(ft, "wb").write(self.tb.data())
        b = {"c4b": m4.c4b(self.s.bundle()), "R_dir": self.s.R, "final_dir": self.F, "R_transcript": self.s.Rt, "pre_transcript": self.s.Pt,
             "final_transcript": ft, "transcripts_after": ["00000000-0000-4000-8000-000000000001.jsonl"],
             "R_transcript_name": "00000000-0000-4000-8000-000000000001.jsonl", "process": "new-process", "launcher_refused": False,
             "probe_token": TOK, "codeword": CW, "expected_last": [self.n - 1], "control_pass": True, "M_s": 46.0, "start_t": self.t,
             "dialogs": {"trust": False, "custom_key": False, "resume_summary": False}, "spend_stop": False, "probe_typed": True, "continue_typed": bool(len(self.inputs) > 1)}
        b.update(kw)
        return b


def classify(run, **kw):
    return m4.c4c(run.bundle(**kw))


class C4c(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); self.r = Run(self.td.name)

    def tearDown(self):
        self.td.cleanup()

    def v(self, **kw):
        return classify(self.r, **kw)

    def test_continued_after_prompt_expected(self):
        r = self.r; r.probe(); r.cont(); r.continue_steps()
        v = self.v()
        self.assertEqual(v["axes"]["resume"], "resumed-continued-after-prompt", v["decision_path"])
        self.assertEqual(v["axes"]["repeat_skip"], "in-flight-reattempt-only")
        self.assertEqual(v["axes"]["interrupted_turn"], "synthesized-interrupted")
        self.assertEqual(v["axes"]["session"], "same-id-same-file")
        self.assertTrue(v["primary_pass"]); self.assertTrue(v["attributes"]["step_n_token_matches_prefault"])

    def test_continued_after_probe_only(self):
        r = self.r; r.probe(); r.continue_steps()
        v = self.v()
        self.assertEqual(v["axes"]["resume"], "resumed-continued-after-prompt"); self.assertTrue(v["primary_pass"])

    def test_auto_continued(self):
        r = self.r; r.step(r.n, prior=1, t=r.t + 20000)  # before any input
        r.tb.user(f"Reply on one line exactly: {TOK} CODEWORD=<..> LAST=<..>.", r.t + 200000); r.inputs.append(r.t + 200000)
        r.tb.real_text(f"{TOK} CODEWORD={CW} LAST={r.n}", r.t + 201000)
        r.step(r.n + 1); r.step(r.n + 2)
        v = self.v(expected_last=[r.n - 1, r.n])
        self.assertEqual(v["axes"]["resume"], "resumed-auto-continued", v["decision_path"]); self.assertTrue(v["primary_pass"])

    def test_wrong_token_is_not_a_pass(self):
        r = self.r; r.probe(); r.cont(); r.step(r.n, tok="zzzz", prior=1); r.step(r.n + 1); r.step(r.n + 2)
        v = self.v()
        self.assertFalse(v["attributes"]["step_n_token_matches_prefault"]); self.assertEqual(v["axes"]["resume"], "responded-no-progress")

    def test_nonconforming_command_blocks_pass(self):
        r = self.r; r.probe(); r.cont(); r.continue_steps(); r.tb.tool("cat /sandbox/c/claude/projects/x.jsonl", r.t + 900000)
        v = self.v()
        self.assertEqual(v["axes"]["resume"], "responded-no-progress"); self.assertEqual(v["attributes"]["nonconforming_bash_commands"], 1)
        r2 = Run(tempfile.mkdtemp(dir=self.td.name)); r2.probe(); r2.cont()
        r2.step(r2.n, prior=1, cmd=f"./step.sh {r2.n} tok{r2.n:04d}; echo"); r2.step(r2.n + 1); r2.step(r2.n + 2)
        self.assertFalse(classify(r2)["primary_pass"])

    def test_context_lost(self):
        r = self.r; r.probe(reply="wrong"); r.cont(); r.continue_steps()
        self.assertEqual(self.v()["axes"]["resume"], "resumed-context-lost")
        r2 = Run(tempfile.mkdtemp(dir=self.td.name)); r2.probe(reply="none"); r2.tb.real_text("I do not know", r2.t + 70000)
        self.assertEqual(classify(r2)["axes"]["resume"], "resumed-context-lost")

    def test_probe_ignored(self):
        r = self.r; r.probe(tool_first=True); r.continue_steps()
        self.assertEqual(self.v()["axes"]["resume"], "probe-ignored")

    def test_re_executed(self):
        r = self.r; r.probe(); r.cont(); r.refuse(1, f"expected-n={r.n}"); r.tb.real_text("x", r.t + 260000)
        v = self.v()
        self.assertEqual(v["axes"]["resume"], "re-executed"); self.assertEqual(v["axes"]["repeat_skip"], "restart-from-start")
        r2 = Run(tempfile.mkdtemp(dir=self.td.name)); r2.probe(); r2.cont(); r2.refuse(3, f"expected-n={r2.n}"); r2.refuse(4, f"expected-n={r2.n}"); r2.tb.real_text("x", r2.t + 260000)
        self.assertEqual(classify(r2)["axes"]["resume"], "re-executed")

    def test_single_duplicate_fails_primary_only(self):
        r = self.r; r.probe(); r.cont(); r.refuse(r.n - 1, f"expected-n={r.n}"); r.continue_steps()
        v = self.v()
        self.assertEqual(v["axes"]["resume"], "resumed-continued-after-prompt"); self.assertEqual(v["axes"]["repeat_skip"], "duplicate-refused(1)")
        self.assertFalse(v["primary_pass"])

    def test_skip(self):
        r = self.r; r.probe(); r.cont(); r.refuse(r.n + 1, f"expected-n={r.n}"); r.continue_steps()
        self.assertEqual(self.v()["axes"]["repeat_skip"], "skip-refused(1)")

    def test_failed_no_model_or_dialog(self):
        r = self.r; r.probe(reply="none")
        self.assertEqual(self.v()["axes"]["resume"], "failed")
        r2 = Run(tempfile.mkdtemp(dir=self.td.name)); r2.probe(); r2.cont(); r2.continue_steps()
        self.assertEqual(classify(r2, dialogs={"trust": True})["axes"]["resume"], "failed")

    def test_not_started(self):
        self.assertEqual(self.v(process="not-started")["axes"]["resume"], "not-started")
        self.assertEqual(self.v(launcher_refused=True)["axes"]["resume"], "not-started")

    def test_inconclusive(self):
        r = self.r; r.probe(); r.cont(); r.continue_steps()
        self.assertEqual(self.v(spend_stop=True)["axes"]["resume"], "inconclusive")
        self.assertEqual(self.v(process="same-as-original")["axes"]["resume"], "inconclusive")
        self.assertEqual(self.v(c4b=dict(m4.c4b(r.s.bundle()), chain_broken_by_fault=True))["axes"]["resume"], "inconclusive")
        r2 = Run(tempfile.mkdtemp(dir=self.td.name)); r2.probe(); r2.tb.api_error(r2.t + 70000); r2.cont(); r2.continue_steps()
        self.assertEqual(classify(r2)["decision_path"], "api-error-after-resume")
        r3 = Run(tempfile.mkdtemp(dir=self.td.name)); r3.probe(reply="wrong"); r3.cont(); r3.continue_steps()
        self.assertEqual(classify(r3, control_pass=False)["decision_path"], "control-and-probe-failed")
        r4 = Run(tempfile.mkdtemp(dir=self.td.name)); r4.interrupted(); r4.tb.real_text("hello", r4.t + 70000)
        self.assertEqual(classify(r4)["decision_path"], "probe-not-delivered")

    def test_lost_and_fresh(self):
        r = self.r; r.probe(); r.cont(); r.continue_steps()
        self.assertEqual(self.v(c4b={"value": "lost"})["axes"]["resume"], "lost")
        self.assertFalse(self.v(c4b={"value": "lost"})["primary_pass"])
        v = self.v(final_transcript=os.path.join(self.td.name, "missing.jsonl"))
        self.assertEqual((v["axes"]["resume"], v["axes"]["session"], v["decision_path"]), ("inconclusive", "unavailable", "final-transcript-unavailable"))
        v = self.v(final_transcript=os.path.join(self.td.name, "missing.jsonl"), process="not-started")
        self.assertEqual(v["axes"]["resume"], "not-started")
        v = self.v(final_transcript=os.path.join(self.td.name, "missing.jsonl"), launcher_refused=True)
        self.assertEqual(v["axes"]["resume"], "not-started")
        b = r.bundle(); open(b["final_transcript"], "wb").write(b"{}\n")
        self.assertEqual(m4.c4c(b)["axes"]["session"], "fresh-no-history")
        b = r.bundle(transcripts_after=["00000000-0000-4000-8000-000000000001.jsonl", "11111111-0000-4000-8000-000000000001.jsonl"])
        self.assertEqual(m4.c4c(b)["axes"]["session"], "new-id")
        b = r.bundle(transcripts_after=["00000000-0000-4000-8000-000000000001.jsonl"] * 2)
        self.assertEqual(m4.c4c(b)["axes"]["session"], "same-id-new-file")

    def test_responded_no_progress(self):
        r = self.r; r.probe(); r.cont(); r.step(r.n, prior=1)  # N accepted but stalls before N+2
        self.assertEqual(self.v()["axes"]["resume"], "responded-no-progress")

    def test_api_error_entries_never_count_as_activity(self):
        r = self.r; r.probe(reply="none"); r.tb.api_error(r.t + 70000); r.tb.api_error(r.t + 80000)
        v = self.v()
        self.assertEqual(v["attributes"]["real_model_entries_after_resume"], 0); self.assertEqual(v["axes"]["resume"], "inconclusive")

    def test_interrupted_turn_values(self):
        r = self.r; r.probe(); r.cont(); r.continue_steps()
        self.assertEqual(self.v()["axes"]["interrupted_turn"], "synthesized-interrupted")
        r2 = Run(tempfile.mkdtemp(dir=self.td.name)); r2.tb.user(f"Reply on one line exactly: {TOK} x", r2.t + 60000); r2.tb.real_text(f"{TOK} CODEWORD={CW} LAST={r2.n - 1}", r2.t + 61000)
        self.assertEqual(classify(r2)["axes"]["interrupted_turn"], "absent")
        r3 = Run(tempfile.mkdtemp(dir=self.td.name)); r3.tb.result(f"toolu_s{r3.n}", "STEP 8 OK. NEXT: ./step.sh 9 x", r3.t + 10)
        self.assertEqual(classify(r3)["axes"]["interrupted_turn"], "other")

    def test_probe_not_typed_and_new_id(self):
        r = self.r; r.step(r.n, prior=1, t=r.t + 20000); r.step(r.n + 1); r.step(r.n + 2)
        self.assertEqual(self.v(probe_typed=False, probe_token="")["decision_path"], "probe-not-typed")
        b = r.bundle(transcripts_after=["00000000-0000-4000-8000-000000000001.jsonl", "22222222-0000-4000-8000-000000000001.jsonl"])
        self.assertEqual(m4.c4c(b)["decision_path"], "session-new-id-not-followed")

    def test_boundary_falls_back_to_R(self):
        r = self.r; r.probe(); r.cont(); r.continue_steps()
        v = self.v(pre_transcript=os.path.join(self.td.name, "nope.jsonl"))
        self.assertEqual(v["attributes"].get("boundary"), "R"); self.assertEqual(v["axes"]["resume"], "resumed-continued-after-prompt")
        self.assertFalse(v["primary_pass"])  # missing frozen copy = missing transcript evidence: never a pass (owner correction C)

    def test_process_unreadable_is_inconclusive(self):
        r = self.r; r.probe(); r.cont(); r.continue_steps()
        self.assertEqual(self.v(process="unreadable")["decision_path"], "process-unreadable")

    def test_session_load_parent_attribute(self):
        r = self.r; r.probe(); r.cont(); r.continue_steps()
        self.assertTrue(self.v()["attributes"]["first_resumed_parent_in_prefault"])

    def test_precedence_when_rules_overlap(self):
        """Two or more rules match: the earlier step of the procedure wins."""
        def mk(fn):
            r = Run(tempfile.mkdtemp(dir=self.td.name)); fn(r); return r
        base = lambda r: (r.probe(), r.cont(), r.continue_steps())
        # lost beats everything, including API errors and a spend stop
        r = mk(lambda r: (base(r), r.tb.api_error(r.t + 999000)))
        self.assertEqual(classify(r, c4b={"value": "lost"}, spend_stop=True)["axes"]["resume"], "lost")
        # inconclusive (chain broken by the fault) beats not-started
        r = mk(base)
        self.assertEqual(classify(r, c4b=dict(m4.c4b(r.s.bundle()), chain_broken_by_fault=True), process="not-started")["axes"]["resume"], "inconclusive")
        # not-started beats failed (no model entry)
        r = mk(lambda r: None)
        self.assertEqual(classify(r, launcher_refused=True)["axes"]["resume"], "not-started")
        # failed (blocking dialog) beats re-executed
        r = mk(lambda r: (r.probe(), r.cont(), r.refuse(1, "expected-n=8"), r.tb.real_text("x", r.t + 260000)))
        self.assertEqual(classify(r, dialogs={"trust": True})["axes"]["resume"], "failed")
        # re-executed beats probe-ignored
        r = mk(lambda r: (r.probe(tool_first=True), r.refuse(1, "expected-n=8"), r.continue_steps()))
        self.assertEqual(classify(r)["axes"]["resume"], "re-executed")
        # probe-ignored beats context-lost (a tool first, then a wrong codeword)
        r = mk(lambda r: (r.probe(reply="wrong", tool_first=True), r.continue_steps()))
        self.assertEqual(classify(r)["axes"]["resume"], "probe-ignored")
        # context-lost beats a full continuation (task integrity alone is not a pass)
        r = mk(lambda r: (r.probe(reply="wrong"), r.cont(), r.continue_steps()))
        v = classify(r)
        self.assertEqual(v["axes"]["resume"], "resumed-context-lost"); self.assertFalse(v["primary_pass"])

    def test_a_correct_reply_alone_is_not_a_pass(self):
        r = self.r; r.probe()  # correct probe reply, no continuation at all
        v = self.v()
        self.assertEqual(v["axes"]["resume"], "responded-no-progress"); self.assertFalse(v["primary_pass"])

    def test_no_ambiguous_session_can_pass(self):
        """Regression (owner correction C): a run that is otherwise a perfect continuation never passes unless the
        ORIGINAL session continued unambiguously in a new process."""
        def perfect():
            r = Run(tempfile.mkdtemp(dir=self.td.name)); r.probe(); r.cont(); r.continue_steps(); return r
        name = "00000000-0000-4000-8000-000000000001.jsonl"
        self.assertTrue(classify(perfect())["primary_pass"])  # control: the baseline passes
        variants = {
            "same-id-new-file": dict(transcripts_after=[name, name]),
            "new-id": dict(transcripts_after=[name, "33333333-0000-4000-8000-000000000001.jsonl"]),
            "unavailable": dict(final_transcript="/nonexistent/final.jsonl"),
            "process-unreadable": dict(process="unreadable"),
            "process-same-as-original": dict(process="same-as-original"),
            "process-not-started": dict(process="not-started"),
            "no-transcript-evidence": dict(transcripts_after=[]),
            "no-frozen-copy": dict(pre_transcript="/nonexistent/pre.jsonl"),
        }
        for k, kw in variants.items():
            with self.subTest(k):
                v = classify(perfect(), **kw)
                self.assertFalse(v["primary_pass"], (k, v["axes"], v["decision_path"]))
        r = perfect(); b = r.bundle(); open(b["final_transcript"], "wb").write(b"{}\n")           # fresh-no-history
        v = m4.c4c(b); self.assertEqual(v["axes"]["session"], "fresh-no-history"); self.assertFalse(v["primary_pass"])
        r = perfect(); r.tb.sid = "44444444-0000-4000-8000-000000000001"; r.tb.real_text("x", r.t + 990000)  # a second session id in the same file
        v = classify(r); self.assertEqual(v["decision_path"], "session-id-ambiguous"); self.assertFalse(v["primary_pass"])
        r = perfect(); v = classify(r, transcripts_after=[name, name])
        self.assertEqual(v["decision_path"], "session-duplicated-file")
        other = "55555555-0000-4000-8000-000000000001.jsonl"                                       # file name != the session id inside it
        v = classify(perfect(), transcripts_after=[other], R_transcript_name=other)
        self.assertFalse(v["attributes"]["session_ids_consistent"]); self.assertFalse(v["primary_pass"])

    def test_primary_pass_requires_every_condition(self):
        """Over random runs: primary_pass implies every documented condition."""
        rnd = random.Random(7)
        name = "00000000-0000-4000-8000-000000000001.jsonl"
        for i in range(120):
            r = Run(tempfile.mkdtemp(dir=self.td.name)); r.probe(reply=rnd.choice(["ok", "ok", "wrong"])); r.cont(); r.continue_steps()
            kw = rnd.choice([{}, {}, {"transcripts_after": [name, name]}, {"process": "unreadable"}, {"transcripts_after": []},
                             {"final_transcript": "/nonexistent"}, {"c4b": {"value": "unmeasured"}}])
            v = classify(r, **kw)
            if v["primary_pass"]:
                self.assertEqual(v["axes"]["session"], "same-id-same-file"); self.assertEqual(v["axes"]["process"], "new-process")
                self.assertTrue(v["attributes"]["session_ids_consistent"]); self.assertTrue(v["attributes"]["final_transcript_available"])
                self.assertIn(v["attributes"]["c4b"], ("intact", "intact-with-allowance")); self.assertTrue(v["attributes"]["probe"]["pass"])

    def test_every_value_has_a_fixture(self):
        covered = set()
        for build in FIXTURES:
            d = tempfile.mkdtemp(dir=self.td.name)
            covered.add(build(Run(d)))
        self.assertEqual(covered, set(m4.RESUME_VALUES))


def _fx(fn, **kw):
    def build(r):
        fn(r)
        k = dict(kw)
        if "final_transcript" in k and k["final_transcript"] is None:
            k["final_transcript"] = os.path.join(r.s.d, "other.jsonl")  # exists, but does not start with the pre-fault bytes
        return classify(r, **k)["axes"]["resume"]
    return build


FIXTURES = [
    _fx(lambda r: (r.probe(), r.cont(), r.continue_steps())),                                         # continued-after-prompt
    _fx(lambda r: (r.step(r.n, prior=1, t=r.t + 20000), r.tb.user(f"Reply {TOK} x", r.t + 200000),
                   r.tb.real_text(f"{TOK} CODEWORD={CW} LAST={r.n}", r.t + 201000), r.step(r.n + 1), r.step(r.n + 2)), expected_last=[8]),  # auto
    _fx(lambda r: (r.probe(reply="wrong"), r.cont(), r.continue_steps())),                            # context-lost
    _fx(lambda r: (r.probe(tool_first=True), r.continue_steps())),                                    # probe-ignored
    _fx(lambda r: (r.probe(), r.cont(), r.refuse(1, "expected-n=8"), r.tb.real_text("x", r.t + 260000))),  # re-executed
    _fx(lambda r: r.probe(reply="none")),                                                             # failed
    _fx(lambda r: None, process="not-started"),                                                       # not-started
    _fx(lambda r: (r.probe(), r.cont(), r.continue_steps()), spend_stop=True),                        # inconclusive
    _fx(lambda r: (r.probe(), r.cont(), r.continue_steps()), c4b={"value": "lost"}),                  # lost
    _fx(lambda r: open(os.path.join(r.s.d, "other.jsonl"), "wb").write(b"{}\n"), final_transcript=None),  # fresh-no-history (set below)
    _fx(lambda r: (r.probe(), r.cont(), r.step(r.n, prior=1))),                                       # responded-no-progress
]


class Totality(unittest.TestCase):
    """Random combinations of the decision inputs: c4c never raises and returns exactly one known value."""

    def test_random_combinations(self):
        rnd = random.Random(4)
        seen = set()
        with tempfile.TemporaryDirectory() as td:
            for i in range(300):
                r = Run(os.path.join(td, str(i)))
                if rnd.random() < 0.8:
                    r.probe(reply=rnd.choice(["ok", "wrong", "none"]), tool_first=rnd.random() < 0.2)
                if rnd.random() < 0.5:
                    r.cont()
                if rnd.random() < 0.15:
                    r.tb.api_error(r.t + 90000)
                for _ in range(rnd.randint(0, 2)):
                    r.refuse(rnd.choice([1, r.n - 2, r.n - 1, r.n + 1, r.n]), rnd.choice([f"expected-n={r.n}", "wrong-token", "busy"]))
                k = rnd.randint(0, 3)
                for j in range(k):
                    r.step(r.n + j, prior=1 if j == 0 else 0, tok=None if rnd.random() < 0.9 else "bad")
                if rnd.random() < 0.1:
                    r.tb.tool("ls", r.t + 999999)
                kw = {"process": rnd.choice(["new-process"] * 8 + ["not-started", "same-as-original"]),
                      "launcher_refused": rnd.random() < 0.05, "spend_stop": rnd.random() < 0.05, "control_pass": rnd.random() < 0.9,
                      "dialogs": {"trust": rnd.random() < 0.05}}
                if rnd.random() < 0.05:
                    kw["c4b"] = {"value": rnd.choice(["lost", "corrupt"])}
                v = classify(r, **kw)
                self.assertIn(v["axes"]["resume"], m4.RESUME_VALUES)
                self.assertIsInstance(v["primary_pass"], bool)
                if v["primary_pass"]:
                    self.assertIn(v["axes"]["resume"], ("resumed-auto-continued", "resumed-continued-after-prompt"))
                    self.assertTrue(v["attributes"]["probe"]["pass"] or v["axes"]["resume"] == "resumed-auto-continued")
                # exactly one value, and the primary pass is exactly the documented conjunction
                expect = v["axes"]["resume"] in ("resumed-auto-continued", "resumed-continued-after-prompt") and \
                    v["axes"]["repeat_skip"] in ("none", "in-flight-reattempt-only") and v["attributes"]["c4b"] in ("intact", "intact-with-allowance") and \
                    v["axes"]["session"] == "same-id-same-file" and v["axes"]["process"] == "new-process" and \
                    v["attributes"]["final_transcript_available"] and v["attributes"]["session_ids_consistent"] and v["attributes"]["frozen_copy_available"]
                self.assertEqual(v["primary_pass"], expect)
                seen.add(v["axes"]["resume"])
        self.assertGreaterEqual(len(seen), 8, seen)

    def test_output_never_contains_secrets(self):
        with tempfile.TemporaryDirectory() as td:
            r = Run(td); r.probe(); r.cont(); r.continue_steps()
            out = json.dumps(classify(r))
            for s in (CW, TOK, "tok0008", "tok0009"):
                self.assertNotIn(s, out)


if __name__ == "__main__":
    unittest.main()
