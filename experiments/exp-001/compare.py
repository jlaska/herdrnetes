#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""EXP-001 helpers for Herdr CLI JSON (v0.9.5 `herdr api snapshot` shape).

  compare.py pane-id <workspace-label> <tab-index> <pane-index>   < snapshot
  compare.py field <dotted.path>                                   < any result
  compare.py panes                                                 < snapshot
  compare.py procs                                                 < process-info
  compare.py diff <evidence-dir-before> <evidence-dir-after>
  compare.py session <session.json>      # layout + agent refs, ids redacted
"""
import json
import sys
from pathlib import Path


def result(doc):
    return doc.get("result", doc)


def snapshot(doc):
    r = result(doc)
    return r.get("snapshot", r)


def ordered_panes(snap):
    """Yield (workspace label, tab index, pane index, pane) in UI order."""
    tabs_by_ws = {}
    for t in snap["tabs"]:
        tabs_by_ws.setdefault(t["workspace_id"], []).append(t)
    layouts = {l["tab_id"]: l for l in snap["layouts"]}
    panes = {p["pane_id"]: p for p in snap["panes"]}
    for ws in sorted(snap["workspaces"], key=lambda w: w["number"]):
        for ti, tab in enumerate(sorted(tabs_by_ws.get(ws["workspace_id"], []), key=lambda t: t["number"])):
            order = [p["pane_id"] for p in sorted(layouts[tab["tab_id"]]["panes"],
                                                  key=lambda p: (p["rect"]["y"], p["rect"]["x"]))]
            for pi, pid in enumerate(order):
                yield ws["label"], tab["label"], ti, pi, panes[pid]


def pane_rows(snap):
    agents = {a.get("pane_id"): a for a in snap.get("agents", [])}
    for wl, tl, ti, pi, p in ordered_panes(snap):
        a = agents.get(p["pane_id"], {})
        yield {
            "pane_id": p["pane_id"],
            "key": f"{wl}/{ti}:{tl}/{pi}",
            "label": p.get("label") or p.get("name") or "",
            "cwd": p.get("cwd", ""),
            "agent": a.get("agent") or p.get("agent") or "",
            "agent_status": p.get("agent_status", ""),
        }


def get_path(doc, path):
    cur = result(doc)
    for part in path.split("."):
        cur = cur[part]
    return cur


def load_tsv(path):
    lines = Path(path).read_text().splitlines()
    head = lines[0].split("\t")
    return {r["key"]: r for r in (dict(zip(head, l.split("\t"))) for l in lines[1:])}


def parse_probes(path):
    out, cur = {}, None
    p = Path(path)
    if not p.exists():
        return out
    for line in p.read_text().splitlines():
        if line.startswith("### "):
            cur = line[4:]
            out[cur] = []
        elif cur:
            out[cur].append(line)
    return out


def diff(before, after):
    b, a = Path(before), Path(after)
    tb, ta = load_tsv(b / "panes.tsv"), load_tsv(a / "panes.tsv")
    pb, pa = parse_probes(b / "pane-probes.txt"), parse_probes(a / "pane-probes.txt")
    print("| pane | cwd before → after | label | foreground before → after | MARK on screen after |")
    print("| --- | --- | --- | --- | --- |")
    for key in sorted(set(tb) | set(ta)):
        rb, ra = tb.get(key), ta.get(key)
        if not ra:
            print(f"| {key} | {rb['cwd']} → **missing** | | | |")
            continue
        if not rb:
            print(f"| {key} | (new) → {ra['cwd']} | | | |")
            continue
        def fg(probes, row):
            lines = probes.get(row["pane_id"], [])
            return next((l[4:] for l in lines if l.startswith("fg: ")), "?")
        def mark(probes, row):
            return "yes" if any("MARK-" in l for l in probes.get(row["pane_id"], [])) else "no"
        cwd = rb["cwd"] if rb["cwd"] == ra["cwd"] else f"{rb['cwd']} → **{ra['cwd']}**"
        lab = rb["label"] if rb["label"] == ra["label"] else f"{rb['label']} → **{ra['label']}**"
        print(f"| {key} | {cwd} | {lab} | {fg(pb, rb)} → {fg(pa, ra)} | {mark(pa, ra)} |")
    for name in ("git-status.txt", "history-mark-count.txt"):
        sb = (b / name).read_text().strip() if (b / name).exists() else ""
        sa = (a / name).read_text().strip() if (a / name).exists() else ""
        print(f"\n{name}: {'unchanged' if sb == sa else 'CHANGED'}\n  before: {sb!r}\n  after:  {sa!r}")


def redact(value):
    return f"<{len(value)}-char id>" if isinstance(value, str) else value


def session_summary(path):
    s = json.loads(Path(path).read_text())
    print(f"version={s.get('version')} workspaces={len(s['workspaces'])}")

    def walk(node, depth):
        if not isinstance(node, dict):
            return
        if "Pane" in node or node.get("type") == "pane":
            print("    " * depth + json.dumps(node)[:200])
        for v in node.values():
            if isinstance(v, dict):
                walk(v, depth + 1)
            elif isinstance(v, list):
                for x in v:
                    walk(x, depth + 1)

    for ws in s["workspaces"]:
        print(f"- workspace custom_name={ws.get('custom_name')!r} tabs={len(ws.get('tabs', []))}")
        for pane in ws.get("panes", {}).values() if isinstance(ws.get("panes"), dict) else ws.get("panes", []):
            ref = {k: (redact(v) if "id" in k or "path" in k else v)
                   for k, v in (pane.get("agent_session") or {}).items()} if isinstance(pane, dict) else None
            print(f"    pane cwd={pane.get('cwd')!r} agent_session={ref} keys={sorted(pane)}")


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "pane-id":
        wl, ti, pi = args[0], int(args[1]), int(args[2])
        for w, _, t, p, pane in ordered_panes(snapshot(json.load(sys.stdin))):
            if (w, t, p) == (wl, ti, pi):
                print(pane["pane_id"])
                return
        sys.exit(f"no pane {wl}/{ti}/{pi}")
    elif cmd == "field":
        print(get_path(json.load(sys.stdin), args[0]))
    elif cmd == "panes":
        rows = list(pane_rows(snapshot(json.load(sys.stdin))))
        cols = ["pane_id", "key", "label", "cwd", "agent", "agent_status"]
        print("\t".join(cols))
        for r in rows:
            print("\t".join(str(r[c]) for c in cols))
    elif cmd == "procs":
        info = result(json.load(sys.stdin)).get("process_info", {})
        fg = info.get("foreground_processes") or []
        print("fg: " + " | ".join(p.get("cmdline", "?") for p in fg))
        print(f"shell_pid: {info.get('shell_pid')}")
    elif cmd == "diff":
        diff(args[0], args[1])
    elif cmd == "session":
        session_summary(args[0])
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
