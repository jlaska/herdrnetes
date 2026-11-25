#!/usr/bin/env bash
# EXP-008 Stage C: copy DERIVED evidence of one run into the repository and redact it; then scan.
#   export.sh <RUN> <dest-dir>      (dest is normally experiments/exp-008/stage-c/evidence/<RUN>)
#   export.sh --scan <path>...      (scan only; exit 1 on any hit)
# Only allowlisted file kinds are copied. Transcripts, screen captures, PTY logs, container/gateway logs,
# task-log copies, the codeword and probe tokens live in $HX/run/<RUN>/raw and are NEVER copied.
# Node names become node-a/node-b/..., site names (site.env values and $HX/redact.txt lines) become
# <redacted>, pod IPs are removed. The scan then refuses: key shapes, OpenShell placeholders, JWT shapes,
# private IPv4 addresses, site names, the codeword/probe tokens, and transcript-shaped JSON. A failed scan
# reports only category, file path and matching-line count; it never prints the matching content.
set -euo pipefail
HX=$HOME/.cache/hxc
site_literals() { # site-specific names that must never be committed (values only, >= 4 chars)
  if [ -r "$HX/site.env" ]; then sed -n 's/^[A-Z_]*=//p' "$HX/site.env" | tr -d "\"'" | grep -E '.{4,}' | grep -v -E '^[0-9.]+$|^exp008c-' || true; fi
  if [ -r "$HX/redact.txt" ]; then grep -E '.{4,}' "$HX/redact.txt" || true; fi
}
# scan never prints matching content: only category, matching-line count and path per file.
# A grep error (unreadable file etc.) fails closed.
SCAN_CAT=(key-shape placeholder jwt private-ipv4 transcript-json private-key)
SCAN_PAT=('sk-ant-' 'openshell:resolve' 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  '\b(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}\b'
  '"type": ?"(assistant|api-request-blob|api-request-shape)"|"tool_use_id"' 'BEGIN [A-Z ]*PRIVATE KEY')
scan_one() { # scan_one <category> <path> <grep pattern options...>: prints "HIT <category> <file> <count>" per file
  local c=$1 f=$2 rc out line; shift 2
  # -a: files with NUL bytes are scanned as text (a "binary" file is not exempt from the scan)
  out=$(LC_ALL=C grep -r -a -H -c "$@" -- "$f" 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" -le 1 ] || { printf 'ERROR\t%s\t%s\tn/a\n' "$c" "$f"; return; }
  while IFS= read -r line; do
    [ -n "$line" ] && [ "${line##*:}" != 0 ] && printf 'HIT\t%s\t%s\t%s\n' "$c" "${line%:*}" "${line##*:}"
  done <<<"$out"
}
scan() {
  local f i res lit tok
  lit=$(mktemp); tok=$(mktemp); trap 'rm -f "$lit" "$tok"' RETURN
  site_literals | sort -u >"$lit"
  for r in "$HX"/run/*/raw; do cat "$r/codeword" "$r"/*-probe 2>/dev/null || true; done | grep . | sort -u >"$tok" || true
  res=$(for f in "$@"; do
    for i in "${!SCAN_CAT[@]}"; do scan_one "${SCAN_CAT[$i]}" "$f" -E -e "${SCAN_PAT[$i]}"; done
    if [ -s "$lit" ]; then scan_one site-literal "$f" -F -f "$lit"; fi
    if [ -s "$tok" ]; then scan_one run-token "$f" -F -f "$tok"; fi
  done) || true
  if [ -z "$res" ]; then echo "scan: clean ($*)"; return 0; fi
  awk -F '\t' '{printf "scan: %s category=%s lines=%s file=%s\n", ($1 == "HIT" ? "hit" : "error"), $2, $4, $3}' <<<"$res" >&2
  echo "scan: FAILED - $(grep -c '^HIT' <<<"$res" || true) file/category hit(s), $(grep -c '^ERROR' <<<"$res" || true) error(s); contents not shown; do not commit" >&2
  return 1
}
if [ "${1:-}" = --scan ]; then shift; scan "$@"; exit; fi
RUN=$1 DEST=$2
[[ $RUN =~ ^[0-9]{4}-[0-9]{4}$ ]] || { echo "bad RUN" >&2; exit 2; }
E=$HX/run/$RUN/e
[ -d "$E" ] || { echo "no evidence at $E" >&2; exit 2; }
[ ! -e "$DEST" ] || { echo "$DEST exists; refusing to overwrite evidence" >&2; exit 2; }
mkdir -p "$DEST"
# fail closed: any exit before a passing scan (including an error under set -e) removes the copy
SCANNED=
trap '[ -n "$SCANNED" ] || { rm -rf "$DEST"; echo "export removed: did not complete a passing scan" >&2; }' EXIT
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
    -o -path './inv/diff-*' -o -path './inv/unexpected-diffs*.txt' -o -path './inv/restoration*.txt' -o -path './inv/restore-checks*.txt' \
    -o -path './inv/diff-files*.txt' -o -path './obs/scale-ops.txt' -o -path './obs/cleanup-*.txt' \
    -o -path './obs/*-t' -o -path './obs/*-probe-t' -o -path './obs/c0-create.err' -o -path './obs/cleanup-delete.err' \
    -o -path './obs/argo-changed-*.txt' -o -path './obs/*-S.txt' -o -path './obs/*-G-gwpod.txt' \
  \) -print0 | xargs -0 -I{} cp --parents {} "$DEST/" )
# X2/T files carry the last task-log line (timestamps, step numbers, ppid/pcmd hashes): allowed.
# node names -> node-a..., pod IPs dropped
nodes=$( { cat "$E"/obs/*-C-pods.json "$E"/samples/*.jsonl 2>/dev/null | grep -o -E '"(node|nodeName)": ?"[^"]+"' | sed -E 's/.*: ?"([^"]+)"/\1/'
  cat "$E"/obs/*-G-gwpod.txt 2>/dev/null | awk 'NF >= 2 {print $2}'; } | { grep -E '^[A-Za-z0-9.-]{2,}$' || true; } | sort -u) || true
i=0; for n in $nodes; do lbl=node-$(printf "\\x$(printf %x $((97 + i)))"); { grep -r -l -F "$n" "$DEST" || true; } | xargs -r sed -i "s/$n/$lbl/g"; i=$((i + 1)); done
{ grep -r -l -E '"(podIP|hostIP)"' "$DEST" || true; } | xargs -r sed -i -E 's/"(podIP|hostIP)": ?"[^"]*"/"\1": "<redacted>"/g'
site_literals | sort -u | while read -r s; do
  { grep -r -l -F "$s" "$DEST" || true; } | xargs -r sed -i "s|$(printf %s "$s" | sed 's/[|&\\]/\\&/g')|<redacted>|g"
done
echo "exported $(find "$DEST" -type f | wc -l) files to $DEST"
scan "$DEST" || { echo "scan failed (fix the redaction, then export again)" >&2; exit 1; }
SCANNED=1
