#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""EXP-003 path B: a local Unix socket that carries Herdr's UI client stream into the pod.

    CTX=<context> bridge.py <local-socket-path>

Each accepted connection spawns `kubectl exec -i herdr-0 -- herdr remote-client-bridge` and
pumps bytes both ways (what `ssh -T host herdr remote-client-bridge` does for `herdr --remote`).
`remote-client-bridge` STARTS a server if none is listening on the client socket, so before
listening, and again before every connection, this runs `herdr status server --json` in the
target and refuses unless running and endpoint_compatible. It never stops or restarts anything.

Environment (the defaults are the cluster; override all three to test against a local server):
  CTX, NS (herdrnetes-exp), POD (herdr-0)   used only to build the default BRIDGE_EXEC
  BRIDGE_EXEC    command prefix that reaches the target; empty string = run locally
                 (default: kubectl --context $CTX -n $NS exec -i $POD -c herdr --)
  BRIDGE_CMD     remote bridge command (default: herdr remote-client-bridge)
  BRIDGE_STATUS  remote status command (default: herdr status server --json)

Keep the socket path short: sun_path holds about 107 bytes ($XDG_RUNTIME_DIR is a good home).
Connect/disconnect events go to stderr with UTC timestamps. The socket is owner-only (0600).
"""

import json
import os
import shlex
import signal
import socket
import subprocess
import sys
import threading
from datetime import datetime, timezone

MAX_PATH = 100


def log(msg):
    ts = datetime.now(timezone.utc).strftime("%FT%T.%f")[:-3] + "Z"
    print(f"{ts} bridge: {msg}", file=sys.stderr, flush=True)


def config():
    ex = os.environ.get("BRIDGE_EXEC")
    if ex is None:
        ctx = os.environ.get("CTX")
        if not ctx:
            sys.exit("set CTX (kubectl context) or BRIDGE_EXEC")
        ex = (
            f"kubectl --context {shlex.quote(ctx)} -n {os.environ.get('NS', 'herdrnetes-exp')}"
            f" exec -i {os.environ.get('POD', 'herdr-0')} -c herdr --"
        )
    prefix = shlex.split(ex)
    bridge = prefix + shlex.split(os.environ.get("BRIDGE_CMD", "herdr remote-client-bridge"))
    status = prefix + shlex.split(os.environ.get("BRIDGE_STATUS", "herdr status server --json"))
    # `kubectl exec -i` on the status probe must not read our stdin.
    return bridge, status


def server_ok(status_cmd):
    """True only if the target's Herdr server is up and speaks our endpoint generation."""
    try:
        r = subprocess.run(status_cmd, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
        st = json.loads(r.stdout)
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        log(f"status probe failed: {e}")
        return False
    ok = st.get("running") is True and st.get("endpoint_compatible") is True
    if not ok:
        log(f"refusing: server not usable (running={st.get('running')} endpoint_compatible={st.get('endpoint_compatible')})")
    return ok


def stop_child(p):
    # Closing stdin first lets a healthy bridge exit by itself; then escalate.
    for step in (lambda: p.stdin.close(), p.terminate, p.kill):
        try:
            step()
            p.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            continue
        except OSError:
            continue


def serve(conn, n, bridge_cmd, status_cmd):
    if not server_ok(status_cmd):
        conn.close()
        return
    p = subprocess.Popen(bridge_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    log(f"conn {n} connected; child pid {p.pid}")
    done = threading.Event()

    def up():  # client -> child
        try:
            while data := conn.recv(65536):
                p.stdin.write(data)
                p.stdin.flush()
        except OSError:
            pass
        done.set()

    def down():  # child -> client
        try:
            while data := os.read(p.stdout.fileno(), 65536):
                conn.sendall(data)
        except OSError:
            pass
        done.set()

    threading.Thread(target=up, daemon=True).start()
    threading.Thread(target=down, daemon=True).start()
    done.wait()
    who = "child exited" if p.poll() is not None else "client closed"
    try:
        conn.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    conn.close()
    stop_child(p)
    log(f"conn {n} disconnected ({who}); child exit {p.returncode}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    if len(path.encode()) > MAX_PATH:
        sys.exit(f"socket path too long ({len(path.encode())} > {MAX_PATH}); use a shorter one")
    bridge_cmd, status_cmd = config()
    if not server_ok(status_cmd):
        sys.exit("target Herdr server is not running and compatible; not listening")
    if os.path.exists(path):
        probe = socket.socket(socket.AF_UNIX)
        try:
            probe.connect(path)
            sys.exit(f"{path} is a live socket; refusing to replace it")
        except ConnectionRefusedError:
            os.unlink(path)  # stale socket from a dead bridge
        except OSError as e:
            sys.exit(f"{path} exists and is not a stale socket: {e}")
        finally:
            probe.close()
    old = os.umask(0o177)
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(path)
    os.umask(old)
    os.chmod(path, 0o600)
    srv.listen(8)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log(f"listening on {path}")
    n = 0
    try:
        while True:
            conn, _ = srv.accept()
            n += 1
            threading.Thread(target=serve, args=(conn, n, bridge_cmd, status_cmd), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()
        try:
            os.unlink(path)
        except OSError:
            pass
        log("stopped; socket removed")


if __name__ == "__main__":
    main()
