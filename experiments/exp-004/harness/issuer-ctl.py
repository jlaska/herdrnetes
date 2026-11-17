#!/usr/bin/env python3
"""EXP-004 issuer admin CLI.

    issuer-ctl.py <socket> --admin-secret FILE <op> [--client X] [--token-stdin]

ops: revoke_all | revoke_client | reinstate_client | revoke_token (token read from stdin, never argv).
Prints the issuer's JSON reply. The caller's uid must be in the issuer policy's admin_uids.
Exit 0 only if the reply has no "error" and is not "ok": false; otherwise exit 1, and for an
incomplete revocation print a REVOCATION INCOMPLETE line (with the fallback) to stderr.
"""

import argparse
import json
import socket
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("socket")
    ap.add_argument("--admin-secret", required=True)
    ap.add_argument("op", choices=["revoke_all", "revoke_client", "reinstate_client", "revoke_token"])
    ap.add_argument("--client")
    ap.add_argument("--token-stdin", action="store_true")
    a = ap.parse_args()
    req = {"op": a.op, "admin": open(a.admin_secret).read().strip()}
    if a.client:
        req["client"] = a.client
    if a.token_stdin:
        req["token"] = sys.stdin.readline().strip()
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(30)
        s.connect(a.socket)
        s.sendall((json.dumps(req) + "\n").encode())
        line = s.makefile().readline().strip()
    print(line)
    try:
        reply = json.loads(line)
    except ValueError:
        reply = {"error": "unparseable reply"}
    if "error" in reply or reply.get("ok") is False:
        if reply.get("ok") is False:
            print("REVOCATION INCOMPLETE: " + str(reply.get("fallback", "tokens may remain valid")),
                  file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
