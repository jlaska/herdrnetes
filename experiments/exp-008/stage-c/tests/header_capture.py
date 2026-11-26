"""Header capture for tests/header-capture-test.sh (run inside a network namespace with loopback only).

Starts a mock Anthropic endpoint on 127.0.0.1, runs the EXP-008 Stage C bootstrap (the real launcher and the
real, sha256-pinned Claude Code binary) under a PTY with a FAKE placeholder in ANTHROPIC_API_KEY and
ANTHROPIC_BASE_URL pointing at the mock, and records, per request, the method, path, header NAMES and the
FORM of the credential-bearing headers (never a value). Every request is answered 403, so no model runs.

usage: header_capture.py <out.json> <boot_script> <package.b64> <package_sha256> <fake_placeholder> <seconds>
"""
import http.server
import json
import os
import pty
import re
import select
import signal
import sys
import threading
import time

out, boot, b64, sha, fake, secs = sys.argv[1:7]
secs = float(secs)
reqs = []


def form(v):
    if v is None:
        return "absent"
    if v == fake:
        return "placeholder"
    if v == "Bearer " + fake:
        return "bearer-placeholder"
    if fake in v:
        return "contains-placeholder"
    return "other"


class H(http.server.BaseHTTPRequestHandler):
    def _any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        reqs.append({
            "method": self.command, "path": self.path.split("?")[0],
            "header_names": sorted(k.lower() for k in self.headers.keys()),
            "x-api-key": form(self.headers.get("x-api-key")),
            "authorization": form(self.headers.get("authorization")),
            "placeholder_in_other_headers": sorted(k.lower() for k, v in self.headers.items()
                                                   if fake in v and k.lower() not in ("x-api-key", "authorization")),
            "placeholder_in_body": fake.encode() in body,
        })
        msg = json.dumps({"type": "error", "error": {"type": "permission_error", "message": "header-capture mock"}}).encode()
        self.send_response(403)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(msg)))
        self.end_headers()
        self.wfile.write(msg)

    do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = _any

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
env = {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "C.UTF-8",
       "ANTHROPIC_API_KEY": fake, "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{srv.server_address[1]}"}
pid, fd = pty.fork()
if pid == 0:
    os.execve("/bin/sh", ["/bin/sh", "-c", open(boot).read(), open(b64).read(), sha], env)
screen = b""
t0 = time.time()
first_post = None
while time.time() - t0 < secs:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try:
            screen += os.read(fd, 65536)
        except OSError:
            break
    posts = [q for q in reqs if q["method"] == "POST" and q["path"].endswith("/v1/messages")]
    if posts and first_post is None:
        first_post = time.time()
    if first_post and time.time() - first_post > 5:
        break
for s in (signal.SIGTERM, signal.SIGKILL):
    try:
        os.killpg(pid, s)
    except OSError:
        pass
    time.sleep(0.5)
srv.shutdown()
text = screen.decode("utf-8", "replace")
# Ink positions words with cursor movements, not spaces: turn CSI n C (cursor forward) into n spaces, drop every
# other CSI / OSC sequence, then collapse whitespace before matching (an unvalidated raw match missed the dialog).
text = re.sub(r"\x1b\[(\d*)C", lambda m: " " * int(m.group(1) or 1), text)
text = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", text)
text = re.sub(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]", " ", text)
text = re.sub(r"\x1b[@-_]", " ", text)
text = re.sub(r"\s+", " ", text).lower()
json.dump({
    "requests": reqs,
    "messages_posts": sum(1 for q in reqs if q["method"] == "POST" and q["path"].endswith("/v1/messages")),
    "custom_key_dialog_seen": "custom api key" in text or "use this api key" in text,
    "screen_bytes": len(screen),
    "seconds": round(time.time() - t0, 1),
}, open(out, "w"), indent=1)
