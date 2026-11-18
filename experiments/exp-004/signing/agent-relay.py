#!/usr/bin/env python3
"""Unix-socket proxy for an ssh-agent, with an optional filter policy (EXP-004 S11).

  agent-relay.py --listen RELAY.sock --upstream AGENT.sock [--policy git-sign]

--policy git-sign allows only SSH_AGENTC_REQUEST_IDENTITIES (11) and SSH_AGENTC_SIGN_REQUEST
(13) whose data starts with the SSHSIG magic and namespace "git". Everything else gets
SSH_AGENT_FAILURE (5). Decisions (type, namespace, key fingerprint) go to stderr; signed data
and signatures are never logged. A relay over `kubectl exec` stdio has the same shape (swap the
upstream socket for a subprocess pipe); that variant is not built or tested here.
"""
import argparse, base64, hashlib, os, socket, struct, sys, threading

REQ_IDENTITIES, SIGN_REQUEST, FAILURE = 11, 13, 5
MAX_MSG = 256 * 1024


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError
        buf += c
    return buf


def read_msg(s):
    (n,) = struct.unpack(">I", recv_exact(s, 4))
    if n == 0 or n > MAX_MSG:
        raise ValueError("bad length %d" % n)
    return recv_exact(s, n)


def send_msg(s, body):
    s.sendall(struct.pack(">I", len(body)) + body)


def get_string(b, off):
    (n,) = struct.unpack_from(">I", b, off)
    off += 4
    if off + n > len(b):
        raise ValueError("truncated")
    return b[off:off + n], off + n


def fingerprint(blob):
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def decide(msg, policy):
    """Return (allow, log_line)."""
    t = msg[0]
    if policy is None:
        return True, "type=%d policy=none allow" % t
    if t == REQ_IDENTITIES:
        return True, "type=11 identities allow"
    if t == SIGN_REQUEST:
        try:
            blob, off = get_string(msg, 1)
            data, off = get_string(msg, off)
            fp = fingerprint(blob)
            if not data.startswith(b"SSHSIG"):
                return False, "type=13 key=%s not-sshsig DENY" % fp
            ns, _ = get_string(data, 6)
        except Exception as e:
            return False, "type=13 unparsable (%s) DENY" % e
        if ns != b"git":
            return False, "type=13 key=%s namespace=%s DENY" % (fp, ns.decode("ascii", "replace"))
        return True, "type=13 key=%s namespace=git allow" % fp
    return False, "type=%d unsupported DENY" % t


def serve(conn, upstream, policy):
    up = None
    try:
        up = socket.socket(socket.AF_UNIX)
        up.connect(upstream)
        while True:
            msg = read_msg(conn)
            ok, line = decide(msg, policy)
            print("relay:", line, file=sys.stderr, flush=True)
            if not ok:
                send_msg(conn, bytes([FAILURE]))
                continue
            send_msg(up, msg)
            send_msg(conn, read_msg(up))
    except (EOFError, ConnectionError, ValueError):
        pass
    finally:
        conn.close()
        if up:
            up.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--policy", choices=["git-sign"])
    a = ap.parse_args()
    if os.path.exists(a.listen):
        os.unlink(a.listen)
    srv = socket.socket(socket.AF_UNIX)
    old = os.umask(0o177)
    srv.bind(a.listen)
    os.umask(old)
    srv.listen(8)
    print("relay: listening %s -> %s policy=%s" % (a.listen, a.upstream, a.policy), file=sys.stderr, flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=serve, args=(c, a.upstream, a.policy), daemon=True).start()


if __name__ == "__main__":
    main()
