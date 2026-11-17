#!/usr/bin/env python3
"""EXP-004 credential issuer: mints short-lived, repository-scoped mock tokens on a Unix socket.

    issuer.py <socket> --policy policy.json --admin-secret FILE --state FILE
              [--backend mock --root-key FILE | --backend github] [--socket-mode 0600] [--revoke-on-exit]

Policy: {"clients": {"<id>": {"secret_sha256": "<hex>", "repos": {"owner/repo": "read"|"write"}}},
         "ttl_seconds": N, "client_uids": [int], "admin_uids": [int],
         "github": {"api_url", "app_id", "owner", "installation_id", "private_key_file"}}
  client_uids (optional): token/revoke_own are refused unless the SO_PEERCRED uid is listed.
  admin_uids (default [euid]): admin ops need a listed peer uid AND the admin secret.
  Socket mode alone is NOT the control (a 0666 socket is fine): peer uid + client secret are.
  github backend: repo value "read"|"write" -> {contents: that, metadata: read}; a deliberate probe
  client may instead have {"permissions": {...}} (sent verbatim; request access must be "probe").
  The App private key is only ever passed by path to `openssl dgst -sign`; it is never read here.
The root key (mock of the GitHub App private key) and the admin secret live in files outside any
pane HOME. Requests are one JSON line, replies one JSON line:
  token         {client, secret, repo, access}   -> {token, expires_at, repo, access}
  revoke_own    {client, secret, token}          client revokes a token it holds (credential erase)
  revoke_token  {admin, token}                   admin
  revoke_client {admin, client}                  admin; also revokes the client's outstanding tokens.
                                                 Persisted to --state so a restart cannot undo it
  reinstate_client {admin, client}               admin; undoes revoke_client
  introspect    {admin, token, repo}             admin (the mock host) -> {valid, reason, access}; mock only
  revoke_all    {admin}                          admin; revokes every tracked unexpired token
Tokens exist only in memory and are never written to disk. A mock restart invalidates them; GitHub
tokens outlive a restart, so the github backend revokes them on SIGTERM/SIGINT (after finishing
in-flight mints). Client revocations persist in --state. Logs (stderr, JSON) carry peer pid/uid/gid
and a sha256 prefix of the token, never the token or any secret. Mock backend only: if
EXP004_TEST_RECORD_TOKENS=<path> is set, minted tokens are appended there for the leak scan.
github api_url must be https (http only to 127.0.0.1 for the offline fake); redirects are refused.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import subprocess
import socket
import socketserver
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

ADMIN_OPS = {"revoke_token", "revoke_client", "reinstate_client", "introspect", "revoke_all"}
LEVEL = {"read": 1, "write": 2, "admin": 3}
REDACT = [re.compile(r"gh[a-z]_[A-Za-z0-9_\-\.]+"), re.compile(r"[A-Za-z0-9+/=_\-\.]{30,}")]


class Refuse(Exception):
    pass


def sanitize(msg, limit=120):
    """Truncate a remote message and redact token-like or long base64-ish runs."""
    for rx in REDACT:
        msg = rx.sub("<redacted>", str(msg))
    return msg[:limit]


def b64u(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def make_jwt(app_id, key_file, now=None):
    """RS256 App JWT. Signing is delegated to openssl; the key content never enters Python."""
    now = int(now or time.time())
    inp = ".".join(b64u(json.dumps(p, separators=(",", ":")).encode()) for p in (
        {"alg": "RS256", "typ": "JWT"}, {"iat": now - 60, "exp": now + 540, "iss": app_id}))
    try:
        r = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_file], input=inp.encode(),
                           capture_output=True, check=False, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise Refuse("openssl signing failed (not runnable)")
    if r.returncode != 0 or not r.stdout:
        raise Refuse(f"openssl signing failed (exit {r.returncode})")  # stderr deliberately dropped
    return inp + "." + b64u(r.stdout)


def sha_prefix(token):
    return hashlib.sha256(token.encode()).hexdigest()[:8]


def log(**kw):
    print(json.dumps({"ts": round(time.time(), 3), **kw}), file=sys.stderr, flush=True)


def parse_time(s):
    return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect would carry the Authorization header (JWT or token) to another URL: refuse."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


OPENER = urllib.request.build_opener(NoRedirect)


class GitHub:
    """Minimal GitHub App client: mint and delete installation tokens."""

    def __init__(self, cfg):
        self.api = cfg["api_url"].rstrip("/")
        u = urllib.parse.urlsplit(self.api)
        if not (u.scheme == "https" or (u.scheme == "http" and u.hostname == "127.0.0.1")):
            raise SystemExit("github.api_url must be https (http only to 127.0.0.1 for tests)")
        self.app_id, self.owner = str(cfg["app_id"]), cfg["owner"]
        self.inst, self.key = int(cfg["installation_id"]), cfg["private_key_file"]

    def call(self, method, path, bearer, body=None):
        """-> (status, parsed JSON or {}). Network failure -> Refuse (sanitized)."""
        req = urllib.request.Request(
            self.api + path, method=method, data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + bearer, "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "herdrnetes-exp004",
                     "Content-Type": "application/json"})
        try:
            with OPENER.open(req, timeout=10) as r:
                status, raw = r.status, r.read(1 << 20)
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read(1 << 20)
        except (urllib.error.URLError, OSError, ValueError) as e:
            why = e.reason if isinstance(e, urllib.error.URLError) else e
            raise Refuse(f"github unreachable: {type(why).__name__}")
        try:
            data = json.loads(raw) if raw else {}
        except ValueError:
            data = {}
        return status, data if isinstance(data, dict) else {}

    def mint(self, repo, perms):
        owner, _, name = repo.partition("/")
        if owner != self.owner or not name or "/" in name:
            raise Refuse(f"repository {repo} is not under the configured owner")
        want = {"repositories": [name], "permissions": perms}
        status, d = self.call("POST", f"/app/installations/{self.inst}/access_tokens",
                              make_jwt(self.app_id, self.key), want)
        log(event="github_mint", status=status)
        tok = d.get("token")
        if status != 201:
            raise Refuse(f"github mint failed: HTTP {status} {sanitize(d.get('message', ''))}".rstrip())
        if not isinstance(tok, str) or not tok:
            raise Refuse("github mint failed: no token in response")
        try:
            exp = parse_time(d["expires_at"])
            repos = {r["name"] for r in d.get("repositories", [])}
            got = d.get("permissions", {})
            broader = repos != {name} or any(
                k not in perms or LEVEL.get(v, 99) > LEVEL[perms[k]] for k, v in got.items())
        except (KeyError, TypeError, ValueError, AttributeError):
            broader, exp = True, 0
        return tok, exp, broader

    def delete(self, token):
        """-> True if GitHub confirmed revocation (204)."""
        try:
            status, _ = self.call("DELETE", "/installation/token", token)
        except Refuse:
            status = None
        log(event="github_delete", status=status, token_sha256_8=sha_prefix(token))
        return status == 204


class Issuer:
    def __init__(self, policy, root_key, admin_secret, state, backend="mock"):
        self.policy, self.root_key, self.admin, self.state = policy, root_key, admin_secret, state
        self.backend = backend
        self.gh = GitHub(policy["github"]) if backend == "github" else None
        self.tokens = {}  # token -> {repo, access, client, exp, revoked}
        # No state file = no revocations; an unreadable one is fatal (fail closed).
        self.revoked_clients = set(json.load(open(state))) if os.path.exists(state) else set()
        self.lock = threading.Condition()
        self.closing, self.inflight = False, 0
        self.record = os.environ.get("EXP004_TEST_RECORD_TOKENS") if backend == "mock" else None
        for cid, c in policy["clients"].items():  # a typo must not widen access
            for repo, v in c["repos"].items():
                if v not in ("read", "write") and not (backend == "github" and isinstance(v, dict)):
                    raise SystemExit(f"policy: {cid} {repo}: access must be read or write")

    def client(self, req, uid):
        c = self.policy["clients"].get(str(req.get("client")))
        digest = hashlib.sha256(str(req.get("secret", "")).encode()).hexdigest()
        # Same message for unknown client and bad secret; compare even if unknown.
        want = c["secret_sha256"] if c else "0" * 64
        if "client_uids" in self.policy and uid not in self.policy["client_uids"]:
            raise Refuse("uid not permitted")
        if not hmac.compare_digest(digest, want) or not c:
            raise Refuse("unknown client or bad secret")
        if req["client"] in self.revoked_clients:
            raise Refuse("client revoked by administrator")
        return c

    def need_admin(self, req, uid):
        if uid not in self.policy.get("admin_uids", [os.geteuid()]):
            raise Refuse("uid not permitted for admin ops")
        if not hmac.compare_digest(str(req.get("admin", "")), self.admin):
            raise Refuse("admin secret required")

    def perms_for(self, policy_val, repo, access):
        """github: policy value + requested access -> permissions to request."""
        if isinstance(policy_val, dict):  # deliberate probe client: verbatim, only on "probe"
            if access != "probe":
                raise Refuse(f"access {access} not allowed: probe client must request 'probe'")
            return policy_val["permissions"]
        if access not in ("read", "write") or LEVEL[access] > LEVEL[policy_val]:
            raise Refuse(f"access {access} exceeds policy ({policy_val}) for {repo}")
        return {"contents": access, "metadata": "read"}

    def mint(self, req, uid):
        c = self.client(req, uid)
        repo, access = str(req.get("repo")), str(req.get("access"))
        if repo not in c["repos"]:
            raise Refuse(f"repository {repo} not in policy for this client")
        if self.gh:
            perms = self.perms_for(c["repos"][repo], repo, access)
            with self.lock:
                if self.closing:
                    raise Refuse("issuer shutting down")
                self.inflight += 1
            try:
                tok, exp, broader = self.gh.mint(repo, perms)
                # Track before anything else so revoke_all covers it even if a DELETE below fails.
                out = self.track(tok, exp, repo, access, req["client"])
                if broader:  # fail closed: never hand out a token wider than asked
                    self.kill(tok, self.tokens[tok])
                    raise Refuse("github returned a token broader than requested or malformed; revoked")
                return out
            finally:
                with self.lock:
                    self.inflight -= 1
                    self.lock.notify_all()
        if access not in LEVEL or LEVEL[access] > LEVEL[c["repos"][repo]]:
            raise Refuse(f"access {access} exceeds policy ({c['repos'][repo]}) for {repo}")
        # Mock of the GitHub App key signing the grant: token = HMAC(root_key, nonce).
        nonce = secrets.token_bytes(16)
        token = "ghs_mock_" + hmac.new(self.root_key, nonce, "sha256").hexdigest()[:32]
        return self.track(token, int(time.time()) + int(self.policy["ttl_seconds"]), repo, access,
                          req["client"])

    def track(self, token, exp, repo, access, client):
        with self.lock:
            self.tokens[token] = {"repo": repo, "access": access, "client": client,
                                  "exp": exp, "revoked": False}
        if self.record:
            with open(self.record, "a") as f:
                f.write(token + "\n")
        return {"token": token, "expires_at": exp, "repo": repo, "access": access}

    def kill(self, token, rec):
        """Revoke one tracked token (github: DELETE it). -> bool success."""
        ok = self.gh.delete(token) if self.gh else True
        if ok:
            rec["revoked"] = True
        return ok

    def revoke(self, token, client=None):
        with self.lock:
            rec = self.tokens.get(token)
        if not rec or (client and rec["client"] != client):
            raise Refuse("unknown token")
        if not self.kill(token, rec):
            raise Refuse("revocation failed")
        return {"revoked": 1}

    def shutdown(self):
        """Refuse new mints, let in-flight mints finish (up to 15 s), then revoke everything."""
        with self.lock:
            self.closing = True
            self.lock.wait_for(lambda: self.inflight == 0, timeout=15)
            left = self.inflight
        return {**self.revoke_all(), "inflight_abandoned": left}

    def revoke_all(self, client=None):
        with self.lock:
            todo = [(t, r) for t, r in self.tokens.items()
                    if not r["revoked"] and (client is None or r["client"] == client)]
        n = {"revoked": 0, "failed": 0, "expired_skipped": 0}
        for t, r in todo:
            if r["exp"] <= time.time():
                n["expired_skipped"] += 1
            elif self.kill(t, r):
                n["revoked"] += 1
            else:
                n["failed"] += 1
        return n

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
        n = self.revoke_all(req.get("client"))  # github: DELETEs each tracked token at the API
        return {"revoked": n["revoked"], "failed": n["failed"]}

    def introspect(self, req):
        if self.gh:
            raise Refuse("not applicable: GitHub enforces tokens")
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

    def handle(self, req, uid):
        op = req.get("op")
        if op in ADMIN_OPS:
            self.need_admin(req, uid)
        if op == "token":
            return self.mint(req, uid)
        if op == "revoke_own":
            self.client(req, uid)
            return self.revoke(str(req.get("token")), req["client"])
        if op == "revoke_token":
            return self.revoke(str(req.get("token")))
        if op == "revoke_client":
            return self.revoke_client(req)
        if op == "reinstate_client":
            return self.reinstate_client(req)
        if op == "introspect":
            return self.introspect(req)
        if op == "revoke_all":
            return self.revoke_all()
        raise Refuse("unknown op")


def make_handler(issuer):
    class H(socketserver.StreamRequestHandler):
        def handle(self):
            pid, uid, gid = struct.unpack("3i", self.request.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            self.request.settimeout(5)
            req, resp = {}, {}
            try:
                req = json.loads(self.rfile.readline(65536))
                resp = issuer.handle(req, uid)
            except Refuse as e:
                resp = {"error": str(e)}
            except Exception as e:  # malformed input; never echo the request
                resp = {"error": f"bad request ({type(e).__name__})"}
            tok = resp.get("token") or req.get("token")
            log(backend=issuer.backend, op=req.get("op"), client=req.get("client"),
                repo=req.get("repo"), access=req.get("access"),
                peer={"pid": pid, "uid": uid, "gid": gid},
                token_sha256_8=sha_prefix(tok) if isinstance(tok, str) and tok else None,
                result=resp.get("error") or resp.get("reason") or "ok")
            self.wfile.write((json.dumps(resp) + "\n").encode())
    return H


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def stop(*_):
    raise SystemExit(0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("socket")
    ap.add_argument("--policy", required=True)
    ap.add_argument("--root-key", help="mock backend only")
    ap.add_argument("--admin-secret", required=True)
    ap.add_argument("--state", required=True, help="persisted client revocations (JSON list)")
    ap.add_argument("--backend", default="mock", choices=["mock", "github"])
    ap.add_argument("--socket-mode", default="0600", help="octal; not the access control by itself")
    ap.add_argument("--revoke-on-exit", action=argparse.BooleanOptionalAction, default=None,
                    help="revoke_all on SIGTERM/SIGINT (default: on for github, off for mock)")
    a = ap.parse_args()
    if a.backend == "mock" and not a.root_key:
        ap.error("--root-key is required for the mock backend")
    policy = json.load(open(a.policy))
    root_key = open(a.root_key, "rb").read().strip() if a.root_key else b""
    os.umask(0o177)
    issuer = Issuer(policy, root_key, open(a.admin_secret).read().strip(), a.state, a.backend)
    if os.path.exists(a.socket):
        os.unlink(a.socket)
    srv = Server(a.socket, make_handler(issuer))
    os.chmod(a.socket, int(a.socket_mode, 8))
    revoke_exit = a.backend == "github" if a.revoke_on_exit is None else a.revoke_on_exit
    signal.signal(signal.SIGTERM, stop)
    log(event="listening", backend=a.backend, socket=a.socket, mode=a.socket_mode,
        ttl=policy.get("ttl_seconds"))
    try:
        srv.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        if revoke_exit:
            log(event="revoke_on_exit", **issuer.shutdown())


if __name__ == "__main__":
    main()
