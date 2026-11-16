#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""EXP-002 recovery identity checks on `herdr api snapshot` output.

Compares stable identities, not counts: workspace and tab labels in order,
each pane by position key (workspace/tab-index:tab-label/pane-index) with its
label and cwd, `restore_error` panes, and the `snapshot.agents` collection by
pane key with the agent name and its session reference (compared, never printed).

recovery.py match <expected-snapshot.json> [<actual-snapshot.json>]   # actual on stdin if omitted
    prints: <layout_ok 0|1> <agent_ok 0|1> <agent pane id or -> <restore_error count>
recovery.py report <expected-snapshot.json> <actual-snapshot.json>    # JSON detail
recovery.py audit <run-dir> <reference-label> [<pane-key>=<cwd> ...]
    offline: every after-*/ probe against a reference probe; <pane-key>=<cwd>
    records a deliberate change made after the reference (e.g. the C2 `cd`)
"""

import json
import sys
from pathlib import Path

# Importing compare.py must not leave __pycache__ in the repository.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "exp-001"))
from compare import ordered_panes, snapshot


def load(src):
    text = src.read() if hasattr(src, "read") else Path(src).read_text()
    try:
        return snapshot(json.loads(text))
    except (ValueError, KeyError, AttributeError):
        return None


def identity(snap):
    tabs = {}
    for t in snap["tabs"]:
        tabs.setdefault(t["workspace_id"], []).append(t)
    workspaces = [
        (
            w["label"],
            [
                t["label"]
                for t in sorted(
                    tabs.get(w["workspace_id"], []), key=lambda t: t["number"]
                )
            ],
        )
        for w in sorted(snap["workspaces"], key=lambda w: w["number"])
    ]
    panes, key_of = {}, {}
    for wl, tl, ti, pi, p in ordered_panes(snap):
        key = f"{wl}/{ti}:{tl}/{pi}"
        key_of[p["pane_id"]] = key
        panes[key] = {
            "pane_id": p["pane_id"],
            "label": p.get("label") or "",
            "cwd": p.get("cwd", ""),
            "restore_error": bool(p.get("restore_error")),
        }
    agents = {
        key_of.get(a.get("pane_id"), a.get("pane_id")): {
            "pane_id": a.get("pane_id"),
            "agent": a.get("agent"),
            "session": a.get("agent_session"),
        }
        for a in snap.get("agents", [])
    }
    return {"workspaces": workspaces, "panes": panes, "agents": agents}


def compare(expected, actual):
    e, a = identity(expected), identity(actual) if actual else None
    if a is None:
        return {
            "layout_ok": False,
            "agent_ok": False,
            "diffs": ["no snapshot"],
            "restore_errors": [],
            "agent_pane": None,
        }
    diffs = []
    if e["workspaces"] != a["workspaces"]:
        diffs.append(f"workspaces/tabs {e['workspaces']} -> {a['workspaces']}")
    for key in sorted(set(e["panes"]) | set(a["panes"])):
        pe, pa = e["panes"].get(key), a["panes"].get(key)
        if not pa or not pe:
            diffs.append(f"pane {key} {'missing' if not pa else 'new'}")
            continue
        for f in ("label", "cwd"):
            if pe[f] != pa[f]:
                diffs.append(f"pane {key} {f} {pe[f]!r} -> {pa[f]!r}")
    agent_diffs, agent_pane = [], None
    for key, ae in e["agents"].items():
        aa = a["agents"].get(key)
        if not aa:
            agent_diffs.append(f"agent {ae['agent']} at {key} missing")
            continue
        agent_pane = aa["pane_id"]
        if aa["agent"] != ae["agent"]:
            agent_diffs.append(f"agent at {key} {ae['agent']} -> {aa['agent']}")
        if ae["session"] and aa["session"] != ae["session"]:
            agent_diffs.append(f"agent at {key} session reference changed")
    return {
        "layout_ok": not diffs,
        "agent_ok": bool(e["agents"]) and not agent_diffs,
        "expected_agents": len(e["agents"]),
        "agent_pane": agent_pane,
        "restore_errors": [k for k, p in a["panes"].items() if p["restore_error"]],
        "diffs": diffs + agent_diffs,
    }


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd in ("match", "report"):
        expected = load(args[0])
        actual = load(args[1] if len(args) > 1 else sys.stdin)
        r = compare(expected, actual)
        if cmd == "report":
            print(json.dumps(r, indent=1))
        else:
            print(
                int(r["layout_ok"]),
                int(r["agent_ok"]),
                r["agent_pane"] or "-",
                len(r["restore_errors"]),
            )
    elif cmd == "audit":
        run, ref = Path(args[0]), args[1]
        expected = load(run / ref / "api-snapshot.json")
        overrides = dict(a.split("=", 1) for a in args[2:])
        key_of = {
            f"{wl}/{ti}:{tl}/{pi}": p for wl, tl, ti, pi, p in ordered_panes(expected)
        }
        for key, cwd in overrides.items():
            key_of[key]["cwd"] = cwd
        print(
            "| probe | Herdr | layout identity | agent + session ref | `claude --resume` in pane | restore_error panes | differences |"
        )
        print("| --- | --- | --- | --- | --- | --- | --- |")
        for d in sorted(run.glob("after-*/api-snapshot.json")):
            actual = load(d)
            r = compare(expected, actual)
            probes = d.parent / "pane-probes.txt"
            fg = "?"
            if probes.exists() and r["agent_pane"]:
                lines = probes.read_text().splitlines()
                try:
                    i = lines.index(f"### {r['agent_pane']}")
                    fg = (
                        "yes"
                        if lines[i + 1].startswith("fg: claude --resume ")
                        else "no"
                    )
                except (ValueError, IndexError):
                    fg = "no"
            elif r["expected_agents"]:
                fg = "no"
            print(
                f"| {d.parent.name} | {(actual or {}).get('version', '?')} | {'match' if r['layout_ok'] else 'DIFF'} | "
                f"{'match' if r['agent_ok'] else 'DIFF'} | {fg} | {len(r['restore_errors'])} | "
                f"{'; '.join(r['diffs']) or '–'} |"
            )
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
