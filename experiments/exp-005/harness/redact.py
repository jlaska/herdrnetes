#!/usr/bin/env python3
"""Redact cluster-identifying details from EXP-005 evidence before committing.

Usage: uv run python harness/redact.py SRC DST [--map PATH]

- Copies every file under SRC into DST with the same relative layout.
- tallon-iv-<name> node hostnames -> stable <node-N> placeholders. The mapping
  is persisted outside the repository (default: scratchpad) so repeated runs
  reuse the same placeholders.
- admin@tallon-iv and bare tallon-iv -> <cluster>.
- https://<host>:6443 API server URLs -> <apiserver>.
- IPv4 (except 127.0.0.1 / 0.0.0.0) -> <ip>; IPv6 -> <ip6>.
- Files containing token / password / PRIVATE KEY lines are NOT copied;
  each offending file:line is reported to stderr.
"""

import argparse
import json
import os
import re
import shutil
import sys
from collections import Counter

DEFAULT_MAP = (
    "/tmp/claude-1000/-home-jlaska-Projects-herdrnetes/"
    "4e33ac86-9385-4fe7-8dc6-2ee8820b89da/scratchpad/redact-map.json"
)

ENC = "utf-8"
ERR = "surrogateescape"

# Hostname: label groups joined by single hyphens; never ends in '-'.
HOST_RE = re.compile(r"\btallon-iv(?:-[a-z0-9]+)+")
CLUSTER_CTX_RE = re.compile(r"admin@tallon-iv")
CLUSTER_BARE_RE = re.compile(r"tallon-iv")
APISERVER_RE = re.compile(
    r"https?://(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):6443"
)
IPV4_RE = re.compile(
    r"(?<![\w.])(?!127\.0\.0\.1(?![\d.]))(?!0\.0\.0\.0(?![\d.]))"
    r"(?:\d{1,3}\.){3}\d{1,3}(?![\w]|\.\d)"
)
# Candidate IPv6: hex groups joined by at least two colons. Accepted only if
# it contains '::' or has >= 3 colons, so timestamps (HH:MM:SS) and digests
# are left alone.
IPV6_CANDIDATE_RE = re.compile(
    r"(?<![0-9A-Fa-f:.])[0-9A-Fa-f]*(?::[0-9A-Fa-f]*){2,7}(?![0-9A-Fa-f:.])"
)
SECRET_RE = re.compile(r"token|password|BEGIN .* PRIVATE KEY", re.IGNORECASE)


def load_map(path):
    if os.path.exists(path):
        with open(path, encoding=ENC) as fh:
            return json.load(fh)
    return {"hosts": {}}


def save_map(path, mapping):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding=ENC) as fh:
        json.dump(mapping, fh, indent=2, sort_keys=True)
        fh.write("\n")


def make_redactor(mapping, counts):
    def host_sub(m):
        name = m.group(0)
        hosts = mapping["hosts"]
        if name not in hosts:
            hosts[name] = f"<node-{len(hosts) + 1}>"
        counts["hostname"] += 1
        return hosts[name]

    def ipv6_sub(m):
        cand = m.group(0)
        if "::" in cand or cand.count(":") >= 3:
            counts["ip6"] += 1
            return "<ip6>"
        return cand

    def ipv4_sub(_m):
        counts["ip"] += 1
        return "<ip>"

    def apiserver_sub(_m):
        counts["apiserver"] += 1
        return "<apiserver>"

    def redact(text):
        # Order matters: API server URLs and cluster context before the
        # generic hostname/IP patterns.
        text = APISERVER_RE.sub(apiserver_sub, text)
        text = CLUSTER_CTX_RE.sub(lambda _m: _count(counts, "cluster", "<cluster>"), text)
        text = HOST_RE.sub(host_sub, text)
        text = CLUSTER_BARE_RE.sub(lambda _m: _count(counts, "cluster", "<cluster>"), text)
        text = IPV4_RE.sub(ipv4_sub, text)
        text = IPV6_CANDIDATE_RE.sub(ipv6_sub, text)
        return text

    return redact


def _count(counts, kind, value):
    counts[kind] += 1
    return value


def find_secret_lines(text):
    hits = []
    for lineno, line in enumerate(text.splitlines(), 1):
        m = SECRET_RE.search(line)
        if m:
            hits.append((lineno, m.group(0).lower()))
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--map", default=DEFAULT_MAP, help="mapping file (outside repo)")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    dst = os.path.abspath(args.dst)
    if not os.path.isdir(src):
        sys.exit(f"source is not a directory: {src}")

    mapping = load_map(args.map)
    counts = Counter()
    redact = make_redactor(mapping, counts)

    copied = []
    skipped = []  # (relpath, reason)
    other = []  # non-regular entries

    for root, dirs, files in os.walk(src):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            if os.path.islink(full) or not os.path.isfile(full):
                other.append(rel)
                continue
            with open(full, "rb") as fh:
                raw = fh.read()
            text = raw.decode(ENC, ERR)

            hits = find_secret_lines(text)
            if hits:
                for lineno, kind in hits:
                    print(f"WARNING: possible secret ({kind}) at {rel}:{lineno}; "
                          f"file NOT copied", file=sys.stderr)
                skipped.append((rel, "secret-like line"))
                continue

            out = redact(text).encode(ENC, ERR)
            target = os.path.join(dst, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as fh:
                fh.write(out)
            shutil.copymode(full, target)
            copied.append(rel)

    save_map(args.map, mapping)

    print(f"Source: {src}")
    print(f"Destination: {dst}")
    print(f"Files copied: {len(copied)}")
    for rel in copied:
        print(f"  {rel}")
    print("Substitutions:")
    for kind in ("hostname", "cluster", "apiserver", "ip", "ip6"):
        print(f"  {kind}: {counts[kind]}")
    print(f"Placeholders in use: {len(mapping['hosts'])} "
          f"({', '.join(sorted(mapping['hosts'].values()))})")
    print(f"Files skipped: {len(skipped)}")
    for rel, reason in skipped:
        print(f"  {rel} ({reason})")
    if other:
        print(f"Non-regular entries ignored: {len(other)}")
        for rel in other:
            print(f"  {rel}")
    print(f"Mapping file: {args.map}")
    return 1 if skipped else 0


if __name__ == "__main__":
    sys.exit(main())
