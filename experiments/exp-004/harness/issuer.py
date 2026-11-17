#!/usr/bin/env python3
"""EXP-004 credential issuer: mints short-lived, repository-scoped mock tokens on a Unix socket.

    issuer.py <socket> --policy policy.json --admin-secret FILE --state FILE
              [--backend mock --root-key FILE | --backend github] [--socket-mode 0600] [--revoke-on-exit]
              [--drain-seconds 45] [--github-timeout 10]

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
tokens outlive a restart, so the github backend, on SIGTERM/SIGINT, refuses new mints, waits up to
--drain-seconds for in-flight mints (a mint finishing while closing kills its own token), then
revokes everything. Exit 0 only if all drained and every DELETE succeeded; otherwise a CRITICAL log
line with a fallback and exit 2. SIGKILL, a crash or power loss skip all of this: minted tokens then
stay valid at GitHub until expiry (<= 1 h). A token GitHub issues after the issuer has exited
cannot be revoked by it.
Client revocations persist in --state, which must pre-exist (owner step: write `[]`, mode 0600),
be a regular file owned by the issuer's euid, not group/world-writable, and hold a JSON list of
strings; otherwise the issuer refuses to start (a missing file must not mean "nothing revoked"). Logs (stderr, JSON) carry peer pid/uid/gid
and a sha256 prefix of the token, never the token or any secret. Mock backend only: if
EXP004_TEST_RECORD_TOKENS=<path> is set, minted tokens are appended there for the leak scan.
github api_url must be https (http only to 127.0.0.1 for the offline fake); redirects are refused.
"""

import argparse
import base64
import concurrent.futures
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
import stat
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
# Keep equivalent to live/redact.sed.
REDACT = [re.compile(r"gh[a-z]_[A-Za-z0-9_.\-]+"), re.compile(r"eyJ[A-Za-z0-9_.\-]+"),
          re.compile(r"[A-Za-z0-9+/=_.\-]{30,}")]
FALLBACK = ("tokens may remain valid at GitHub until expiry (<=1 h); uninstall the GitHub App "
            "installation, then confirm the outstanding token is rejected")
DEL_FAILED = "DELETE FAILED: token remains valid until expiry; uninstall the App installation"
STATE_BROKEN = "revocation state could not be persisted; issuer refuses all mints"
OPENSSL_TIMEOUT = 10


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
                           capture_output=True, check=False, timeout=OPENSSL_TIMEOUT)
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

    def __init__(self, cfg, timeout=10):
        self.timeout = timeout
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
            with OPENER.open(req, timeout=self.timeout) as r:
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
        """-> HTTP status (204 = revoked) or None if unreachable."""
        try:
            status, _ = self.call("DELETE", "/installation/token", token)
        except Refuse:
            status = None
        log(event="github_delete", status=status, token_sha256_8=sha_prefix(token))
        return status


def load_state(path):
    """Revocation state must pre-exist and be trustworthy, else refuse to start (SystemExit)."""
    try:
        st = os.lstat(path)
    except OSError as e:
        raise SystemExit(f"state file {path}: {e.strerror}; initialize it with `[]` (mode 0600)")
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o022:
        raise SystemExit(f"state file {path}: must be a regular file owned by uid {os.geteuid()}, "
                         "not group/world-writable")
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        raise SystemExit(f"state file {path}: not valid JSON; refusing to start")
    if not isinstance(data, list) or not all(isinstance(x, str) for x in data):
        raise SystemExit(f"state file {path}: must be a JSON list of strings; refusing to start")
    return set(data)


class Issuer:
    def __init__(self, policy, root_key, admin_secret, state, backend="mock", gh_timeout=10):
        self.policy, self.root_key, self.admin, self.state = policy, root_key, admin_secret, state
        self.backend = backend
        self.gh = GitHub(policy["github"], gh_timeout) if backend == "github" else None
        self.tokens = {}  # token -> {repo, access, client, exp, revoked}
        self.revoked_clients = load_state(state)  # missing/corrupt/unsafe is fatal (fail closed)
        self.lock = threading.Condition()
        self.closing, self.inflight, self.state_broken = False, 0, False
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
                if self.state_broken:
                    raise Refuse(STATE_BROKEN)
                self.inflight += 1
            try:
                tok, exp, broader = self.gh.mint(repo, perms)
                return self.finish_mint(tok, exp, repo, access, req["client"], broader)
            finally:
                with self.lock:
                    self.inflight -= 1
                    self.lock.notify_all()
        if access not in LEVEL or LEVEL[access] > LEVEL[c["repos"][repo]]:
            raise Refuse(f"access {access} exceeds policy ({c['repos'][repo]}) for {repo}")
        # Mock of the GitHub App key signing the grant: token = HMAC(root_key, nonce).
        nonce = secrets.token_bytes(16)
        token = "ghs_mock_" + hmac.new(self.root_key, nonce, "sha256").hexdigest()[:32]
        return self.finish_mint(token, int(time.time()) + int(self.policy["ttl_seconds"]), repo,
                                access, req["client"])

    def finish_mint(self, token, exp, repo, access, client, broader=False):
        """Track the token and check client/closing/scope in ONE critical section, so a concurrent
        revoke_client or shutdown either sees the token or makes us kill it. Never returns a token
        that fails the check."""
        with self.lock:
            why = ("issuer shutting down" if self.closing else
                   STATE_BROKEN if self.state_broken else
                   "client revoked by administrator" if client in self.revoked_clients else
                   "github returned a token broader than requested or malformed" if broader else None)
            # claimed: one killer per token, so racing revocations never DELETE twice
            rec = self.tokens[token] = {"repo": repo, "access": access, "client": client,
                                        "exp": exp, "revoked": False, "claimed": bool(why)}
            if self.record:
                with open(self.record, "a") as f:
                    f.write(token + "\n")
        if why:  # fail closed: kill it, do not return it
            ok = self.kill(token, rec)
            log(event="late_token_killed", reason=why, killed=ok, token_sha256_8=sha_prefix(token))
            raise Refuse(f"{why}; " + (("DELETEd at GitHub" if self.gh else "revoked") if ok else DEL_FAILED))
        return {"token": token, "expires_at": exp, "repo": repo, "access": access}

    def kill(self, token, rec):
        """Revoke one tracked token the caller has claimed (github: DELETE it). -> bool success.
        204 = revoked. 401 also counts: DELETE authenticates with the token itself, so GitHub
        rejecting it means the token is already unusable. Anything else releases the claim so a
        later revoke_all retries."""
        status = self.gh.delete(token) if self.gh else 204
        with self.lock:
            rec["status"] = status
            rec["revoked"] = status in (204, 401)
            rec["claimed"] = rec["revoked"]
            return rec["revoked"]

    def revoke(self, token, client=None):
        with self.lock:
            rec = self.tokens.get(token)
            if not rec or (client and rec["client"] != client):
                raise Refuse("unknown token")
            if rec["revoked"] or rec["claimed"]:
                return {"revoked": 1, "note": "already revoked or being revoked"}
            rec["claimed"] = True
        if not self.kill(token, rec):
            raise Refuse(f"revocation failed at GitHub (HTTP {rec['status'] or 'unreachable'}); "
                         "token remains valid until expiry")
        return {"revoked": 1}

    def shutdown(self, drain):
        """Refuse new mints, wait up to `drain` s for in-flight mints (each kills its own token
        once closing), then revoke everything. -> (clean, result)."""
        with self.lock:
            self.closing = True
            self.lock.wait_for(lambda: self.inflight == 0, timeout=drain)
            left = self.inflight
        res = {**self.revoke_all(), "inflight_abandoned": left}
        clean = left == 0 and res["failed"] == 0
        if not clean:
            res["ok"], res["fallback"] = False, FALLBACK
            log(level="CRITICAL", event="shutdown_incomplete", **res)
        return clean, res

    def revoke_all(self, client=None):
        with self.lock:
            todo = self.snapshot(client)
        return self.kill_many(todo)  # network calls outside the lock

    def snapshot(self, client=None):
        """Claim the unrevoked, unclaimed tracked tokens (caller holds self.lock)."""
        todo = [(t, r) for t, r in self.tokens.items() if not r["revoked"] and not r["claimed"]
                and (client is None or r["client"] == client)]
        for _, r in todo:
            r["claimed"] = True
        return todo

    def kill_many(self, todo):
        """DELETE in parallel, so shutdown's revocation fits the stop budget whatever the count."""
        n = {"revoked": 0, "failed": 0, "expired_skipped": 0}
        live = []
        for t, r in todo:
            if r["exp"] <= time.time():
                n["expired_skipped"] += 1
                with self.lock:
                    r["claimed"] = False
            else:
                live.append((t, r))
        if live:
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
                for ok in ex.map(lambda tr: self.kill(*tr), live):
                    n["revoked" if ok else "failed"] += 1
        n["ok"] = n["failed"] == 0
        if not n["ok"]:
            n["fallback"] = FALLBACK
        return n

    def save_state(self):
        """Durable atomic replace: 0600 temp in the same dir, fsync, rename, fsync the dir."""
        tmp = self.state + ".tmp"
        if os.path.lexists(tmp):
            os.unlink(tmp)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(sorted(self.revoked_clients), f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.state)
        dfd = os.open(os.path.dirname(os.path.abspath(self.state)), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)

    def reinstate_client(self, req):
        with self.lock:
            self.revoked_clients.discard(str(req.get("client")))
            self.save_state()
        return {"reinstated": 1}

    def revoke_client(self, req):
        client, saved = str(req.get("client")), True
        with self.lock:  # revoke + persist + snapshot atomically vs. finish_mint's check
            self.revoked_clients.add(client)
            try:
                self.save_state()
            except OSError as e:  # revoke in memory, kill tokens, and stop minting for everyone
                saved, self.state_broken = False, True
                log(level="CRITICAL", event="state_save_failed", error=type(e).__name__)
            todo = self.snapshot(client)
        n = self.kill_many(todo)  # github: DELETEs each tracked token at the API
        out = {"revoked": n["revoked"], "failed": n["failed"], "ok": n["ok"] and saved}
        if not saved:
            out["state_saved"] = False
        if not out["ok"]:
            out["fallback"] = FALLBACK + ("" if saved else "; revocation state NOT persisted: the issuer "
                                          "now refuses all mints; fix the state file before any restart")
        return out

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
            try:
                self.wfile.write((json.dumps(resp) + "\n").encode())
            except OSError:  # client gone (e.g. helper timed out): an undelivered token must die
                if resp.get("token"):
                    try:
                        issuer.revoke(resp["token"])
                        killed = True
                    except Refuse:
                        killed = False
                    log(event="undelivered_token_killed", killed=killed,
                        token_sha256_8=sha_prefix(resp["token"]))
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
    # Stop budget: a mint is at most openssl (10 s) + POST + a kill DELETE (github-timeout each), so
    # drain >= 10 + 2 * github-timeout lets every in-flight mint finish and kill its own token. The
    # final revoke_all runs its DELETEs in parallel (one github-timeout). live/issuer-start.sh sets
    # TimeoutStopSec=120 > 45 + 10 so systemd's SIGKILL cannot cut the drain or the revocation short.
    ap.add_argument("--drain-seconds", type=float, default=45,
                    help="max wait for in-flight mints on SIGTERM/SIGINT (default 45)")
    ap.add_argument("--github-timeout", type=float, default=10, help="per GitHub API call, seconds")
    ap.add_argument("--unsafe-short-drain", action="store_true",
                    help="tests only: allow drain-seconds below the mint budget")
    ap.add_argument("--revoke-on-exit", action=argparse.BooleanOptionalAction, default=None,
                    help="revoke_all on SIGTERM/SIGINT (default: on for github, off for mock)")
    a = ap.parse_args()
    budget = OPENSSL_TIMEOUT + 2 * a.github_timeout
    if a.backend == "github" and a.drain_seconds < budget and not a.unsafe_short_drain:
        ap.error(f"--drain-seconds {a.drain_seconds:g} < mint budget {budget:g} "
                 "(openssl + 2 x --github-timeout)")
    if a.backend == "mock" and not a.root_key:
        ap.error("--root-key is required for the mock backend")
    policy = json.load(open(a.policy))
    root_key = open(a.root_key, "rb").read().strip() if a.root_key else b""
    os.umask(0o177)
    issuer = Issuer(policy, root_key, open(a.admin_secret).read().strip(), a.state, a.backend,
                    a.github_timeout)
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
        signal.signal(signal.SIGTERM, signal.SIG_IGN)  # a second signal must not abort the drain
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        clean = True
        if revoke_exit:
            clean, res = issuer.shutdown(a.drain_seconds)
            log(event="revoke_on_exit", **res)
    sys.exit(0 if clean else 2)


if __name__ == "__main__":
    main()
