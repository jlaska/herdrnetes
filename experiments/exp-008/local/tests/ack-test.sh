#!/usr/bin/env bash
# Offline regression tests for the pane-ACK region of demo.sh (wrap-aware ACK verification).
# Starts no process of the experiment and uses no network: Herdr is a stub that serves fixture
# files, and every capture is written under a mktemp -d directory, removed on exit.
# Fixtures: fixtures/ack/run3-* are run 3's (1123-122157) pane captures and ACK log lines, copied
# byte for byte; syn-* and bad-* are synthetic.
# Usage: bash experiments/exp-008/local/tests/ack-test.sh
# shellcheck disable=SC2015,SC2034 # ok/no always return 0; CPID/CSTART/CNONCE are read by the eval'd region
set -u
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
DEMO="$HERE/../demo.sh"
FX="$HERE/fixtures/ack"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT

die() { echo "FAIL setup: $*" >&2; exit 2; }

# ------------------------------------------------------------ load code under test
[ -r "$DEMO" ] || die "cannot read $DEMO"
[ "$(grep -c -x -F '# >>> pane-ack' "$DEMO")" = 1 ] || die "marker '# >>> pane-ack' missing"
[ "$(grep -c -x -F '# <<< pane-ack' "$DEMO")" = 1 ] || die "marker '# <<< pane-ack' missing"
REGION=$(awk '$0 == "# >>> pane-ack" { f = 1; next } $0 == "# <<< pane-ack" { f = 0 } f' "$DEMO")
[ -n "$REGION" ] || die "pane-ack region is empty"
t_fn() { awk -v n="$1" 'index($0, n "() {") == 1 { f = 1 } f { print } f && $0 == "}" { exit }' "$DEMO"; }
t_oneliner() { awk -v n="$1" 'index($0, n "() {") == 1 { print; exit }' "$DEMO"; }
FN_POLL=$(t_fn poll)
FN_WAIT=$(t_oneliner wait_for)
FN_ACKF=$(t_oneliner ackf)
FN_PRESENT=$(t_oneliner ack_present)
FN_TYPE=$(t_oneliner type_line)
for v in FN_POLL FN_WAIT FN_ACKF FN_PRESENT FN_TYPE; do [ -n "${!v}" ] || die "$v not found in $DEMO"; done

E="$T/e"
mkdir -p "$E/panes" "$E/obs"
redact() { cat; }
LOG="$T/counter.log"
ack_line() { grep " ACK $1 pid=" "$LOG" 2>/dev/null | tail -n 1; } # demo.sh reads the counter's log through cread
# Herdr stub: `pane read` serves the fixture assigned to a source; send-text/send-keys are recorded
SERVE_visible=/dev/null; SERVE_recent=/dev/null; SERVE_unwrapped=/dev/null
H() {
  case "$1 $2" in
  "pane read")
    case $5 in visible) cat "$SERVE_visible" ;; recent) cat "$SERVE_recent" ;; recent-unwrapped) cat "$SERVE_unwrapped" ;; *) return 1 ;; esac ;;
  "pane send-text" | "pane send-keys") echo "$*" >>"$T/typed.txt"; [ -z "${ON_TYPE:-}" ] || cat "$ON_TYPE" >>"$LOG" ;;
  *) return 1 ;;
  esac
}
eval "$FN_POLL"
eval "$FN_WAIT"
eval "$FN_ACKF"
eval "$FN_PRESENT"
eval "$FN_TYPE"
eval "$REGION"

# ------------------------------------------------------------ helpers
PASS=0; FAILN=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAILN=$((FAILN + 1)); echo "FAIL $1${2:+ ($2)}"; }
# expect_match <name> <fixture> <expected> <method-glob>
expect_match() {
  local m
  if m=$(ack_rows_match "$FX/$2" "$3"); then
    case $m in "$4") ok "$1 -> $m" ;; *) no "$1" "matched as '$m', expected '$4'" ;; esac
  else no "$1" "no match"; fi
}
expect_nomatch() { # <name> <fixture> <expected>
  local m
  if m=$(ack_rows_match "$FX/$2" "$3"); then no "$1" "false match '$m'"; else ok "$1 -> no match"; fi
}
id52() { CPID=52; CSTART=43423622; CNONCE=fdf5d2b339358279; }
caps() { cp "${1:-/dev/null}" "$E/panes/$4.txt"; cp "${2:-/dev/null}" "$E/panes/$4-recent.txt"; cp "${3:-/dev/null}" "$E/panes/$4-unwrapped.txt"; } # <visible> <recent> <unwrapped> <tag>

A4B="ACK a4b pid=52 start=43423622 nonce=fdf5d2b339358279 n=38"
A6="ACK a6ro2 pid=52 start=43423622 nonce=fdf5d2b339358279 n=120"

# ------------------------------------------------------------ 1. run 3's exact A4b ACK (three rows, 27 columns)
[ "$(sed -n 's/^[^ ]* [^ ]* //p' "$FX/run3-counter-acks.log" | grep -c -x -F "$A4B")" = 1 ] && ok "fixture: run 3 log holds the exact A4b ACK" || no "fixture: run 3 log A4b line"
if grep -F "ACK a4b pid=52 start=43423622 nonce=fdf5d2b339358279" "$FX/run3-a4b-visible.txt" >/dev/null; then no "run 3 defect reproduced" "the old exact-line grep matches"
else ok "run 3 defect reproduced: the old exact-line grep finds no A4b ACK in the visible capture"; fi
expect_match "run 3 A4b visible capture" run3-a4b-visible.txt "$A4B" "wrapped:27:3"
expect_match "run 3 A4b recent capture" run3-a4b-recent.txt "$A4B" "wrapped:27:3"
expect_match "run 3 A4a ACK, wrapped in the same 27-column capture" run3-a4b-visible.txt "ACK a4a pid=52 start=43423622 nonce=fdf5d2b339358279 n=25" "wrapped:27:3"
expect_match "run 3 A3 ACK, replayed and wrapped" run3-a4b-visible.txt "ACK a3 pid=52 start=43423622 nonce=fdf5d2b339358279 n=13" "wrapped:27:3"

# ------------------------------------------------------------ 2. normal width
expect_match "run 3 A1 ACK at 96 columns" run3-a1-visible.txt "ACK a1 pid=52 start=43423622 nonce=fdf5d2b339358279 n=5" line
expect_match "run 3 A4a ACK at 57 columns" run3-a4a-visible.txt "ACK a4a pid=52 start=43423622 nonce=fdf5d2b339358279 n=25" line
expect_match "Herdr recent-unwrapped style (one row)" syn-a6-unwrapped.txt "$A6" line
expect_match "A6 viewer at 47 columns" syn-a6-w47.txt "$A6" "wrapped:47:2"
expect_match "wrap just after a space (32 columns, space trimmed)" syn-a6-w32-space.txt "$A6" "wrapped:32:2"
expect_match "wrap after a space at 17 columns, four rows" syn-a6-w17-space.txt "$A6" "wrapped:17:4"

# ------------------------------------------------------------ 3. incorrect identities
expect_nomatch "wrong nonce" run3-a4b-visible.txt "ACK a4b pid=52 start=43423622 nonce=fdf5d2b339358278 n=38"
expect_nomatch "wrong start" run3-a4b-visible.txt "ACK a4b pid=52 start=43423623 nonce=fdf5d2b339358279 n=38"
expect_nomatch "wrong pid" run3-a4b-visible.txt "ACK a4b pid=53 start=43423622 nonce=fdf5d2b339358279 n=38"
expect_nomatch "wrong n" run3-a4b-visible.txt "ACK a4b pid=52 start=43423622 nonce=fdf5d2b339358279 n=37"
expect_nomatch "wrong word (a4 vs a4b)" run3-a4b-visible.txt "ACK a4 pid=52 start=43423622 nonce=fdf5d2b339358279 n=38"
expect_nomatch "normal width, wrong nonce" run3-a1-visible.txt "ACK a1 pid=52 start=43423622 nonce=0000000000000000 n=5"
expect_nomatch "A6 47 columns, wrong n" syn-a6-w47.txt "ACK a6ro2 pid=52 start=43423622 nonce=fdf5d2b339358279 n=12"
expect_nomatch "a6ro must not match a6ro2's ACK" syn-a6-unwrapped.txt "ACK a6ro pid=52 start=43423622 nonce=fdf5d2b339358279 n=120"

# ------------------------------------------------------------ 4. incomplete ACKs
expect_nomatch "capture ends before the last wrapped row" bad-a4b-incomplete-2rows.txt "$A4B"
expect_nomatch "single row without n" bad-a4b-incomplete-noN.txt "$A4B"
expect_nomatch "empty capture" bad-empty.txt "$A4B"
expect_nomatch "missing capture file" does-not-exist.txt "$A4B"
expect_nomatch "empty expected ACK" run3-a4b-visible.txt ""

# ------------------------------------------------------------ 5. unrelated output
expect_nomatch "unrelated row between the wrapped rows" bad-a4b-interleaved.txt "$A4B"
expect_nomatch "extra digit after n" bad-a4b-extra-digit.txt "$A4B"
expect_nomatch "trailing text after n" bad-a4b-trailing-text.txt "$A4B"
expect_nomatch "text before the ACK on its row" bad-a4b-prefixed.txt "$A4B"
expect_nomatch "rows of unequal width (not a soft wrap)" bad-a4b-uneven-rows.txt "$A4B"
expect_nomatch "ticks only" bad-ticks-only.txt "$A4B"

# ------------------------------------------------------------ 6. notices (text_rows_seen)
text_rows_seen "$FX/syn-notice-w20.txt" "openshell: attached read-only" && ok "notice wrapped at 20 columns (whole line)" || no "notice wrapped at 20 columns"
text_rows_seen "$FX/syn-a6-unwrapped.txt" "attached read-only" && no "notice absent" "false match" || ok "notice absent -> no match"

# ------------------------------------------------------------ 7. verify_ack (log identity + saved captures)
grep ' ACK a4b ' "$FX/run3-counter-acks.log" >"$LOG"
id52
caps "$FX/run3-a4b-visible.txt" "$FX/run3-a4b-recent.txt" "" a4b
if verify_ack a4b 31 && [ "$ACKN" = 38 ]; then ok "verify_ack: run 3 A4b passes (n=38 > 31)"; else no "verify_ack: run 3 A4b" "$(tr '\n' ' ' <"$E/obs/ack-a4b.txt")"; fi
grep -q -x 'source=visible match=wrapped:27:3' "$E/obs/ack-a4b.txt" && grep -q -x 'source=unwrapped match=none' "$E/obs/ack-a4b.txt" &&
  grep -q -x 'verify=pass' "$E/obs/ack-a4b.txt" && ok "verify_ack: per-source results recorded" || no "verify_ack: obs record"
verify_ack a4b 38 && no "verify_ack: n must exceed the minimum" || ok "verify_ack: n=38 not > 38 fails"
CNONCE=fdf5d2b339358278
verify_ack a4b 31 && no "verify_ack: identity mismatch" "passed" || ok "verify_ack: wrong expected nonce fails"
CPID=; CSTART=; CNONCE=
verify_ack a4b 31 && no "verify_ack: uninitialised identity" "passed" || ok "verify_ack: uninitialised identity fails"
grep -q 'expected=<none' "$E/obs/ack-a4b.txt" && ok "verify_ack: uninitialised identity recorded" || no "verify_ack: uninitialised record"
id52
caps "" "" "" a4b
verify_ack a4b 31 && no "verify_ack: no pane capture" "passed" || ok "verify_ack: log-only ACK (no pane evidence) fails"
echo "1795454753.667934 2026-11-23T17:25:53 ACK a4b pid=52 start=43423622 nonce=fdf5d2b339358279 n=38 extra" >"$LOG"
caps "$FX/run3-a4b-visible.txt" "" "" a4b
verify_ack a4b 31 && no "verify_ack: altered log line" "passed" || ok "verify_ack: log line with an extra field fails"
: >"$LOG"
verify_ack a4b 31 && no "verify_ack: no log ACK" "passed" || ok "verify_ack: no ACK in the log fails"
# a5a after a restart: a new identity; the old incarnation's ACK must not satisfy it
echo "1795455000.000001 2026-11-23T17:30:00 ACK a5a pid=52 start=50000000 nonce=1111111111111111 n=4" >"$LOG"
printf 'tick n=3\nmark a5a\nACK a5a pid=52 start=50000000 nonce=1111111111111111 n=4\ntick n=5\n' >"$T/a5a.txt"
caps "$T/a5a.txt" "" "" a5a
verify_ack a5a 0 && no "verify_ack: A5 new ACK with the pre-restart identity loaded" "passed" || ok "verify_ack: A5 new ACK fails while the pre-restart identity is loaded"
CPID=52; CSTART=50000000; CNONCE=1111111111111111
verify_ack a5a 0 && ok "verify_ack: A5 passes once the new identity is loaded" || no "verify_ack: A5 loaded identity"
id52
verify_ack a5a 0 && no "verify_ack: stale (pre-restart) identity" "passed" || ok "verify_ack: stale pre-restart identity fails"

# ------------------------------------------------------------ 8. mark (typing, log wait, pane poll) via the Herdr stub
id52
echo "1795455100.000001 2026-11-23T17:31:40 ACK a6ro2 pid=52 start=43423622 nonce=fdf5d2b339358279 n=120" >"$T/on-type.log"
: >"$LOG"; ON_TYPE="$T/on-type.log"; SERVE_visible="$FX/syn-a6-w47.txt"; SERVE_recent=/dev/null; SERVE_unwrapped=/dev/null
rc=0; mark p2 a6ro2 2 || rc=$?
[ "$rc" = 0 ] && verify_ack a6ro2 0 && ok "mark+verify_ack: A6 viewer, 47 columns" || no "mark: A6 viewer 47 columns" "rc=$rc"
grep -q 'pane send-text p2 mark a6ro2' "$T/typed.txt" && ok "mark: typed 'mark a6ro2' into the pane" || no "mark: typing"
: >"$LOG"; SERVE_visible="$FX/bad-a4b-interleaved.txt"; SERVE_unwrapped="$FX/bad-ticks-only.txt"
rc=0; mark p2 a6ro2 2 || rc=$?
[ "$rc" = 2 ] && ok "mark: log ACK but no complete pane ACK -> rc 2" || no "mark: pane missing" "rc=$rc"
: >"$LOG"; ON_TYPE=
rc=0; mark p2 a6ro2 1 || rc=$?
[ "$rc" = 1 ] && ok "mark: no log ACK -> rc 1" || no "mark: no log ACK" "rc=$rc"

# ------------------------------------------------------------ 9. static: every pane ACK check goes through verify_ack
c=$(grep -c -E 'wait-output[^#]*--match "ACK|grep "ACK \$' "$DEMO")
[ "$c" = 0 ] && ok "static: no exact-line ACK grep or ACK wait-output left in demo.sh" || no "static: old ACK checks remain" "$c"
for f in run_a1 run_a6 run_a5a run_a5b restart_test; do
  body=$(t_fn "$f")
  words=$(grep -o -E 'mark "[^"]*" "?[a-z0-9$]+"?' <<<"$body" | awk '{ gsub(/"/, "", $3); print $3 }' | sort -u)
  miss=$(for w in $words; do grep -q -F "verify_ack $w " <<<"$body" || grep -q -F "verify_ack \"$w\" " <<<"$body" || echo "$w"; done)
  [ -n "$words" ] && [ -z "$miss" ] && ok "static: $f verifies every marked word with verify_ack ($(tr '\n' ' ' <<<"$words"))" || no "static: $f" "words=$(tr '\n' ' ' <<<"$words") unverified=$(tr '\n' ' ' <<<"$miss")"
done

# ------------------------------------------------------------ 10. A5 classification (a5_classify)
eval "$(t_oneliner kv)"
eval "$(grep -m1 '^IDENT_KEYS=' "$DEMO")"
eval "$(t_fn same_ident)"
eval "$(t_fn a5_classify)"
eval "$(t_fn a5_gap)"
clog() { :; }
idf() { # idf <label> <pid> <start> <nonce> <instance> <started_ms> <hpid> <hstart>
  printf 'pid=%s\nstart=%s\nnonce=%s\ninstance_id=%s\nstarted_at_ms=%s\nhpid=%s\nhstart=%s\nphase=Ready\n' "${@:2}" >"$E/obs/$1-identity.txt"
}
idf pre 52 100 aaaa i1 1000 900 100
idf same 52 100 aaaa i1 1000 900 100
idf new 52 200 bbbb i2 2000 950 200
idf msonly 52 100 aaaa i1 1001 900 100
idf partial 52 200 "" i2 2000 950 200
expect_cls() { local c; c=$(a5_classify t "$2" "$3" "$4"); [ "$c" = "$5" ] && ok "a5_classify: $1 -> $c" || no "a5_classify: $1" "got $c, want $5"; }
expect_cls "all keys equal" pre same yes survived
expect_cls "new process (start, nonce, instance, host pid)" pre new yes restarted
expect_cls "only started_at_ms differs" pre msonly yes inconclusive
expect_cls "a key missing after the restart" pre partial yes inconclusive
expect_cls "identity sources did not settle" pre new no inconclusive
expect_cls "equal keys but not settled" pre same no inconclusive

echo
echo "passed: $PASS  failed: $FAILN"
[ "$FAILN" = 0 ]
