"""EXP-008 stage B: one fresh `openshell sandbox connect` under a pty; type one "mark <word>".

usage: python3 -I ackpty.py <word> <timeout-s> <raw-out> -- <connect argv...>

1. Spawn the connect client in its own session on a new pty.
2. Wait until the counter's "tick n=" output is visible (the client reached the canonical PTY).
3. Type "mark <word>" + CR exactly once (no retry).
4. Wait for "ACK <word> pid=... start=... nonce=... n=..." in the ANSI-stripped output; wrapped
   rows are joined before matching.
5. Hang up the client (SIGHUP to its process group, then SIGTERM, then SIGKILL) - an abrupt detach.

Prints "reached_pty=yes|no ack=<ACK line>|none t_tick_s=.. t_ack_s=.." and exits 0 only if the ACK
was seen. The raw pty transcript is written to <raw-out> (kept local; redacted before commit).
"""

import os
import pty
import re
import select
import signal
import sys
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(\x07|\x1b\\)|\x1b[()][0-9A-B]|\x1b[=>]")


def main() -> int:
    word, timeout, raw_path = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    argv = sys.argv[sys.argv.index("--") + 1 :]
    if not re.fullmatch(r"[a-z0-9]{1,12}", word):
        print("bad word", file=sys.stderr)
        return 2
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv)
    t0 = time.monotonic()
    buf = b""
    t_tick = t_ack = None
    sent = False
    sent_at = 0
    ack_re = re.compile(rb"ACK " + word.encode() + rb" pid=(\d+) start=(\d+) nonce=([0-9a-f]{16}) n=(\d+)\n")
    ack = None
    with open(raw_path, "wb") as raw:
        while time.monotonic() - t0 < timeout:
            r, _, _ = select.select([fd], [], [], 0.25)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                raw.write(chunk)
                buf += chunk
            clean = ANSI.sub(b"", buf).replace(b"\r", b"")
            joined = clean.replace(b"\n", b"")
            if t_tick is None and re.search(rb"tick n=\d+", clean):
                t_tick = time.monotonic() - t0
            if t_tick is not None and not sent:
                time.sleep(0.5)
                os.write(fd, b"mark " + word.encode() + b"\r")
                sent = True
                sent_at = len(buf)
            if sent:
                after = ANSI.sub(b"", buf[sent_at:]).replace(b"\r", b"")
                m = ack_re.search(after) or ack_re.search(after.replace(b"\n", b"") + b"\n")
                if m:
                    ack = m.group(0).decode().strip()
                    t_ack = time.monotonic() - t0
                    break
    for sig, wait in ((signal.SIGHUP, 3), (signal.SIGTERM, 3), (signal.SIGKILL, 2)):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            break
        end = time.monotonic() + wait
        while time.monotonic() < end:
            if os.waitpid(pid, os.WNOHANG)[0]:
                end = 0
                break
            time.sleep(0.1)
        if end == 0:
            break
    print(
        f"reached_pty={'yes' if t_tick is not None else 'no'} sent={'yes' if sent else 'no'} "
        f"ack={ack or 'none'} t_tick_s={t_tick if t_tick is None else round(t_tick, 2)} "
        f"t_ack_s={t_ack if t_ack is None else round(t_ack, 2)}"
    )
    return 0 if ack else 1


if __name__ == "__main__":
    sys.exit(main())
