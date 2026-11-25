#!/usr/bin/env bash
# EXP-008 Stage C: copy DERIVED evidence of one run into the repository and redact it; then scan.
#   export.sh <RUN> <dest-dir>      (dest is normally experiments/exp-008/stage-c/evidence/<RUN>)
#   export.sh --scan <path>...      (scan only; exit 1 on any hit)
# Only allowlisted file kinds are copied. Transcripts, screen captures, PTY logs, container/gateway logs,
# task-log copies, the codeword and probe tokens live in $HX/run/<RUN>/raw and are NEVER copied.
# Node names become node-a/node-b/..., site names (site.env values and $HX/redact.txt lines) become
# <redacted>, pod IPs are removed. The scan then refuses: key shapes, OpenShell placeholders, JWT shapes,
# private IPv4 addresses, site names, the codeword/probe tokens, and transcript-shaped JSON.
set -euo pipefail
HX=$HOME/.cache/hxc
site_literals() { # site-specific names that must never be committed (values only, >= 4 chars)
  if [ -r "$HX/site.env" ]; then sed -n 's/^[A-Z_]*=//p' "$HX/site.env" | tr -d "\"'" | grep -E '.{4,}' | grep -v -E '^[0-9.]+$|^exp008c-' || true; fi
  if [ -r "$HX/redact.txt" ]; then grep -E '.{4,}' "$HX/redact.txt" || true; fi
}
scan() {
  local pat=() f hits=0
  pat+=(-e 'sk-ant-' -e 'openshell:resolve' -e 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    -e '\b(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}\b'
    -e '"type": ?"(assistant|api-request-blob|api-request-shape)"' -e '"tool_use_id"' -e 'BEGIN [A-Z ]*PRIVATE KEY')
  local lit; lit=$(mktemp); trap 'rm -f "$lit"' RETURN
  { site_literals; for r in "$HX"/run/*/raw; do cat "$r/codeword" "$r"/*-probe 2>/dev/null || true; done; } | sort -u >"$lit"
  for f in "$@"; do
    if grep -r -n -I -E "${pat[@]}" "$f"; then hits=1; fi
    if [ -s "$lit" ] && grep -r -n -I -F -f "$lit" "$f"; then hits=1; fi
  done
  [ "$hits" = 0 ] && echo "scan: clean ($*)" || { echo "scan: HITS - do not commit" >&2; return 1; }
}
if [ "${1:-}" = --scan ]; then shift; scan "$@"; exit; fi
RUN=$1 DEST=$2
[[ $RUN =~ ^[0-9]{4}-[0-9]{4}$ ]] || { echo "bad RUN" >&2; exit 2; }
E=$HX/run/$RUN/e
[ -d "$E" ] || { echo "no evidence at $E" >&2; exit 2; }
[ ! -e "$DEST" ] || { echo "$DEST exists; refusing to overwrite evidence" >&2; exit 2; }
mkdir -p "$DEST"
( cd "$E" && find . -type f \( \
    -path './timeline.log' -o -path './STOPPED' -o -path './done-*' \
    -o -path './obs/*-result.txt' -o -path './obs/*-times.txt' -o -path './obs/*-summary.txt' -o -path './obs/*-clock.txt' \
    -o -path './obs/*-R.txt' -o -path './obs/*-S.txt' -o -path './obs/*-X4.txt' -o -path './obs/*-X5*.txt' -o -path './obs/*-gate.txt' \
    -o -path './obs/term-*' -o -path './obs/*-t0' -o -path './obs/*-t-*' -o -path './obs/*-done' -o -path './obs/M_s' \
    -o -path './obs/c0-pkg.txt' -o -path './obs/c0-ready-ms' -o -path './obs/*-token.txt' -o -path './obs/spend.txt' \
    -o -path './obs/*-C-pods.json' -o -path './obs/*-C-cr.json' -o -path './obs/*-P.txt' -o -path './obs/*-T.txt' \
    -o -path './metrics/*.json' -o -path './term/*.json' \
    -o -path './samples/pods-watch.jsonl' -o -path './samples/cr-watch.jsonl' -o -path './samples/events-watch.jsonl' \
    -o -path './samples/pods-1hz.txt' -o -path './samples/sandbox-get-1hz.txt' -o -path './samples/P-5s.txt' -o -path './samples/T-10s.txt' \
    -o -path './samples/x-*.json' -o -path './samples/x-captured.txt' \
    -o -path './inv/diff-*' -o -path './inv/unexpected-diffs.txt' -o -path './inv/restoration.txt' -o -path './obs/cleanup-*.txt' \
    -o -path './obs/*-t' -o -path './obs/*-probe-t' -o -path './obs/c0-create.err' -o -path './obs/cleanup-delete.err' \
    -o -path './obs/argo-changed-*.txt' -o -path './obs/*-S.txt' -o -path './obs/*-G-gwpod.txt' \
  \) -print0 | xargs -0 -I{} cp --parents {} "$DEST/" )
# X2/T files carry the last task-log line (timestamps, step numbers, ppid/pcmd hashes): allowed.
# node names -> node-a..., pod IPs dropped
nodes=$( { cat "$E"/obs/*-C-pods.json "$E"/samples/*.jsonl 2>/dev/null | grep -o -E '"(node|nodeName)": ?"[^"]+"' | sed -E 's/.*: ?"([^"]+)"/\1/'
  cat "$E"/obs/*-G-gwpod.txt 2>/dev/null | awk 'NF >= 2 {print $2}'; } | grep -E '^[A-Za-z0-9.-]{2,}$' | sort -u)
i=0; for n in $nodes; do lbl=node-$(printf "\\x$(printf %x $((97 + i)))"); grep -r -l -F "$n" "$DEST" | xargs -r sed -i "s/$n/$lbl/g"; i=$((i + 1)); done
grep -r -l -E '"(podIP|hostIP)"' "$DEST" | xargs -r sed -i -E 's/"(podIP|hostIP)": ?"[^"]*"/"\1": "<redacted>"/g'
site_literals | sort -u | while read -r s; do
  grep -r -l -F "$s" "$DEST" | xargs -r sed -i "s|$(printf %s "$s" | sed 's/[|&\\]/\\&/g')|<redacted>|g"
done
echo "exported $(find "$DEST" -type f | wc -l) files to $DEST"
scan "$DEST" || { rm -rf "$DEST"; echo "export removed: scan failed (fix the redaction, then export again)" >&2; exit 1; }
