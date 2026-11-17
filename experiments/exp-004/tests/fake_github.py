#!/usr/bin/env python3
"""FAKE GitHub API for offline EXP-004 tests (127.0.0.1 only; NOT evidence of real GitHub behavior).

    fake_github.py --port N --pub PUBKEY.pem [--ttl 3600] [--misbehave broaden|redirect] [--delay S]
                   [--fail-delete] [--delete-delay S] [--token-len N] [--git-root DIR]

POST /app/installations/42/access_tokens   verifies the App JWT (RS256 via openssl, iss, iat/exp)
DELETE /installation/token                 revokes the bearer installation token
  --fail-delete: DELETE answers 500.  --delete-delay S: sleep S seconds before answering a DELETE.
  --token-len N: ~N-char stateless-style tokens
  (ghs_<app id>_<b64url>.<b64url>.<b64url>, with . - _ in them) instead of the short form.
  --git-root DIR: /<owner>/<repo>.git/... is Git smart HTTP via `git http-backend`; Basic auth,
  user x-access-token, password = a minted, unrevoked, unexpired token whose repositories include
  <repo> (401 otherwise, 404 for another repo).
GET /__fake/ctl?fail_delete=0|1&delete_delay=S&delete_trickle=0|1   change DELETE behavior at runtime
  (a test can mint normally, then make DELETEs slow or failing). delete_trickle=1: DELETE answers 200
  with Content-Length 120 then sends one byte per second, so the issuer's per-socket-op timeout never
  fires and the DELETE outlives any total deadline (an unresolved network operation); the token is
  NOT revoked in that case. A DELETE's arrival is logged as event=delete_arrived (no "method" key);
  its answer as method=DELETE with the status.
GET /__fake/state                          token sha256 prefixes + revoked flags (test assertions)
Installation 42 has repos {"a"} and grants contents:write, metadata:read. Request bodies and
statuses are logged to stderr (bodies contain no secrets; tokens are never logged, only prefixes).
"""

import argparse
import base64
import re
import hashlib
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

GRANTED = {"contents": "write", "metadata": "read"}
LEVEL = {"read": 1, "write": 2, "admin": 3}
REPOS = {"a"}
CTL = {"fail_delete": False, "delete_delay": 0.0, "delete_trickle": False}  # runtime-mutable
TOKENS = {}  # token -> {"revoked": bool, "exp": int, "repos": [names]}
GIT_RE = re.compile(r"^/([\w.-]+)/([\w.-]+?)\.git(/.*)?$")


def make_token(n):
    """Short form, or a stateless-style token of exactly n chars (n > 0)."""
    if not n:
        return "ghs_FAKE" + secrets.token_hex(16)
    pre = "ghs_%06d_" % secrets.randbelow(10**6)
    while True:
        body = ".".join(base64.urlsafe_b64encode(x).rstrip(b"=").decode() for x in (
            b'{"alg":"fake","typ":"ghs"}', b'{"i":42,"r":"a","n":"%s"}' % secrets.token_hex(8).encode(),
            secrets.token_bytes(n)))
        tok = (pre + body)[:n]
        if n < 40 or all(c in tok[len(pre):] for c in ".-_"):
            return tok


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def jwt_ok(tok, pub, tmp):
    try:
        h, p, sig = tok.split(".")
        hd, pl = json.loads(b64d(h)), json.loads(b64d(p))
        if hd.get("alg") != "RS256" or not pl.get("iss") or pl["exp"] - pl["iat"] > 600:
            return False
        if not pl["iat"] - 5 <= time.time() <= pl["exp"]:
            return False
        sf = os.path.join(tmp, "sig" + secrets.token_hex(4))
        with open(sf, "wb") as f:
            f.write(b64d(sig))
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sf],
                           input=(h + "." + p).encode(), capture_output=True, check=False)
        os.unlink(sf)
        return r.returncode == 0
    except Exception:
        return False


def make_handler(a, tmp):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def note(self, **kw):
            print(json.dumps({"ts": round(time.time(), 3), **kw}), file=sys.stderr, flush=True)

        def reply(self, code, obj=None):
            raw = json.dumps(obj).encode() if obj is not None else b""
            self.send_response(code)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def bearer(self):
            return self.headers.get("Authorization", "")[7:]

        def body(self):
            if "chunked" in self.headers.get("Transfer-Encoding", ""):
                out = b""
                while True:
                    n = int(self.rfile.readline().split(b";")[0], 16)
                    out += self.rfile.read(n)
                    self.rfile.readline()
                    if n == 0:
                        return out
            return self.rfile.read(int(self.headers.get("Content-Length") or 0))

        def git(self, m, url):
            """Smart HTTP behind token auth; tokens are never logged."""
            try:
                user, _, pw = base64.b64decode(self.headers.get("Authorization", "")[6:]).decode().partition(":")
            except ValueError:
                user, pw = "", ""
            t = TOKENS.get(pw) if user == "x-access-token" else None
            body = self.body()
            if not t or t["revoked"] or t["exp"] <= time.time():
                code = 401
            elif m[2] not in t["repos"] or not os.path.isdir(os.path.join(a.git_root, m[1], m[2] + ".git")):
                code = 404
            else:
                code = 0
            self.note(kind="git", method=self.command, path=url.path, auth=bool(pw), status=code or "cgi")
            if code:
                self.send_response(code)
                if code == 401:
                    self.send_header("WWW-Authenticate", 'Basic realm="fake"')
                self.send_header("Content-Length", "0")
                return self.end_headers()
            h = self.headers
            env = {"PATH": os.environ["PATH"], "GIT_PROJECT_ROOT": a.git_root, "GIT_HTTP_EXPORT_ALL": "1",
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                   "PATH_INFO": url.path, "QUERY_STRING": url.query, "REQUEST_METHOD": self.command,
                   "CONTENT_TYPE": h.get("Content-Type", ""), "CONTENT_LENGTH": str(len(body)),
                   "REMOTE_USER": "x-access-token", "REMOTE_ADDR": self.client_address[0]}
            for src, dst in (("Content-Encoding", "HTTP_CONTENT_ENCODING"), ("Git-Protocol", "HTTP_GIT_PROTOCOL")):
                if h.get(src):
                    env[dst] = h[src]
            p = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True)
            head, sep, out = p.stdout.partition(b"\r\n\r\n")
            if not sep:
                head, sep, out = p.stdout.partition(b"\n\n")
            code, hdrs = 200, []
            for line in head.decode("latin-1").splitlines():
                k, _, v = line.partition(":")
                if k.lower() == "status":
                    code = int(v.split()[0])
                elif k:
                    hdrs.append((k, v.strip()))
            self.send_response(code)
            for k, v in hdrs:
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def do_GET(self):
            m = GIT_RE.match(urlsplit(self.path).path) if a.git_root else None
            if m:
                return self.git(m, urlsplit(self.path))
            if self.path == "/__fake/elsewhere":  # urllib re-sends a redirected POST as GET
                self.note(method="GET", path=self.path, followed_redirect=True,
                          had_auth=bool(self.headers.get("Authorization")))
                return self.reply(404, {"message": "Not Found"})
            if self.path.startswith("/__fake/ctl"):
                q = parse_qs(urlsplit(self.path).query)
                if "fail_delete" in q:
                    CTL["fail_delete"] = q["fail_delete"][0] == "1"
                if "delete_delay" in q:
                    CTL["delete_delay"] = float(q["delete_delay"][0])
                if "delete_trickle" in q:
                    CTL["delete_trickle"] = q["delete_trickle"][0] == "1"
                return self.reply(200, CTL)
            if self.path != "/__fake/state":
                return self.reply(404, {"message": "Not Found"})
            self.reply(200, {hashlib.sha256(t.encode()).hexdigest()[:8]: v["revoked"]
                             for t, v in TOKENS.items()})

        def do_DELETE(self):
            self.note(event="delete_arrived")
            if CTL["delete_trickle"]:
                self.send_response(200)
                self.send_header("Content-Length", "120")
                self.end_headers()
                self.wfile.flush()
                try:
                    for _ in range(120):
                        time.sleep(1)
                        self.wfile.write(b" ")
                        self.wfile.flush()
                except OSError:
                    pass
                self.close_connection = True
                return
            if CTL["delete_delay"]:
                time.sleep(CTL["delete_delay"])
            t = TOKENS.get(self.bearer())
            if CTL["fail_delete"]:
                self.note(method="DELETE", path=self.path, status=500)
                return self.reply(500, {"message": "Server Error"})
            ok = self.path == "/installation/token" and t and not t["revoked"]
            if ok:
                t["revoked"] = True
            self.note(method="DELETE", path=self.path, status=204 if ok else 401)
            self.reply(204) if ok else self.reply(401, {"message": "Bad credentials"})

        def do_POST(self):
            m = GIT_RE.match(urlsplit(self.path).path) if a.git_root else None
            if m:
                return self.git(m, urlsplit(self.path))
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if a.misbehave == "redirect":  # 302: urllib would follow it (as GET) by default
                self.send_response(302)
                self.send_header("Location", "/__fake/elsewhere")
                self.send_header("Content-Length", "0")
                return self.end_headers()
            ok = jwt_ok(self.bearer(), a.pub, tmp)
            if not ok:
                self.note(method="POST", path=self.path, status=401, jwt="bad")
                return self.reply(401, {"message": "A JSON web token could not be decoded"})
            if self.path != "/app/installations/42/access_tokens":
                return self.reply(404, {"message": "Not Found"})
            perms, repos = body.get("permissions", {}), body.get("repositories", [])
            code, msg = 201, None
            if any(LEVEL.get(v, 99) > LEVEL.get(GRANTED.get(k), 0) for k, v in perms.items()):
                code, msg = 422, "The permissions requested are not granted to this installation."
            elif not set(repos) <= REPOS:  # real GitHub wording/status may differ (fake)
                code, msg = 422, "There is at least one repository that does not exist or is not accessible to the parent installation."
            self.note(method="POST", path=self.path, status=code, jwt="ok", body=body)
            if msg:
                return self.reply(code, {"message": msg})
            time.sleep(a.delay)  # lets a test signal the issuer while a mint is in flight
            tok = make_token(a.token_len)
            exp = int(time.time()) + a.ttl
            TOKENS[tok] = {"revoked": False, "exp": exp, "repos": list(repos)}
            names = list(repos) + (["extra"] if a.misbehave == "broaden" else [])
            self.reply(201, {"token": tok, "permissions": perms,
                             "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(exp)),
                             "repositories": [{"name": n} for n in names]})
    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--pub", required=True)
    ap.add_argument("--ttl", type=int, default=3600)
    ap.add_argument("--misbehave", choices=["broaden", "redirect"])
    ap.add_argument("--delay", type=float, default=0, help="seconds before answering a mint")
    ap.add_argument("--fail-delete", action="store_true", help="DELETE answers 500")
    ap.add_argument("--delete-delay", type=float, default=0, help="seconds before answering a DELETE")
    ap.add_argument("--token-len", type=int, default=0, help="stateless-style token of exactly N chars")
    ap.add_argument("--git-root", help="serve bare repos DIR/<owner>/<repo>.git over token-authed HTTP")
    a = ap.parse_args()
    CTL["fail_delete"], CTL["delete_delay"] = a.fail_delete, a.delete_delay
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    tmp = tempfile.mkdtemp(prefix="fakegh.")
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(a, tmp))
        srv.daemon_threads = True  # a sleeping/trickling DELETE must not block fake shutdown
        srv.serve_forever()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
