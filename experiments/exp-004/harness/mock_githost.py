#!/usr/bin/env python3
"""EXP-004 mock GitHub-like Git host: smart HTTP via `git http-backend`, token auth via the issuer.

    mock_githost.py --root DIR --port N --issuer-sock S --admin-file F

Serves bare repos DIR/<owner>/<repo>.git at /<owner>/<repo>.git/... on 127.0.0.1 (plain HTTP; the
mock is not HTTPS). Every request needs Basic auth, user `x-access-token`, password = issuer token.
  no/invalid/expired/revoked token -> 401     token for another repo (or no such repo) -> 404
  read token on a push             -> 403     otherwise                                 -> CGI
Logs method, path, status and reason to stderr; never credentials.
"""

import argparse
import base64
import json
import os
import re
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PATH_RE = re.compile(r"^/([\w.-]+)/([\w.-]+?)(?:\.git)?(/.*)$")


def introspect(token, repo):
    req = {"op": "introspect", "admin": ARGS.admin, "token": token, "repo": repo}
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5)
        s.connect(ARGS.issuer_sock)
        s.sendall((json.dumps(req) + "\n").encode())
        return json.loads(s.makefile().readline())


class Handler(BaseHTTPRequestHandler):
    why = ""

    def log_message(self, fmt, *args):
        print(f"host {self.command} {self.path} -> {args[1] if len(args) > 1 else ''} {self.why}",
              file=sys.stderr, flush=True)

    def reply(self, code, why, body=b"", headers=()):
        self.why = why
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def token(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic "):
            return None
        try:
            user, _, pw = base64.b64decode(auth[6:]).decode().partition(":")
        except ValueError:
            return None
        return pw if user == "x-access-token" and pw else None

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

    def serve(self):
        url = urlsplit(self.path)
        m = PATH_RE.match(url.path)
        tok = self.token()
        if not tok:
            return self.reply(401, "no credentials", headers=[("WWW-Authenticate", 'Basic realm="mock"')])
        if not m:
            return self.reply(404, "bad path")
        repo = f"{m[1]}/{m[2]}"
        info = introspect(tok, repo)
        if info.get("reason") == "wrong_repo" or (info["valid"] and not os.path.isdir(self.gitdir(m))):
            return self.reply(404, "not found (token scope)")
        if not info["valid"]:
            return self.reply(401, "token " + info["reason"], headers=[("WWW-Authenticate", 'Basic realm="mock"')])
        push = "service=git-receive-pack" in url.query or url.path.endswith("/git-receive-pack")
        if push and info["access"] != "write":
            return self.reply(403, "read-only token cannot push")
        self.cgi(url, self.body())

    def gitdir(self, m):
        return os.path.join(ARGS.root, m[1], m[2] + ".git")

    def cgi(self, url, body):
        h = self.headers
        env = {"PATH": os.environ["PATH"], "GIT_PROJECT_ROOT": ARGS.root, "GIT_HTTP_EXPORT_ALL": "1",
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
        self.reply(code, "cgi", out, hdrs)

    do_GET = do_POST = serve


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--issuer-sock", required=True)
    ap.add_argument("--admin-file", required=True)
    ARGS = ap.parse_args()
    ARGS.admin = open(ARGS.admin_file).read().strip()
    print(f"host listening 127.0.0.1:{ARGS.port}", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
