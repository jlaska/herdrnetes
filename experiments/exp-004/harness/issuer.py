#!/usr/bin/env python3
"""EXP-004 credential issuer: mints short-lived, repository-scoped mock tokens on a Unix socket.

    issuer.py <socket> --policy policy.json --root-key FILE --admin-secret FILE --state FILE

Policy: {"clients": {"<id>": {"secret_sha256": "<hex>", "repos": {"owner/repo": "read"|"write"}}},
         "ttl_seconds": N}
The root key (mock of the GitHub App private key) and the admin secret live in files outside any
pane HOME. Requests are one JSON line, replies one JSON line:
  token         {client, secret, repo, access}   -> {token, expires_at, repo, access}
  revoke_own    {client, secret, token}          client revokes a token it holds (credential erase)
  revoke_token  {admin, token}                   admin
  revoke_client {admin, client}                  admin; also revokes the client's outstanding tokens.
                                                 Persisted to --state so a restart cannot undo it
  reinstate_client {admin, client}               admin; undoes revoke_client
  introspect    {admin, token, repo}             admin (the mock host) -> {valid, reason, access}
Tokens exist only in memory (a restart invalidates them); client revocations persist in --state. Logs (stderr, JSON) carry peer pid/uid/gid and a sha256 prefix of the
token, never the token or any secret. If EXP004_TEST_RECORD_TOKENS=<path> is set, minted tokens are
appended to that file so the leak scan can search for them (test-only).
"""

import argparse
import hashlib
import hmac
import json
import os
import secrets
import socket
import socketserver
import struct
import sys
import threading
import time

ADMIN_OPS = {"revoke_token", "revoke_client", "reinstate_client", "introspect"}
LEVEL = {"read": 1, "write": 2}


class Refuse(Exception):
    pass


def mint_github(repo, access):
    """NOT IMPLEMENTED (out of scope for EXP-004; `--backend github` is a later experiment).

    Real call: sign a JWT (RS256, iss=<app id>, iat=now-60, exp<=now+600) with the GitHub App
    private key, then POST https://api.github.com/app/installations/{installation_id}/access_tokens
    with body {"repositories": ["<name>"], "permissions": {"contents": "read"|"write"}}.
    The response carries the installation token ("ghs_...") and "expires_at" (about 1 hour).
    """
    raise NotImplementedError("github backend is out of scope for EXP-004")


def sha_prefix(token):
    return hashlib.sha256(token.encode()).hexdigest()[:8]


class Issuer:
    def __init__(self, policy, root_key, admin_secret, state):
        self.policy, self.root_key, self.admin, self.state = policy, root_key, admin_secret, state
        self.tokens = {}  # token -> {repo, access, client, exp, revoked}
        # No state file = no revocations; an unreadable one is fatal (fail closed).
        self.revoked_clients = set(json.load(open(state))) if os.path.exists(state) else set()
        self.lock = threading.Lock()
        self.record = os.environ.get("EXP004_TEST_RECORD_TOKENS")

    def client(self, req):
        c = self.policy["clients"].get(str(req.get("client")))
        digest = hashlib.sha256(str(req.get("secret", "")).encode()).hexdigest()
        # Same message for unknown client and bad secret; compare even if unknown.
        want = c["secret_sha256"] if c else "0" * 64
        if not hmac.compare_digest(digest, want) or not c:
            raise Refuse("unknown client or bad secret")
        if req["client"] in self.revoked_clients:
            raise Refuse("client revoked by administrator")
        return c

    def need_admin(self, req):
        if not hmac.compare_digest(str(req.get("admin", "")), self.admin):
            raise Refuse("admin secret required")

    def mint(self, req):
        c = self.client(req)
        repo, access = str(req.get("repo")), str(req.get("access"))
        if repo not in c["repos"]:
            raise Refuse(f"repository {repo} not in policy for this client")
        if access not in LEVEL or LEVEL[access] > LEVEL[c["repos"][repo]]:
            raise Refuse(f"access {access} exceeds policy ({c['repos'][repo]}) for {repo}")
        # Mock of the GitHub App key signing the grant: token = HMAC(root_key, nonce).
        nonce = secrets.token_bytes(16)
        token = "ghs_mock_" + hmac.new(self.root_key, nonce, "sha256").hexdigest()[:32]
        exp = int(time.time()) + int(self.policy["ttl_seconds"])
        with self.lock:
            self.tokens[token] = {"repo": repo, "access": access, "client": req["client"],
                                  "exp": exp, "revoked": False}
        if self.record:
            with open(self.record, "a") as f:
                f.write(token + "\n")
        return {"token": token, "expires_at": exp, "repo": repo, "access": access}

    def revoke(self, token, client=None):
        with self.lock:
            rec = self.tokens.get(token)
            if not rec or (client and rec["client"] != client):
                raise Refuse("unknown token")
            rec["revoked"] = True
        return {"revoked": 1}

    def save_state(self):
        tmp = self.state + ".tmp"
        with open(tmp, "w") as f:
            json.dump(sorted(self.revoked_clients), f)
        os.replace(tmp, self.state)

    def reinstate_client(self, req):
        with self.lock:
            self.revoked_clients.discard(str(req.get("client")))
            self.save_state()
        return {"reinstated": 1}

    def revoke_client(self, req):
        with self.lock:
            self.revoked_clients.add(str(req.get("client")))
            self.save_state()
            n = 0
            for rec in self.tokens.values():
                if rec["client"] == req.get("client") and not rec["revoked"]:
                    rec["revoked"], n = True, n + 1
        return {"revoked": n}

    def introspect(self, req):
        rec = self.tokens.get(str(req.get("token")))
        if not rec:
            return {"valid": False, "reason": "unknown"}
        out = {"access": rec["access"], "repo": rec["repo"], "client": rec["client"]}
        if rec["revoked"]:
            return {**out, "valid": False, "reason": "revoked"}
        if rec["exp"] <= time.time():
            return {**out, "valid": False, "reason": "expired"}
        if rec["repo"] != req.get("repo"):
            return {**out, "valid": False, "reason": "wrong_repo"}
        return {**out, "valid": True, "reason": "ok"}

    def handle(self, req):
        op = req.get("op")
        if op in ADMIN_OPS:
            self.need_admin(req)
        if op == "token":
            return self.mint(req)
        if op == "revoke_own":
            self.client(req)
            return self.revoke(str(req.get("token")), req["client"])
        if op == "revoke_token":
            return self.revoke(str(req.get("token")))
        if op == "revoke_client":
            return self.revoke_client(req)
        if op == "reinstate_client":
            return self.reinstate_client(req)
        if op == "introspect":
            return self.introspect(req)
        raise Refuse("unknown op")


def log(**kw):
    print(json.dumps({"ts": round(time.time(), 3), **kw}), file=sys.stderr, flush=True)


def make_handler(issuer):
    class H(socketserver.StreamRequestHandler):
        def handle(self):
            pid, uid, gid = struct.unpack("3i", self.request.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            self.request.settimeout(5)
            req, resp = {}, {}
            try:
                req = json.loads(self.rfile.readline(65536))
                resp = issuer.handle(req)
            except Refuse as e:
                resp = {"error": str(e)}
            except Exception as e:  # malformed input; never echo the request
                resp = {"error": f"bad request ({type(e).__name__})"}
            tok = resp.get("token") or req.get("token")
            log(op=req.get("op"), client=req.get("client"), repo=req.get("repo"),
                access=req.get("access"), peer={"pid": pid, "uid": uid, "gid": gid},
                token_sha256_8=sha_prefix(tok) if tok else None,
                result=resp.get("error") or resp.get("reason") or "ok")
            self.wfile.write((json.dumps(resp) + "\n").encode())
    return H


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("socket")
    ap.add_argument("--policy", required=True)
    ap.add_argument("--root-key", required=True)
    ap.add_argument("--admin-secret", required=True)
    ap.add_argument("--state", required=True, help="persisted client revocations (JSON list)")
    ap.add_argument("--backend", default="mock", choices=["mock", "github"])
    a = ap.parse_args()
    if a.backend == "github":
        mint_github(None, None)
    policy = json.load(open(a.policy))
    root_key = open(a.root_key, "rb").read().strip()
    os.umask(0o177)
    issuer = Issuer(policy, root_key, open(a.admin_secret).read().strip(), a.state)
    if os.path.exists(a.socket):
        os.unlink(a.socket)
    srv = Server(a.socket, make_handler(issuer))
    os.chmod(a.socket, 0o600)
    log(event="listening", socket=a.socket, ttl=policy["ttl_seconds"])
    srv.serve_forever()


if __name__ == "__main__":
    main()
