"""Resume regression probe for tests/resume-regression-test.sh (run as PID 1 of a user+network+PID namespace with
loopback only: no network, no model, no credential).

Runs the REAL C4 bootstrap and state-aware launcher with the REAL, sha256-pinned Claude Code 2.1.323 binary
against a local SCRIPTED MODEL (a mock /v1/messages that answers from the request history only, the way a model
that has its context would), with a made-up placeholder. Phase A: fresh launch; step 1; the codeword/control
line; step 2 starts; every process except this one is SIGKILLed while step 2 sleeps (a pod loss). Phase B: the
canonical command is relaunched (as `sandbox start` does); the launcher selects Resume; 12 s with no input; the
probe line; "Continue the task."; steps 2-4. Writes a STRUCTURE-ONLY report (counts, booleans, roles, block
types); copies of the reference state at the kill go to <work>/R for the metrics4 comparators.

usage: resume_probe.py <work> <boot_script> <package.b64> <package_sha256> <placeholder> <claude_bin>
"""
import fcntl
import http.server
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import sys
import termios
import threading
import time

W, boot, b64, sha, fake, BIN = sys.argv[1:7]
SB = os.path.join(W, "sb", "c")
CW, CTL_TOK, PRB_TOK = "heronab12cd", "PROBE-11111111", "PROBE-22222222"
CONTROL = f"Remember this codeword: {CW}. Reply on one line exactly: {CTL_TOK} CODEWORD=<the codeword> LAST=<number of the last step that printed STEP OK>. Do not run any tool for this reply."
PROBE = f"Reply on one line exactly: {PRB_TOK} CODEWORD=<the codeword I gave you> LAST=<number of the last step that printed STEP OK>. Do not run any tool for this reply."
phase = ["A"]
log = []
lock = threading.Lock()
LAST_STEP = 4


def texts(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return [c]
    out = []
    for b in c or []:
        if b.get("type") == "text":
            out.append(b.get("text", ""))
        elif b.get("type") == "tool_result":
            cc = b.get("content")
            out.append(cc if isinstance(cc, str) else " ".join(x.get("text", "") for x in cc or [] if isinstance(x, dict)))
    return out


def shape(body):
    o = []
    for m in body.get("messages", []):
        c = m.get("content")
        bl = ["str"] if isinstance(c, str) else [b.get("type") for b in c or []]
        o.append([m.get("role"), bl])
    return o


def model_turn(msgs):
    """The scripted model: decides the next response from the request history ONLY (as a model with its context).
    1. an unanswered probe -> its strict one-line reply, no tool (end_turn);
    2. no assistant turn yet -> ./step.sh 1 start;
    3. the last message carries a successful tool result -> (the control reply if pending, then) the NEXT step;
    4. "Continue the task." -> re-issue the interrupted step's command, read from the history;
    5. otherwise -> "ok" (end_turn)."""
    hist = "\n".join(t for m in msgs for t in texts(m))
    users = [t for m in msgs if m.get("role") == "user" for t in texts(m)]
    done = [int(x) for x in re.findall(r"STEP (\d+) OK", hist)]
    last_done = max(done) if done else 0
    answered = lambda tok: any(tok in t for m in msgs if m.get("role") == "assistant" for t in texts(m))
    cwm = re.search(r"Remember this codeword: (\S+)\.", hist)
    reply = lambda tok: {"type": "text", "text": f"{tok} CODEWORD={cwm.group(1) if cwm else 'unknown'} LAST={last_done}"}
    step = lambda cmd: {"type": "tool_use", "id": f"toolu_m{len(log):04d}", "name": "Bash", "input": {"command": cmd, "description": "step"}}
    if any(PRB_TOK in u for u in users) and not answered(PRB_TOK):
        return [reply(PRB_TOK)], "end_turn"
    if not any(m.get("role") == "assistant" for m in msgs):
        return [step("./step.sh 1 start")], "tool_use"
    last = msgs[-1].get("content") if msgs else None
    ok_results = [b for b in (last if isinstance(last, list) else []) if b.get("type") == "tool_result" and not b.get("is_error")]
    pre = [reply(CTL_TOK)] if any(CTL_TOK in u for u in users) and not answered(CTL_TOK) else []
    if ok_results:
        nx = re.findall(r"NEXT: \./step\.sh (\d+) ([a-z0-9]+)", " ".join(texts({"content": ok_results})))
        if nx and int(nx[-1][0]) <= LAST_STEP:
            return pre + [step(f"./step.sh {nx[-1][0]} {nx[-1][1]}")], "tool_use"
        return pre + [{"type": "text", "text": "done"}], "end_turn"
    if users and "Continue the task." in users[-1]:
        errs = {b.get("tool_use_id") for m in msgs for b in (m.get("content") if isinstance(m.get("content"), list) else []) if b.get("type") == "tool_result" and b.get("is_error")}
        cmds = [b["input"]["command"] for m in msgs if m.get("role") == "assistant" for b in (m.get("content") if isinstance(m.get("content"), list) else [])
                if b.get("type") == "tool_use" and b.get("id") in errs]
        if cmds:
            return [step(cmds[-1])], "tool_use"
    return pre or [{"type": "text", "text": "ok"}], "end_turn"


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, ctype, data):
        self.send_response(code); self.send_header("content-type", ctype); self.send_header("content-length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        path = self.path.split("?")[0]
        if not path.endswith("/v1/messages"):
            with lock:
                log.append({"t": time.time(), "phase": phase[0], "path": path})
            return self._send(200, "application/json", b"{}")
        msgs = body.get("messages", [])
        main = any(t.get("name") == "Bash" for t in body.get("tools", []))
        blocks, stop = model_turn(msgs) if main else ([{"type": "text", "text": "title"}], "end_turn")
        orphan = []
        for m in msgs:
            for b in (m.get("content") if isinstance(m.get("content"), list) else []):
                if b.get("type") == "tool_result" and b.get("is_error"):
                    cc = b.get("content")
                    cc = cc if isinstance(cc, str) else " ".join(x.get("text", "") for x in cc or [] if isinstance(x, dict))
                    orphan.append({"id_tail": b.get("tool_use_id", "")[-8:], "interrupted_text": cc.startswith("[Tool call interrupted")})
        with lock:
            log.append({"t": time.time(), "phase": phase[0], "path": path, "main": main, "n_messages": len(msgs), "shape": shape(body),
                        "error_tool_results": orphan, "model": body.get("model"), "response": [b["type"] for b in blocks]})
        mid = f"msg_mock{len(log):04d}"
        ev = []
        E = lambda t, d: ev.append(f"event: {t}\ndata: {json.dumps(dict(d, type=t))}\n\n")
        E("message_start", {"message": {"id": mid, "type": "message", "role": "assistant", "model": body.get("model"), "content": [], "stop_reason": None,
                                        "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
        for i, b in enumerate(blocks):
            if b["type"] == "text":
                E("content_block_start", {"index": i, "content_block": {"type": "text", "text": ""}})
                E("content_block_delta", {"index": i, "delta": {"type": "text_delta", "text": b["text"]}})
            else:
                E("content_block_start", {"index": i, "content_block": {"type": "tool_use", "id": b["id"], "name": b["name"], "input": {}}})
                E("content_block_delta", {"index": i, "delta": {"type": "input_json_delta", "partial_json": json.dumps(b["input"])}})
            E("content_block_stop", {"index": i})
        E("message_delta", {"delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 5}})
        E("message_stop", {})
        self._send(200, "text/event-stream", "".join(ev).encode())

    do_GET = do_HEAD = do_PUT = do_DELETE = do_POST


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
env = {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "C.UTF-8", "ANTHROPIC_API_KEY": fake,
       "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{srv.server_address[1]}"}


def launch():
    pid, fd = pty.fork()
    if pid == 0:
        os.execve("/bin/sh", ["/bin/sh", "-c", open(boot).read(), open(b64).read(), sha], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 160, 0, 0))
    return pid, fd


def pump(fd, secs, until=None):
    t = time.time()
    while time.time() - t < secs:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                os.read(fd, 65536)
            except OSError:
                return False
        if until and until():
            return True
    return False


def lines(name):
    try:
        return open(os.path.join(SB, "repo", name)).read().splitlines()
    except FileNotFoundError:
        return []


def attempt_open(n):
    return any(l.startswith(f"attempt n={n} ") for l in lines("attempts.log")) and not any(l.startswith(f"done n={n} ") for l in lines("progress.log"))


def kill_all(final=False):
    """A pod loss: SIGKILL every process in this PID namespace except this one (PID 1). With PROBE_KILL=term1
    (phase A only), SIGTERM first and SIGKILL 1 s later, as a 1 s-grace pod delete does to the container."""
    if not final and os.environ.get("PROBE_KILL") == "term1":
        for p in os.listdir("/proc"):
            if p.isdigit() and int(p) != os.getpid():
                try:
                    os.kill(int(p), signal.SIGTERM)
                except OSError:
                    pass
        time.sleep(1.0)
    for p in os.listdir("/proc"):
        if p.isdigit() and int(p) != os.getpid():
            try:
                os.kill(int(p), signal.SIGKILL)
            except OSError:
                pass
    time.sleep(0.5)
    while True:
        try:
            if os.waitpid(-1, os.WNOHANG) == (0, 0):
                break
        except ChildProcessError:
            break


def claude_argv():
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                if os.readlink(f"/proc/{p}/exe") == os.path.realpath(BIN):
                    return open(f"/proc/{p}/cmdline", "rb").read().split(b"\0")
            except OSError:
                pass
    return None


rep = {}
# ---- phase A
pid, fd = launch()
rep["A_step1_started"] = pump(fd, 60, lambda: bool(lines("attempts.log")))
os.write(fd, CONTROL.encode()); time.sleep(0.3); os.write(fd, b"\r")
rep["A_step2_started"] = pump(fd, 60, lambda: attempt_open(2))
with lock:
    rep["A_control_answered"] = any("text" in (e.get("response") or []) for e in log if e.get("main"))
time.sleep(1.0)
R = os.path.join(W, "R"); os.makedirs(R, exist_ok=True)
for n in ("attempts", "progress", "refusals", "ledger", "locks"):
    p = os.path.join(SB, "repo", f"{n}.log")
    if os.path.exists(p):
        shutil.copy(p, R)
shutil.copy(os.path.join(SB, "repo", ".state", "next-token.sha256"), os.path.join(W, "R-token"))
shutil.copy(os.path.join(SB, "state-id"), os.path.join(W, "R-state-id"))
sid = open(os.path.join(SB, "launch", "sid")).read().strip()
tr = [os.path.join(d, f) for d, _, fs in os.walk(os.path.join(SB, "claude", "projects")) for f in fs if f.endswith(".jsonl")]
rep["A_transcripts"] = len(tr)
shutil.copy(tr[0], os.path.join(W, "R.jsonl"))
rep["A_step2_open_at_kill"] = attempt_open(2)
kill_all()
rep["A_alive_after_kill"] = sum(1 for p in os.listdir("/proc") if p.isdigit() and int(p) != os.getpid())
# ---- phase B (the canonical command again)
phase[0] = "B"
nB = len(log)
pid, fd = launch()
pump(fd, 12)
argv = claude_argv() or []
rep["B_argv_resume"] = b"--resume" in argv and sid.encode() in argv
rep["B_argv_session_id"] = b"--session-id" in argv
rep["B_argv_last_is_sid"] = bool(argv) and [a for a in argv if a][-1] == sid.encode()
with lock:
    rep["B_main_requests_before_input"] = sum(1 for e in log[nB:] if e.get("main"))
nP = len(log)
os.write(fd, PROBE.encode()); time.sleep(0.3); os.write(fd, b"\r")
pump(fd, 15, lambda: any(e.get("main") for e in log[nP:]))
pump(fd, 3)
with lock:
    first = next((e for e in log[nP:] if e.get("main")), None)
rep["B_probe_request"] = {k: first.get(k) for k in ("n_messages", "shape", "error_tool_results", "response")} if first else None
os.write(fd, b"Continue the task."); time.sleep(0.3); os.write(fd, b"\r")
rep["B_done_4"] = pump(fd, 90, lambda: any(l.startswith("done n=4 ") for l in lines("progress.log")))
pump(fd, 3)
kill_all(final=True)
tr2 = sorted(os.path.basename(os.path.join(d, f)) for d, _, fs in os.walk(os.path.join(SB, "claude", "projects")) for f in fs if f.endswith(".jsonl"))
rep["B_transcripts"] = tr2
rep["sid_file"] = sid + ".jsonl"
rep["requests_main_total"] = sum(1 for e in log if e.get("main"))
json.dump(rep, open(os.path.join(W, "report.json"), "w"), indent=1)
srv.shutdown()
