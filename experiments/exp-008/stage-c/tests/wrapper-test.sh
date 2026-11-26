#!/usr/bin/env bash
# Dynamic offline test of stagec.sh wrappers: the real O(), client_scan() and type_line() function bodies
# are extracted and run against a stub CLI and fake local processes. No cluster, no network.
set -uo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)/stagec.sh
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
fn() { awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' "$H"; }
{ sed -n "/^X5PY='/,/)))'\$/p" "$H"; fn O; fn client_scan; fn type_line; fn kw; fn sts_gen; fn spend_check; fn providers; fn profiles; } >"$T/lib.sh"
SBX=exp008c-0101-0101 GWNAME=exp008c HX=$T/hx E=$T/e STEP=test TL=$T/tl
mkdir -p "$HX/bin" "$E"; echo sid-1234 >"$E/sbx_id"
log() { echo "$*" >>"$TL"; }
printf '#!/bin/sh\necho "ARGC=$#"\n' >"$HX/bin/openshell"; chmod +x "$HX/bin/openshell"
CLI=$HX/bin/openshell OENV=(env)
# shellcheck source=/dev/null
. "$T/lib.sh"
grep -q '^X5PY=' "$T/lib.sh" && ok "X5PY extracted" || no "X5PY not extracted"

# O(): accepted forms reach the CLI with the exact argument count
out=$(O sandbox exec "$SBX" --no-tty --no-login-shell --timeout 60 -- python3 -I -c "$X5PY"); [ "$out" = "ARGC=14" ] && ok "M8 sandbox exec accepted (12 args + -g gw)" || no "M8 refused or wrong argc: $out"
for bad in "sandbox exec $SBX --no-tty --no-login-shell --timeout 60 -- python3 -I -c print(1)" "sandbox exec other --no-tty --no-login-shell --timeout 60 -- python3 -I -c X" \
  "sandbox delete other" "sandbox delete $SBX --force" "sandbox create --name other" "provider create --name x" "provider delete x" "provider list" "profile import -f x" \
  "gateway logout other" "sandbox connect $SBX" "sandbox upload $SBX x" "profile list -o json" "profile delete claude-code-exp008c" "profile export x"; do
  # shellcheck disable=SC2086
  O $bad >/dev/null 2>&1; [ $? = 97 ] && ok "refused: ${bad:0:60}" || no "NOT refused: $bad"
done
out=$(O sandbox exec "$SBX" --no-tty --no-login-shell --timeout 60 -- python3 -I -c "$X5PY" extra 2>/dev/null); [ -z "$out" ] && ok "refused: M8 with an extra argument" || no "M8 with extra arg accepted"
[ "$(O provider list --names)" = "ARGC=5" ] && ok "provider list --names accepted" || no "provider list --names"
[ "$(O sandbox delete "$SBX")" = "ARGC=5" ] && ok "sandbox delete \$SBX accepted" || no "sandbox delete"

# client_scan(): sees fake client chain processes, ignores harness reads and kubectl
start() { (exec -a "$1" sleep 60) & sleep 0.2; }
start "kubectl --context c -n openshell exec default--$SBX -c agent -- sh -c X"
start "kubectl --context c -n openshell get pod default--$SBX"
start "$HX/bin/openshell -g exp008c sandbox get $SBX -o json"
start "$HX/bin/openshell -g exp008c sandbox exec $SBX --no-tty"
start "/usr/bin/openshell -g other sandbox connect unrelated"
[ -z "$(client_scan)" ] && ok "client_scan ignores kubectl, harness reads, unrelated openshell" || no "client_scan false positive: $(client_scan)"
start "$HX/bin/openshell -g exp008c sandbox connect $SBX"
start "ssh -tt -o ProxyCommand=$HX/bin/openshell ssh-proxy --sandbox-id sid-1234 sandbox"
start "/bin/sh -c $HX/bin/openshell ssh-proxy --sandbox-id sid-1234"
start "$HX/bin/openshell ssh-proxy --sandbox-id sid-1234"
n=$(client_scan | grep -c .); [ "$n" = 4 ] && ok "client_scan sees all 4 client-chain processes" || no "client_scan saw $n of 4: $(client_scan)"

# type_line(): no control bytes; text never logged
TM=(true)
type_line x "Reply PROBE-ab12 and continue" probe && grep -q 'probe chars=29 sha256=' "$TL" && ! grep -q 'PROBE-ab12' "$TL" && ok "type_line logs length+hash only" || no "type_line logging"
type_line x $'bad\x04ctrl-d' >/dev/null 2>&1; [ $? = 97 ] && ok "type_line refuses Ctrl-D" || no "type_line accepted a control byte"
type_line x $'bad\x10' >/dev/null 2>&1; [ $? = 97 ] && ok "type_line refuses Ctrl-P" || no "type_line accepted Ctrl-P"
[ "$(O profile list)" = "ARGC=4" ] && ok "profile list (read-only, post validation) accepted" || no "profile list"

# kw(): M5 records generation before/after for every scale; post's restore-check explains exactly that chain
NS=openshell GW_STS=openshell; echo 3 >"$T/gen"; mkdir -p "$E/obs"
ref() { echo 1; }; guard_ctx() { true; }; ems() { echo 1000; }; stop() { echo "STOP: $*" >>"$TL"; exit 3; }
K() { cat "$T/gen"; }                                    # sts_gen reads through K
kstub() { case "$*" in *scale*) echo $(( $(cat "$T/gen") + 1 )) >"$T/gen" ;; esac; }; KC=(kstub)
kw scale "statefulset/$GW_STS" --replicas=0 && kw scale "statefulset/$GW_STS" --replicas=1 && ok "kw scale 0 and back accepted" || no "kw scale refused"
kw scale "statefulset/$GW_STS" --replicas=5 >/dev/null 2>&1; [ $? = 97 ] && ok "kw scale to another value refused" || no "kw scale 5 accepted"
kw delete pod x >/dev/null 2>&1; [ $? = 97 ] && ok "kw delete refused" || no "kw delete accepted"
[ "$(grep -c . "$E/obs/scale-ops.txt")" = 2 ] && grep -q 'rc=0 gen_before=3 gen_after=4 op=scale' "$E/obs/scale-ops.txt" && ok "scale ops recorded with generations" || no "scale-ops: $(cat "$E/obs/scale-ops.txt")"
echo gen=3 >"$T/g-pre"; echo "gen=$(cat "$T/gen")" >"$T/g-post"
[ "$(bash "$(dirname "$H")/restore-check.sh" generation "$T/g-pre" "$T/g-post" "$E/obs/scale-ops.txt")" = "explained pre=3 post=5 scale_ops=2" ] && ok "restore-check explains the recorded chain" || no "restore-check did not explain the chain"

# spend_check(): fail closed once model activity began (correction A); real metrics.py, stubbed transcript copy
HERE=$(dirname "$H") L=$T/raw BUDGET_USD=2; mkdir -p "$L/tr" "$E/metrics"
now() { echo 2027-01-15T08:00:00Z; }
asst() { printf '{"type":"assistant","message":{"id":"%s","model":"claude-haiku-5-5","usage":{"input_tokens":%s,"output_tokens":%s}}}\n' "$@"; }
sc() { ( spend_check ) >/dev/null 2>&1; echo $?; }   # rc 3 = STOP
reset_sc() { rm -f "$E/done-c0-create" "$E/tr_rel" "$E/obs/spend.txt" "$E/obs/c0-baseline-done"; }
reset_sc; STEP=c1; [ "$(sc)" = 0 ] && ok "spend: no model activity yet -> no check" || no "spend before c0-create"
touch "$E/done-c0-create"; STEP=c1; [ "$(sc)" = 3 ] && ok "spend: activity began, transcript not located -> STOP" || no "spend: unlocated transcript not a stop"
STEP=c0-baseline; [ "$(sc)" = 0 ] && ok "spend: c0-baseline may locate the transcript first" || no "spend in c0-baseline"
echo "proj/00000000-0000-0000-0000-000000000000.jsonl" >"$E/tr_rel"; STEP=c1
kx() { return 1; }; [ "$(sc)" = 3 ] && ok "spend: transcript copy failure -> STOP" || no "spend: copy failure not a stop"
kx() { cp "$T/tr" "$2"; }
asst m1 1000 100 >"$T/tr"; [ "$(sc)" = 0 ] && grep -q 'reliable=true' "$E/obs/spend.txt" && ok "spend: reliable small estimate passes and is logged" || no "spend: reliable estimate"
grep -q 'transcript estimate; Console cap is authoritative' "$E/obs/spend.txt" && ok "spend: logged as an estimate (Console authoritative)" || no "spend label"
printf '{"type":"assistant","message":{"id":"m2","model":"claude-haiku-5-5"}}\n' >>"$T/tr"; [ "$(sc)" = 3 ] && ok "spend: missing usage -> STOP" || no "spend: missing usage not a stop"
: >"$T/tr"; rm -f "$E/obs/spend.txt"; [ "$(sc)" = 3 ] && ok "spend: zero assistant messages after activity -> STOP" || no "spend: empty transcript not a stop"
asst m1 1000 100 >"$T/tr"; asst m2 150000 400000 >>"$T/tr"; rm -f "$E/obs/spend.txt"; [ "$(sc)" = 0 ] && ok "spend: long-context estimate under 80% passes (1.08 < 1.60)" || no "spend: 1.08 stopped"
asst m3 1000000 300000 >>"$T/tr"; [ "$(sc)" = 3 ] && grep -q "80% of 2" "$TL" && ok "spend: long-context card pushes estimate over 80% -> STOP" || no "spend: over-budget not a stop"
asst m1 1000 100 >"$T/tr"; echo "2027 step=c1 est_usd=0.5 budget=2 reliable=true" >"$E/obs/spend.txt"; [ "$(sc)" = 3 ] && ok "spend: estimate decreased -> STOP" || no "spend: decrease not a stop"

# providers()/profiles(): a CLI failure is an ERROR marker, never an empty-looking list; table normalised
( O() { printf 'b\na\n'; }; [ "$(providers)" = "$(printf 'a\nb')" ] ) && ok "providers: sorted names" || no "providers sorted"
( O() { return 1; }; out=$(providers); rc=$?; [ "$rc" = 1 ] && [ "$out" = "ERROR provider-list-failed" ] ) && ok "providers: CLI failure -> ERROR marker, rc 1" || no "providers failure"
( O() { printf 'NAME                 TYPE      CATEGORY   SOURCE  SCOPE\nclaude-code-exp008c  provider  INFERENCE  user    workspace\n'; }; [ "$(profiles)" = "claude-code-exp008c  provider  INFERENCE  user    workspace" ] ) && ok "profiles: header dropped" || no "profiles header"
( O() { echo "No profiles found."; }; [ -z "$(profiles)" ] ) && ok "profiles: empty catalog -> empty list" || no "profiles empty catalog"
( O() { return 1; }; [ "$(profiles)" = "ERROR profile-list-failed" ] ) && ok "profiles: CLI failure -> ERROR marker" || no "profiles failure"
echo "failures=$fails"; [ "$fails" = 0 ]
