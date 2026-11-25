#!/usr/bin/env bash
# Dynamic offline test of stagec.sh wrappers: the real O(), client_scan() and type_line() function bodies
# are extracted and run against a stub CLI and fake local processes. No cluster, no network.
set -uo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)/stagec.sh
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
fn() { awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' "$H"; }
{ sed -n "/^X5PY='/,/)))'\$/p" "$H"; fn O; fn client_scan; fn type_line; } >"$T/lib.sh"
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
  "gateway logout other" "sandbox connect $SBX" "sandbox upload $SBX x"; do
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
echo "failures=$fails"; [ "$fails" = 0 ]
