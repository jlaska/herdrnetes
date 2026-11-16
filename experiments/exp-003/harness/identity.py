#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""EXP-003 identity records: what must be identical before and after a client test.

identity.py build <dir>   > identity.json   # <dir> is the raw capture made by lib.sh `identity`
identity.py diff <a.json> <b.json>          # UNCHANGED/CHANGED per field; exit 1 if the server
                                            # or any pre-existing pane shell was replaced

Fatal (exit 1): pod UID, server PID or start time, a pane shell PID that changed or whose pane
disappeared. Everything else (restart count, image ID, foreground commands, agents, counts) is
reported but informational. Agent session references are hashed here and never printed, and
UUIDs in pane command lines (e.g. `claude --resume <id>`) are replaced by their hash.
"""

import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def redact(cmdline):
    if not cmdline:
        return cmdline
    return UUID.sub(lambda m: "<sha256:" + hashlib.sha256(m[0].encode()).hexdigest()[:12] + ">", cmdline)


def load(p):
    return json.loads(Path(p).read_text())


def result(doc):
    return doc.get("result", doc)


def build(d):
    d = Path(d)
    pod = load(d / "pod.json")
    status = load(d / "status.json")
    snap = result(load(d / "snapshot.json"))["snapshot"]
    agents = snap.get("agents", [])  # same shape exp-002 recovery.py reads
    pid, stat, btime, clk = (d / "server.txt").read_text().split("\n")[:4]
    # /proc/<pid>/stat: field 22 (starttime, clock ticks since boot) follows the ")" that closes comm.
    ticks = int(stat.rsplit(")", 1)[1].split()[19])
    started = datetime.fromtimestamp(int(btime) + ticks / int(clk), timezone.utc).strftime("%FT%TZ")
    panes = {}
    for p in sorted(snap["panes"], key=lambda p: p["pane_id"]):
        f = d / ("proc-" + p["pane_id"].replace(":", "_") + ".json")
        info = result(load(f)).get("process_info") if f.exists() and f.stat().st_size else None
        info = info or {}
        panes[p["pane_id"]] = {
            "shell_pid": info.get("shell_pid"),
            "foreground": [redact(x.get("cmdline")) for x in info.get("foreground_processes") or []],
        }
    ag = [
        {
            "pane_id": a.get("pane_id"),
            "agent": a.get("agent"),
            "status": a.get("agent_status") or a.get("status"),
            "session_sha256_12": hashlib.sha256(str(a["agent_session"]).encode()).hexdigest()[:12]
            if a.get("agent_session")
            else None,
        }
        for a in agents
    ]
    return {
        "pod": {k: pod.get(k) for k in ("uid", "imageID", "restartCount")},
        "server": {
            "pid": int(pid),
            "start_ticks": ticks,
            "started_at": started,
            "version": status.get("version"),
            "protocol": status.get("protocol"),
        },
        "counts": {
            "workspaces": len(snap["workspaces"]),
            "tabs": len(snap["tabs"]),
            "panes": len(snap["panes"]),
        },
        "workspace_labels": sorted(w["label"] for w in snap["workspaces"]),
        "panes": panes,
        "agents": ag,
        "client_version": (d / "client-version.txt").read_text().strip(),
    }


def diff(a, b):
    fatal = []
    rows = []

    def row(name, x, y, is_fatal=False):
        same = x == y
        rows.append(f"{'UNCHANGED' if same else 'CHANGED  '} {name}: {x if same else f'{x} -> {y}'}")
        if is_fatal and not same:
            fatal.append(name)

    row("pod.uid", a["pod"]["uid"], b["pod"]["uid"], True)
    row("pod.imageID", a["pod"]["imageID"], b["pod"]["imageID"])
    row("pod.restartCount", a["pod"]["restartCount"], b["pod"]["restartCount"])
    row("server.pid", a["server"]["pid"], b["server"]["pid"], True)
    row("server.start_ticks", a["server"]["start_ticks"], b["server"]["start_ticks"], True)
    row("server.started_at", a["server"]["started_at"], b["server"]["started_at"])
    row("counts", a["counts"], b["counts"])
    row("agents", a["agents"], b["agents"])
    row("client_version", a["client_version"], b["client_version"])
    for pid, pa in a["panes"].items():
        pb = b["panes"].get(pid)
        if pb is None:
            rows.append(f"CHANGED   pane {pid}: MISSING after")
            fatal.append(f"pane {pid} missing")
            continue
        row(f"pane {pid} shell_pid", pa["shell_pid"], pb["shell_pid"], True)
        row(f"pane {pid} foreground", pa["foreground"], pb["foreground"])
    for pid in b["panes"].keys() - a["panes"].keys():
        rows.append(f"NEW       pane {pid}: shell_pid {b['panes'][pid]['shell_pid']}")
    print("\n".join(rows))
    if fatal:
        print("FATAL: " + "; ".join(fatal), file=sys.stderr)
        return 1
    print("OK: server and pre-existing pane shells are the same processes")
    return 0


def main():
    cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("", [])
    if cmd == "build" and len(args) == 1:
        print(json.dumps(build(args[0]), indent=1))
    elif cmd == "diff" and len(args) == 2:
        sys.exit(diff(load(args[0]), load(args[1])))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
