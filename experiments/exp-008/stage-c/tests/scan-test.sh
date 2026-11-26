#!/usr/bin/env bash
# Correction B regression test: export.sh's scan must FAIL on secret-shaped content and report only
# category, path and line counts, never the matching content. All secret-shaped strings are SYNTHETIC
# and assembled at run time (none appears literally in this file). Isolated HOME; no cluster, no network.
set -uo pipefail
X=$(cd "$(dirname "$0")/.." && pwd)/export.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
rnd() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
HX=$T/.cache/hxc RAW=$HX/run/0101-0101/raw; mkdir -p "$RAW" "$T/d" "$T/clean"
a=sk b=ant c=openshell d=resolve
KEY="$a-$b-api03-$(rnd 24)"                                  # key shape
PH="$c:$d:env:v1_ANTHROPIC_API_KEY_$(rnd 4)"                  # OpenShell placeholder
JWT="ey""J$(rnd 8).ey""J$(rnd 8).$(rnd 8)"                    # JWT shape
IP="10.$((RANDOM % 200 + 20)).$((RANDOM % 200 + 20)).$((RANDOM % 200 + 20))"
PK="-----BEGIN ""OPENSSH PRIVATE KEY-----"
TRJ="{\"type\": \"assist""ant\", \"note\": \"$(rnd 6)\"}"     # transcript-shaped JSON
SITE="site-ctx-$(rnd 5)"; NODE="node-name-$(rnd 5)"; CW="codeword-$(rnd 5)"; PROBE="PROBE-$(rnd 5)"
printf 'CTX=%s\nPROV=exp008c-anthropic\n' "$SITE" >"$HX/site.env"; echo "$NODE" >"$HX/redact.txt"
echo "$CW" >"$RAW/codeword"; echo "$PROBE" >"$RAW/r1-probe"
i=0
for v in "$KEY" "$PH" "$JWT" "$IP" "$PK" "$TRJ" "$SITE" "$NODE" "$CW" "$PROBE"; do
  i=$((i + 1)); printf 'line one\nvalue: %s trailing\nline three\n' "$v" >"$T/d/f$i.txt"
done
SECRETS=("$KEY" "$PH" "$JWT" "$IP" "$PK" "$TRJ" "$SITE" "$NODE" "$CW" "$PROBE")
FRAGS=("${KEY: -16}" "${PH##*_}" "${JWT: -8}" "${SITE##*-}" "${NODE##*-}" "${CW##*-}" "${PROBE##*-}")

out=$(HOME=$T bash "$X" --scan "$T/d" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "scan fails on synthetic secrets (rc=1)" || no "scan rc=$rc (expected 1)"
leak=0; for s in "${SECRETS[@]}" "${FRAGS[@]}"; do grep -q -F -- "$s" <<<"$out" && { leak=1; no "scan output contains a matched value (${#s} chars)"; }; done
[ "$leak" = 0 ] && ok "scan output contains none of the ${#SECRETS[@]} values or their random fragments"
grep -q -E 'value:|trailing' <<<"$out" && no "scan output contains matching line text" || ok "scan output contains no line text"
for c in key-shape placeholder jwt private-ipv4 private-key transcript-json site-literal run-token; do
  grep -q "category=$c " <<<"$out" && ok "category reported: $c" || no "category missing: $c"
done
n=$(grep -c '^scan: hit ' <<<"$out"); [ "$n" -ge 10 ] && ok "one hit line per file/category ($n)" || no "hit lines: $n"
grep -q -E "^scan: hit category=key-shape lines=1 file=$T/d/f1.txt$" <<<"$out" && ok "hit line = category + count + path only" || no "hit line format: $(grep -m1 key-shape <<<"$out")"
grep -q 'contents not shown' <<<"$out" && ok "summary says contents not shown" || no "summary line"

# a file with NUL bytes is not exempt; a path with spaces is reported whole
mkdir -p "$T/bin dir"; printf 'bin\0ary %s\0\n' "$KEY" >"$T/bin dir/f.bin"
out=$(HOME=$T bash "$X" --scan "$T/bin dir" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q -F "category=key-shape lines=1 file=$T/bin dir/f.bin" <<<"$out" && ok "NUL-byte file scanned; path with spaces reported whole" || no "binary/space path: rc=$rc"
grep -q -F -- "${KEY: -16}" <<<"$out" && no "binary scan leaks the value" || ok "binary scan output leaks no value"

echo "harmless text, step=12 t=2027-01-15T08:00:00Z" >"$T/clean/a.txt"
out=$(HOME=$T bash "$X" --scan "$T/clean" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q '^scan: clean' <<<"$out" && ok "clean directory passes" || no "clean directory rc=$rc: $out"
out=$(HOME=$T bash "$X" --scan "$T/missing" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'category=key-shape lines=n/a' <<<"$out" && ok "unreadable path fails closed" || no "missing path rc=$rc"

# full export path: a secret in an allowlisted evidence file -> export refuses, removes DEST, prints no value
E=$HX/run/0101-0101/e; mkdir -p "$E/obs"
printf 'step=c0 ok\nleak %s here\n' "$KEY" >"$E/timeline.log"; echo "process=same" >"$E/obs/c1-result.txt"
out=$(HOME=$T bash "$X" 0101-0101 "$T/dest" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "export refuses (rc=1)" || no "export rc=$rc"
[ ! -e "$T/dest" ] && ok "export removed DEST after a failed scan" || no "DEST kept"
grep -q -F -- "${KEY: -16}" <<<"$out" && no "export output leaks the value" || ok "export output leaks no value"
grep -q "file=$T/dest/timeline.log" <<<"$out" && ok "export names the offending file" || no "export did not name the file"

# success path: no secrets; a node name and pod IP in an allowlisted pods file are redacted; scan passes
E2=$HX/run/0202-0202/e; mkdir -p "$E2/obs" "$E2/samples"; rm -f "$RAW/codeword" "$RAW/r1-probe"
printf 'step=c0 ok\n--- %s/.cache/hxc/run/0202-0202/e/inv/pre/argo.txt\n' "$T" >"$E2/timeline.log"
printf '{"items": [{"node": "%s", "podIP": "%s"}]}\n' "$NODE" "$IP" >"$E2/obs/c1-C-pods.json"
printf '{"type":"ADDED","msg":"Readiness probe failed: dial tcp %s:5501: connect: refused"}\n' "$IP" >"$E2/samples/events-watch.jsonl"
out=$(HOME=$T bash "$X" 0202-0202 "$T/dest2" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q '^scan: clean' <<<"$out" && ok "clean export completes with a passing scan" || no "clean export rc=$rc: $out"
grep -q '"node": "node-a"' "$T/dest2/obs/c1-C-pods.json" 2>/dev/null && ok "node name mapped to node-a" || no "node name not mapped"
grep -q '"podIP": "<redacted>"' "$T/dest2/obs/c1-C-pods.json" 2>/dev/null && ok "pod IP redacted" || no "pod IP not redacted"
grep -q -F -- '--- ~/.cache/hxc/run/0202-0202/e/inv/pre/argo.txt' "$T/dest2/timeline.log" && ok "local HOME path shortened to ~" || no "HOME path not shortened"
grep -q 'dial tcp <private-ip>:5501' "$T/dest2/samples/events-watch.jsonl" 2>/dev/null && ! grep -q -F "$IP" "$T/dest2/samples/events-watch.jsonl" && ok "private IPv4 in an event message redacted" || no "event-message IP not redacted"
out=$(HOME=$T bash "$X" 0202-0202 "$T/dest2" 2>&1); rc=$?
[ "$rc" = 2 ] && [ -s "$T/dest2/timeline.log" ] && ok "existing DEST is never overwritten or removed" || no "existing DEST rc=$rc"
echo "failures=$fails"; [ "$fails" = 0 ]
