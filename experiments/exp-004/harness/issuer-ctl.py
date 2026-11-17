#!/usr/bin/env python3
"""EXP-004 issuer admin CLI.

    issuer-ctl.py <socket> --admin-secret FILE <op> [--client X] [--token-stdin]

ops: revoke_all | revoke_client | reinstate_client | revoke_token (token read from stdin, never argv).
Prints the issuer's JSON reply. The caller's uid must be in the issuer policy's admin_uids.
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
        print(s.makefile().readline().strip())


if __name__ == "__main__":
    main()
