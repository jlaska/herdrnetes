#!/usr/bin/env bash
# Self-test of the stage-3 task (python only, no claude, no network):
#   experiments/exp-006/local/agent-task/selftest.sh
# Runs check.py on the stubs (0/12), on reference.py (12/12), checks the
# progress.log line format, and checks that a broken kata.py (syntax error,
# import-time sys.exit, import-time infinite loop) still gives TOTAL 0/12 and a log line.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -r "$HERE/repo/." "$tmp/"
chk() { (cd "$tmp" && timeout 15 python3 -B check.py "$@"); }
fail() { echo "SELFTEST FAIL: $*" >&2; exit 1; }

out=$(chk --nolog)
grep -qx 'TOTAL 0/12' <<<"$out" || fail "stubs: expected TOTAL 0/12, got: $out"
[ "$(grep -c '^FAIL f' <<<"$out")" = 12 ] || fail "stubs: expected 12 FAIL lines"
[ ! -e "$tmp/progress.log" ] || fail "--nolog wrote progress.log"
echo "stubs: TOTAL 0/12 ok"

cp "$HERE/reference.py" "$tmp/kata.py"
out=$(chk --nolog)
grep -qx 'TOTAL 12/12' <<<"$out" || fail "reference: expected TOTAL 12/12, got: $out"
[ "$(grep -c '^PASS f' <<<"$out")" = 12 ] || fail "reference: expected 12 PASS lines"
echo "reference: TOTAL 12/12 ok"

chk >/dev/null
want='^[0-9]+\.[0-9]+ check 12/12 passing=f01,f02,f03,f04,f05,f06,f07,f08,f09,f10,f11,f12$'
{ [ "$(wc -l <"$tmp/progress.log")" = 1 ] && grep -qE "$want" "$tmp/progress.log"; } || fail "progress.log format: $(cat "$tmp/progress.log")"
echo "progress.log: $(cat "$tmp/progress.log")"

for bad in 'def f01(:' 'import sys; sys.exit(0)' 'while True: pass'; do
  echo "$bad" >"$tmp/kata.py"
  : >"$tmp/progress.log"
  out=$(chk 2>&1) || fail "broken kata.py ($bad): check.py failed or exceeded 15 s: $out"
  grep -qx 'TOTAL 0/12' <<<"$out" || fail "broken kata.py ($bad): expected TOTAL 0/12, got: $out"
  grep -qE ' check 0/12 passing=$' "$tmp/progress.log" || fail "broken kata.py ($bad): no 0/12 log line"
  echo "broken kata.py ($bad): TOTAL 0/12 and logged ok"
done
echo "SELFTEST PASS"
