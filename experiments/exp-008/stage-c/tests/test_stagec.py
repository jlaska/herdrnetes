"""Offline tests for the EXP-008 Stage C task script and metrics (no cluster, no network, no model).

run:  uv run --no-project python -I -m unittest discover -s experiments/exp-008/stage-c/tests -v
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
STAGE = os.path.dirname(HERE)
sys.path.insert(0, STAGE)
import metrics  # noqa: E402

STEP = os.path.join(STAGE, "task", "step.sh")


def run_step(d, n, tok):
    p = subprocess.run(["./step.sh", str(n), tok], cwd=d, env={"PATH": "/usr/bin:/bin", "STEP_SLEEP": "0"},
                       capture_output=True, text=True, timeout=20)
    return p.returncode, p.stdout.strip()


def next_tok(out):
    m = re.search(r"NEXT: \./step\.sh \d+ ([a-z0-9]+)$", out)
    return m.group(1) if m else None


class StepScript(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        shutil.copy(STEP, self.d)
        os.chmod(os.path.join(self.d, "step.sh"), 0o755)

    def tearDown(self):
        shutil.rmtree(self.d)

    def test_chain_and_refusals(self):
        rc, out = run_step(self.d, 1, "start")
        self.assertEqual(rc, 0, out)
        tok = next_tok(out)
        self.assertRegex(tok, r"^[0-9a-f]{12}$")
        self.assertEqual(run_step(self.d, 1, "start")[0], 3)  # repeated step
        self.assertEqual(run_step(self.d, 3, tok)[0], 3)  # out of order
        self.assertEqual(run_step(self.d, 2, "deadbeef0000")[0], 3)  # wrong token
        rc, out2 = run_step(self.d, 2, tok)
        self.assertEqual(rc, 0, out2)
        task = metrics.load_task(self.d)
        self.assertEqual([a["n"] for a in task["attempts"]], [1, 2])
        self.assertEqual([a["n"] for a in task["progress"]], [1, 2])
        self.assertEqual(len(task["refusals"]), 3)
        self.assertIn("ppid", task["attempts"][0])
        led = metrics.ledger(self.d)
        self.assertTrue(led["chain_ok"], led)
        self.assertEqual(led["ledger_lines"], 2)

    def test_ledger_tamper_detected(self):
        tok = next_tok(run_step(self.d, 1, "start")[1])
        run_step(self.d, 2, tok)
        p = os.path.join(self.d, "ledger.log")
        with open(p) as f:
            lines = f.read().splitlines()
        lines[0] = lines[0].replace("n=1", "n=9")
        with open(p, "w") as f:
            f.write("\n".join(lines) + "\n")
        self.assertFalse(metrics.ledger(self.d)["chain_ok"])

    def test_concurrent_refused(self):
        lock = os.path.join(self.d, ".state", "lock")
        os.makedirs(lock)  # fresh lock, no owner yet: busy
        self.assertEqual(run_step(self.d, 1, "start")[0], 3)
        with open(os.path.join(lock, "owner"), "w") as f:  # live owner (this test process): busy
            st = open(f"/proc/{os.getpid()}/stat").read().rsplit(")", 1)[1].split()[19]
            f.write(f"{os.getpid()} {st}\n")
        self.assertEqual(run_step(self.d, 1, "start")[0], 3)
        with open(os.path.join(self.d, "refusals.log")) as f:
            self.assertEqual(f.read().count("reason=busy"), 2)

    def test_stale_lock_broken_and_logged(self):
        lock = os.path.join(self.d, ".state", "lock")
        os.makedirs(lock)
        with open(os.path.join(lock, "owner"), "w") as f:
            f.write("999999 1\n")  # dead owner
        rc, out = run_step(self.d, 1, "start")
        self.assertEqual(rc, 0, out)
        with open(os.path.join(self.d, "locks.log")) as f:
            self.assertIn("stale-lock-broken n=1", f.read())
        self.assertFalse(os.path.exists(lock))

    def test_leading_zero_refused(self):
        self.assertEqual(run_step(self.d, "01", "start")[0], 3)

    def test_bad_input_forms(self):
        for args in (["x", "start"], ["0", "start"], ["121", "start"], ["1", "a;b"]):
            self.assertEqual(run_step(self.d, *args)[0], 3, args)


def ts(ms):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def write_fixture(d, steps, t0, step_ms=25000, think_ms=1500, batched_at=None, gap=None, probe=None):
    """Synthetic run: per step an assistant tool_use, then step.sh attempt think_ms later, done +20 s."""
    att, prog, tr = [], [], []
    t = t0
    tr.append({"type": "user", "timestamp": ts(t - 3000), "sessionId": "S", "message": {"content": "task prompt"}})
    for n in steps:
        if gap and n == gap[0]:
            t += gap[1]
        cmd = f"./step.sh {n} tok{n}"
        if batched_at == n:
            cmd += f" && ./step.sh {n + 1} tok{n + 1}"
        tr.append({"type": "assistant", "timestamp": ts(t), "sessionId": "S",
                   "message": {"id": f"m{n}", "content": [{"type": "tool_use", "id": f"tu{n}", "name": "Bash", "input": {"command": cmd}}],
                               "usage": {"input_tokens": 10, "cache_read_input_tokens": 1000, "output_tokens": 50}}})
        tr.append({"type": "api-request", "timestamp": ts(t - 800)})
        att.append(f"attempt n={n} t={ts(t + think_ms)} prior_attempts=0 pid=1 ppid={100 + n} pstart=5")
        prog.append(f"done n={n} t={ts(t + think_ms + 20000)} pid=1 ppid={100 + n} pstart=5")
        tr.append({"type": "user", "timestamp": ts(t + think_ms + 20050), "sessionId": "S",
                   "message": {"content": [{"type": "tool_result", "tool_use_id": f"tu{n}", "content": "STEP OK"}]}})
        if probe and n == probe[0]:
            tr.append({"type": "user", "timestamp": ts(t + 5000), "sessionId": "S", "message": {"content": f"Reply {probe[1]} and the last step"}})
            tr.append({"type": "assistant", "timestamp": ts(t + 7000), "sessionId": "S",
                       "message": {"id": f"p{n}", "content": [{"type": "text", "text": f"{probe[1]} last step {n - 1}; codeword heron"}]}})
        t += step_ms
    for name, rows in (("attempts", att), ("progress", prog)):
        with open(f"{d}/{name}.log", "w") as f:
            f.write("\n".join(rows) + "\n")
    with open(f"{d}/transcript.jsonl", "w") as f:
        for e in tr:
            f.write(json.dumps(e) + "\n")


class Metrics(unittest.TestCase):
    T0 = 1_800_000_000_000

    def setUp(self):
        self.d = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.d)

    def classify(self, t_open, t_close, skew=0, **kw):
        write_fixture(self.d, range(1, 21), self.T0, **kw)
        task, tr = metrics.load_task(self.d), metrics.load_transcript(f"{self.d}/transcript.jsonl")
        return metrics.window(task, tr, t_open, t_close, metrics.median_interval(task), skew, 2000)

    def test_median(self):
        write_fixture(self.d, range(1, 10), self.T0)
        self.assertAlmostEqual(metrics.median_interval(metrics.load_task(self.d)), 25.0)

    def test_progressed(self):
        # window opens mid step 5 (in flight), lasts 100 s: steps 6..8 decided and started inside it
        r = self.classify(self.T0 + 4 * 25000 + 5000, self.T0 + 4 * 25000 + 105000)
        self.assertEqual(r["work"], "progressed", r)
        self.assertNotIn(5, r["counted_steps"])  # the in-flight step does not count
        self.assertGreaterEqual(len(r["counted_steps"]), 2)

    def test_in_flight_completion_alone_is_not_progress(self):
        # window from mid step 5 to just before step 6 is decided: only step 5's done (in flight) lands inside
        r = self.classify(self.T0 + 4 * 25000 + 5000, self.T0 + 4 * 25000 + 24500)
        self.assertEqual(r["work"], "stalled", r)
        self.assertGreaterEqual(r["done_in_window"], 1)

    def test_batched(self):
        r = self.classify(self.T0 + 4 * 25000 + 5000, self.T0 + 4 * 25000 + 105000, batched_at=7)
        self.assertEqual(r["work"], "batched", r)

    def test_frozen_then_recovered(self):
        # agent frozen for 150 s starting at step 6, window covers the freeze only
        o = self.T0 + 4 * 25000 + 5000
        r = self.classify(o, o + 140000, gap=(6, 150000))
        self.assertTrue(r["frozen"], r)
        self.assertEqual(r["work"], "stalled-then-recovered", r)

    def test_skew_margin_excludes_borderline(self):
        # with +10 s skew, the window shifts forward on the workload clock: a step started just
        # after the workstation open time but before open+skew no longer counts
        o = self.T0 + 5 * 25000 - 3000  # step 6 decided 3 s after open (margin 2 s), attempt +1.5 s
        r0 = self.classify(o, o + 60000)
        r1 = self.classify(o, o + 60000, skew=10000)
        self.assertIn(6, r0["counted_steps"])
        self.assertNotIn(6, r1["counted_steps"])

    def test_probe(self):
        write_fixture(self.d, range(1, 12), self.T0, probe=(9, "PROBE-ab12cd"))
        cw = os.path.join(self.d, "cw")
        with open(cw, "w") as f:
            f.write("heron\n")
        r = metrics.probe(metrics.load_transcript(f"{self.d}/transcript.jsonl"), "PROBE-ab12cd", "heron", 8)
        self.assertTrue(r["probe_in_transcript"] and r["reply"], r)
        self.assertTrue(r["reply_codeword"])
        self.assertTrue(r["reply_mentions_last_done"])
        self.assertEqual(r["session_ids"], ["S"])
        r2 = metrics.probe(metrics.load_transcript(f"{self.d}/transcript.jsonl"), "PROBE-zzzzzz", None, 8)
        self.assertFalse(r2["probe_in_transcript"])

    def test_probe_queued_vs_delivered(self):
        write_fixture(self.d, range(1, 6), self.T0)
        p = f"{self.d}/transcript.jsonl"
        with open(p, "a") as f:
            f.write(json.dumps({"type": "queue-operation", "operation": "enqueue", "timestamp": ts(self.T0 + 60000), "content": "Reply PROBE-q1"}) + "\n")
        r = metrics.probe(metrics.load_transcript(p), "PROBE-q1", None, 3)
        self.assertTrue(r["probe_queued_only"])
        self.assertFalse(r["probe_in_transcript"])
        with open(p, "a") as f:
            f.write(json.dumps({"type": "attachment", "timestamp": ts(self.T0 + 70000), "attachment": {"type": "queued_command", "prompt": "Reply PROBE-q1"}}) + "\n")
            f.write(json.dumps({"type": "assistant", "timestamp": ts(self.T0 + 72000), "sessionId": "S", "message": {"id": "z", "content": [{"type": "text", "text": "PROBE-q1 step 3"}]}}) + "\n")
        r = metrics.probe(metrics.load_transcript(p), "PROBE-q1", None, 3)
        self.assertTrue(r["probe_in_transcript"] and r["reply"] and r["reply_mentions_last_done"], r)
        self.assertEqual(r["tool_use_before_reply"], 0)

    def test_shared_shell_is_batched(self):
        write_fixture(self.d, range(1, 21), self.T0)
        p = f"{self.d}/attempts.log"
        with open(p) as f:
            lines = f.read().splitlines()
        lines = [re.sub(r"ppid=10[78]", "ppid=999", l) for l in lines]  # steps 7 and 8 from one shell
        with open(p, "w") as f:
            f.write("\n".join(lines) + "\n")
        task, tr = metrics.load_task(self.d), metrics.load_transcript(f"{self.d}/transcript.jsonl")
        r = metrics.window(task, tr, self.T0 + 4 * 25000 + 5000, self.T0 + 4 * 25000 + 105000, 25.0, 0, 2000)
        self.assertTrue(r["shared_shell"])
        self.assertEqual(r["work"], "batched")

    def test_usage_dedupes_message_ids(self):
        write_fixture(self.d, range(1, 4), self.T0)
        p = f"{self.d}/transcript.jsonl"
        with open(p) as f:
            lines = f.read().splitlines()
        with open(p, "a") as f:
            f.write(lines[1] + "\n")  # duplicate of message m1 (streamed block)
        u = metrics.usage(metrics.load_transcript(p), 1, 1.25, 0.1, 5)
        self.assertEqual(u["messages"], 3)
        self.assertEqual(u["output_tokens"], 150)

    def test_screen(self):
        rule = "─" * 40
        ok = f"Claude Code v2.1.323\n\n{rule}\n> \n{rule}\n  don't ask on (shift+tab to cycle)\n"
        self.assertTrue(metrics.screen(ok)["coherent"])
        bad = f"garbage [?1049h text\n{rule}\n> \n{rule}\n"
        self.assertFalse(metrics.screen(bad)["coherent"])
        self.assertFalse(metrics.screen("just output, no prompt\n")["coherent"])
        self.assertEqual(metrics.rawmode(b"a\x1b[?1049hb")["alt_screen_enter"], 1)

    def test_output_has_no_text(self):
        write_fixture(self.d, range(1, 12), self.T0, probe=(9, "PROBE-ab12cd"))
        out = json.dumps(metrics.probe(metrics.load_transcript(f"{self.d}/transcript.jsonl"), "PROBE-ab12cd", "heron", 8))
        self.assertNotIn("heron", out)
        self.assertNotIn("PROBE-ab12cd", out)


if __name__ == "__main__":
    unittest.main()
