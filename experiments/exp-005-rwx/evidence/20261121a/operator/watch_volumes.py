#!/usr/bin/env python3
"""Read-only D-A watcher (operator-side, NOT part of the pinned harness).

Polls `kubectl get volumes.longhorn.io` every INTERVAL s. Baseline = first successful read.
Prints one line per poll; lines starting with ALERT are D-A violations:
  - inventory unreadable / empty
  - any volume degraded or faulted
  - any baseline volume whose (state, robustness) changed
  - any non-baseline volume beyond the single expected scratch volume, or a scratch volume that is degraded/faulted
Volume names are hashed in output (public-repo hygiene).
"""
import hashlib
import json
import subprocess
import sys
import time

CTX = sys.argv[1]
INTERVAL = int(sys.argv[2]) if len(sys.argv) > 2 else 30


def h(name):
    return hashlib.sha256(name.encode()).hexdigest()[:10]


def read():
    try:
        p = subprocess.run(["kubectl", "--context", CTX, "-n", "longhorn-system", "get", "volumes.longhorn.io", "-o", "json",
                            "--request-timeout=20s"], capture_output=True, text=True, timeout=40)
        if p.returncode != 0:
            return None, f"rc={p.returncode} {p.stderr.strip()[:200]}"
        items = json.loads(p.stdout)["items"]
        if not items:
            return None, "empty inventory"
        return {i["metadata"]["name"]: ((i.get("status") or {}).get("state", ""), (i.get("status") or {}).get("robustness", ""))
                for i in items}, None
    except Exception as e:  # noqa: BLE001
        return None, f"{type(e).__name__}: {e}"


base = None
while True:
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    now, err = read()
    if now is None:
        print(f"{ts} ALERT inventory unreadable: {err}", flush=True)
        time.sleep(INTERVAL)
        continue
    if base is None:
        base = now
        c = {}
        for v in base.values():
            c[v] = c.get(v, 0) + 1
        print(f"{ts} BASELINE total={len(base)} {sorted(c.items())}", flush=True)
    alerts, infos = [], []
    for n, (st, rob) in now.items():
        if rob in ("degraded", "faulted"):
            alerts.append(f"{h(n)} {st}/{rob}")
        if n in base:
            if base[n] != (st, rob):
                alerts.append(f"{h(n)} changed {base[n][0]}/{base[n][1]} -> {st}/{rob}")
        else:
            infos.append(f"new {h(n)} {st}/{rob}")
    if len([n for n in now if n not in base]) > 1:
        alerts.append("more than one non-baseline volume")
    for n in base:
        if n not in now:
            alerts.append(f"{h(n)} vanished")
    tag = "ALERT" if alerts else "OK"
    print(f"{ts} {tag} total={len(now)} alerts={alerts} info={infos}", flush=True)
    time.sleep(INTERVAL)
