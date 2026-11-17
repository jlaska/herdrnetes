#!/usr/bin/env python3
"""FAKE GitHub API for offline EXP-004 tests (127.0.0.1 only; NOT evidence of real GitHub behavior).

    fake_github.py --port N --pub PUBKEY.pem [--ttl 3600] [--misbehave broaden]

POST /app/installations/42/access_tokens   verifies the App JWT (RS256 via openssl, iss, iat/exp)
DELETE /installation/token                 revokes the bearer installation token
GET /__fake/state                          token sha256 prefixes + revoked flags (test assertions)
Installation 42 has repos {"a"} and grants contents:write, metadata:read. Request bodies and
statuses are logged to stderr (bodies contain no secrets; tokens are never logged, only prefixes).
"""

import argparse
import base64
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
from http.server import BaseHTTPRequestHandler, HTTPServer

GRANTED = {"contents": "write", "metadata": "read"}
LEVEL = {"read": 1, "write": 2, "admin": 3}
REPOS = {"a"}
TOKENS = {}  # token -> {"revoked": bool, "exp": int}


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
        sf = os.path.join(tmp, "sig")
        with open(sf, "wb") as f:
            f.write(b64d(sig))
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sf],
                           input=(h + "." + p).encode(), capture_output=True, check=False)
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

        def do_GET(self):
            if self.path == "/__fake/elsewhere":  # urllib re-sends a redirected POST as GET
                self.note(method="GET", path=self.path, followed_redirect=True,
                          had_auth=bool(self.headers.get("Authorization")))
                return self.reply(404, {"message": "Not Found"})
            if self.path != "/__fake/state":
                return self.reply(404, {"message": "Not Found"})
            self.reply(200, {hashlib.sha256(t.encode()).hexdigest()[:8]: v["revoked"]
                             for t, v in TOKENS.items()})

        def do_DELETE(self):
            t = TOKENS.get(self.bearer())
            ok = self.path == "/installation/token" and t and not t["revoked"]
            if ok:
                t["revoked"] = True
            self.note(method="DELETE", path=self.path, status=204 if ok else 401)
            self.reply(204) if ok else self.reply(401, {"message": "Bad credentials"})

        def do_POST(self):
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
            tok = "ghs_FAKE" + secrets.token_hex(16)
            exp = int(time.time()) + a.ttl
            TOKENS[tok] = {"revoked": False, "exp": exp}
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
    a = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    tmp = tempfile.mkdtemp(prefix="fakegh.")
    try:
        HTTPServer(("127.0.0.1", a.port), make_handler(a, tmp)).serve_forever()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
