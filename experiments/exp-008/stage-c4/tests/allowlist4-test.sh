#!/usr/bin/env bash
# Static check of stagec4.sh (offline; reads the script text only): every cluster/CLI/terminal action goes through
# its allowlisted wrapper, the wrappers allow exactly the approved Phase 1 mutations (M1-M3b, M4b, M6-M11), each
# mutation is bound to its step, and nothing from Phase 2, C1-C3 or the gateway is present.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
H=${STAGEC4_SH:-$D/stagec4.sh}
fails=0; no() { echo "FAIL - $*"; fails=$((fails + 1)); }; ok() { echo "ok   - $*"; }
annot() { awk '
  /^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/ { fn=$1; sub(/\(\).*/,"",fn) }
  /^[a-z0-9_|-]+\)/ { st=$1; sub(/\).*/,"",st); fn="step:" st }
  { print fn "\t" NR "\t" $0 }' "$H"; }
code() { annot | grep -v -P '\t\s*#' | sed -E 's/[[:space:]]+# [^"'"'"']*$//'; }
fnbody() { awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' "$H"; }
stepbody() { awk -v s="$1" '$0 ~ "^"s"\\)" {p=1} p {print} p && /^  ;;$/ {exit}' "$H"; }
KW=$(fnbody kw) OB=$(fnbody O) WP=$(fnbody wpod_ok) KXB=$(fnbody kx) TLB=$(fnbody type_line)
S_C4A=$(stepbody c4a) S_C4B=$(stepbody c4b) S_C4C=$(stepbody c4c) S_CL=$(stepbody cleanup)

# 1. raw kubectl only in K (read), kw (M9), kx (exec) and the sampler watch
bad=$(code | grep -F '"${KC[@]}"' | grep -v -E '^(K|kw|kx|kwatch)	' | grep -v 'KC=(')
[ -z "$bad" ] && ok "raw kubectl confined to K/kw/kx/kwatch" || no "raw kubectl outside wrappers: $bad"
kwl=$(code | grep -F '"${KC[@]}"' | grep -E '^kwatch	')
[ "$(grep -c . <<<"$kwl")" = 1 ] && grep -q -F -- '--watch --output-watch-events -o json' <<<"$kwl" && ok "kwatch is one read-only get --watch" || no "kwatch: $kwl"
# 2. no kubectl mutation verb outside kw/kx
bad=$(code | sed -E 's/(log|stop|fail|sstop|nr) "[^"]*"//g' | grep -E '(\bK|KC\[@\]\}"|kubectl)( [^|;]*)? (delete|patch|apply|edit|replace|annotate|label|cordon|drain|rollout|cp|scale|exec|create)\b' | grep -v -E '^(kw|kx)	')
[ -z "$bad" ] && ok "no kubectl delete/patch/apply/scale/... outside kw/kx" || no "mutation verb: $bad"
# 3. kw allows exactly M9: the recorded workload pod, 1 s grace, no wait; armed, once, c4a only
kwc=$(grep -E '^\s+"[a-z]' <<<"$KW")
[ "$(grep -c . <<<"$kwc")" = 1 ] && grep -q -F '"delete pod $w --grace-period=1 --wait=false")' <<<"$kwc" && ok "kw allows exactly 'delete pod <recorded workload> --grace-period=1 --wait=false'" || no "kw allowlist: $kwc"
grep -q -F '[ "$STEP" = c4a ] && [ -e "$E/obs/c4a-armed" ]' <<<"$KW" && grep -q 'c4a-m9-issued' <<<"$KW" && grep -q 'wpod_ok' <<<"$KW" \
  && ok "kw requires step c4a, an armed (complete) reference snapshot, once-only marker, labels+UID" || no "kw guards"
grep -n -E -- '--force|--grace-period=0|--now\b' "$H" | grep -v -E '^\s*[0-9]+:\s*#' | grep -v 'Never --force' && no "--force/--grace-period=0 present" || ok "no --force / --grace-period=0 / --now"
[ "$(code | grep -E '(^|[^a-z_])kw ' | grep -v -E '^kw	' | grep -c .)" = 1 ] && code | grep -E '(^|[^a-z_])kw ' | grep -v -E '^kw	' | grep -q '^step:c4a	' \
  && ok "kw is called exactly once, in step c4a" || no "kw callers: $(code | grep -E '(^|[^a-z_])kw ' | grep -v -E '^kw	')"
grep -q -E 'scale|replicas=0' <<<"$KW" && no "kw mentions scale" || ok "no gateway scale mutation"
# 4. kx: only fixed scripts, labels AND UID re-checked
grep -q -F '{.metadata.uid}' <<<"$WP" && grep -q 'wuid' <<<"$WP" && ok "wpod_ok compares the pod UID (never a same-name replacement)" || no "wpod_ok lacks UID"
grep -q 'wpod_ok ||' <<<"$KXB" && ok "kx re-checks the workload identity before every exec" || no "kx guard"
for x in X8 X9 X10; do b=$(sed -n "s/^$x='\(.*\)'$/\1/p" "$H" | sed 's#2>/dev/null##g'); [ -n "$b" ] || no "$x not found"; grep -q -E '\b(rm|mv|cp|chmod|kill|tee|touch|mkdir)\b|>' <<<"$b" && no "$x writes or mutates" || ok "$x is read-only"; done
# 5. CLI only via O and client_start; O allows exactly the approved subcommands, each bound to its step
bad=$(code | grep -F '"$CLI"' | grep -v -E '^(O|client_start)	' | grep -v 'sha256sum "$CLI"')
[ -z "$bad" ] && ok "openshell CLI only via O/client_start" || no "CLI outside wrappers: $bad"
subs=$(grep -v -F '" | "' <<<"$OB" | sed -n 's/^  "\([a-z]* [a-z]*\)".*/\1/p' | sort | tr '\n' ',')
exp='gateway logout,profile list,provider list,sandbox create,sandbox delete,sandbox exec,sandbox start,sandbox stop,'
o2=$(sed -n 's/^  "\([a-z]* [a-z]*\)" | "\([a-z]* [a-z]*\)" | "\([a-z]* [a-z]*\)").*/\1,\2,\3/p' <<<"$OB")
[ "$subs" = "$exp" ] && [ "$o2" = "sandbox get,sandbox list,gateway list" ] && ok "O allows exactly: reads + create/delete/exec/stop/start/logout" || no "O subcommands: $subs | $o2"
for b in 'sandbox create")|[ "$STEP" = c0-create ]' 'sandbox delete")|[ "$STEP" = cleanup ]' 'sandbox exec")|[ "$STEP" = c0-baseline ]' 'gateway logout")|[ "$STEP" = logout ]' \
  'sandbox stop")|[ "$STEP" = c4b ] && [ "$#" -eq 3 ] && [ "$3" = "$SBX" ] && [ ! -e "$E/done-m10" ]' \
  'sandbox start")|[ "$STEP" = c4b ] && [ "$#" -eq 3 ] && [ "$3" = "$SBX" ] && [ -e "$E/done-m10" ] && [ ! -e "$E/done-m11" ]'; do
  k=${b%%|*} g=${b#*|}
  awk -v k="$k" 'index($0, k) {p=1} p {print} p && /;;/ {exit}' <<<"$OB" | grep -q -F "$g" || no "O step binding missing for ${k%\"*}: $g"
done
ok "O binds create/exec/stop/start/delete/logout to their steps (checked above)"
grep -q -F '"${*:5}" = "${CREATE[*]} -- ${LAUNCH[*]}"' <<<"$OB" && ok "sandbox create only with the exact CREATE/LAUNCH argv" || no "create argv not pinned"
grep -q -- '--no-keep | --keep | --driver-config\* | --upload\* | --workspace\*' <<<"$OB" && ok "create refuses --no-keep/--keep/--driver-config/--upload/--workspace" || no "create denylist"
# 6. stop/start called only in c4b, delete only in cleanup
for v in stop start; do c=$(code | grep -E "O sandbox $v " | grep -v -E '^O	'); [ "$(grep -c . <<<"$c")" = 1 ] && grep -q '^step:c4b	' <<<"$c" && ok "sandbox $v called once, in c4b" || no "sandbox $v callers: $c"; done
c=$(code | grep -E 'O sandbox delete ' | grep -v -E '^O	'); [ "$(grep -c . <<<"$c")" = 1 ] && grep -q '^step:cleanup	' <<<"$c" && ok "sandbox delete called once, in cleanup" || no "delete callers: $c"
grep -q -E 'O sandbox (stop|start)|kw ' <<<"$S_CL" && no "cleanup stops/starts/deletes pods" || ok "cleanup never stops/starts the sandbox or deletes pods"
# 7. no credential, provider, profile, driver-config or GitOps mutation; no Phase 2
bad=$(code | grep -E 'provider (create|delete|update)|profile (import|delete|update)|--credential|--from-existing|--auto-providers|ANTHROPIC_API_KEY=|driver-config-json|allowDriverConfig|allow_driver_config|sandbox-attachable|gh (pr|api -X|repo)|git (push|commit)')
[ -z "$bad" ] && ok "no provider/profile/credential/driver-config/attachable-PVC/GitOps mutation" || no "forbidden path: $bad"
grep -q -E '^(c1|c1-reattach|c2|c2-reattach)\)' "$H" && no "C1-C3 steps present" || ok "no C1-C3 steps (no client kill window, no gateway outage)"
# 8. keys to tmux only from type_line, ctrl_l, client_detach; kill only in client_kill and the sampler
bad=$(code | grep -F 'send-keys' | grep -v -E '^(type_line|ctrl_l|client_detach)	')
[ -z "$bad" ] && ok "send-keys confined" || no "send-keys outside wrappers: $bad"
bad=$(code | grep -E '(^|[[:space:];&(])kill[[:space:]]' | grep -v -E '^(client_kill|sampler)	')
[ -z "$bad" ] && ok "kill confined to client_kill/sampler" || no "kill elsewhere: $bad"
grep -q 'INPUT_MAX' <<<"$TLB" && ok "type_line enforces the c4c input cap" || no "type_line cap"
# 9. single attempt: every mutating step once-only; cleanup has its own marker
grep -q 'done-cleanup" \] || fail "cleanup already ran' "$H" && ok "cleanup has its own single-attempt marker" || no "cleanup marker"
for st in c0-create c0-baseline c4a c4b c4c; do b=$(stepbody "$st"); grep -q "once $st" <<<"$(sed -n '1,2p' <<<"$b")" && ok "$st is once-only" || no "$st lacks once"; done
grep -q 'need c0-baseline' <<<"$S_C4A" && grep -q 'need c4a' <<<"$S_C4B" && grep -q 'need c4b' <<<"$S_C4C" && ok "c4a needs c0-baseline; c4b needs c4a; c4c needs c4b" || no "step ordering guards"
a1=$(grep -n -F 'touch "$E/obs/c4a-armed"' <<<"$S_C4A" | cut -d: -f1) a0=$(grep -n -F 'nz "$armed" || stop' <<<"$S_C4A" | cut -d: -f1) a2=$(grep -n -F 'kw delete pod' <<<"$S_C4A" | cut -d: -f1)
[ -n "$a1" ] && [ -n "$a0" ] && [ -n "$a2" ] && [ "$a1" -gt "$a0" ] && [ "$a2" -gt "$a1" ] \
  && ok "c4a arms M9 only after a complete R (stop otherwise)" || no "c4a arming order"
grep -q -F '[ "$ph" = Error ] ||' <<<"$S_C4B" && ok "c4b stops unless the sandbox is in Error (never stops another phase)" || no "c4b Error precondition"
# 10. the resume launcher: plain --resume, never with --session-id or a prompt; no auto-continue variable set
L=$D/task/launch.sh
grep -E -- '--resume' "$L" | grep -v '^\s*#' | grep -q -- '--session-id' && no "launcher passes --session-id with --resume" || ok "launcher: --resume never with --session-id"
tail -n 2 "$L" | grep -q -E -- '--resume "\$SID"$' && ok "launcher: --resume <sid> is the last argument (no positional prompt)" || no "resume argv tail"
grep -r -n -E 'CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1|export CLAUDE_CODE_RESUME' "$D" --include='*.sh' | grep -v '/tests/' && no "an auto-continue variable is set" || ok "no auto-continue variable is set by the harness or launcher"
grep -q '^unset CLAUDE_CODE_RESUME_INTERRUPTED_TURN CLAUDE_CODE_RESUME_PROMPT CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS$' "$L" && ok "launcher unsets the auto-continue variables" || no "launcher unset"
# 11. the C0-C3 harness is untouched by C4 (C0-C3 cannot perform a C4 mutation)
grep -v '^\s*#' "$D/../stage-c/stagec.sh" | grep -q -E 'sandbox (stop|start)|delete pod' && no "C0-C3 harness gained a C4 mutation" || ok "C0-C3 harness has no stop/start/pod-delete"
# negative controls (outer run only): each mutated copy of stagec4.sh must be caught
if [ -z "${STAGEC4_SH:-}" ]; then
  NC=$(mktemp -d); trap 'rm -rf "$NC"' EXIT
  neg() { # neg <name> <python replacement old> <new>
    python3 -I -c 'import sys; s=open(sys.argv[1]).read(); assert s.count(sys.argv[2]) >= 1, sys.argv[2]; open(sys.argv[3], "w").write(s.replace(sys.argv[2], sys.argv[3 + 1], 1))' "$D/stagec4.sh" "$2" "$NC/$1.sh" "$3" || { no "negative control $1: could not build"; return; }
    if STAGEC4_SH="$NC/$1.sh" bash "$0" >/dev/null 2>&1 </dev/null; then no "negative control $1 NOT caught"; else ok "negative control caught: $1"; fi
  }
  neg kw-scale '  *) log "REFUSED kw $f"; return 97 ;;' '  "scale statefulset/$GW_STS --replicas=0") ;;
  *) log "REFUSED kw $f"; return 97 ;;'
  neg kw-force '"delete pod $w --grace-period=1 --wait=false")' '"delete pod $w --grace-period=1 --wait=false" | "delete pod $w --force")'
  neg kw-unarmed '[ "$STEP" = c4a ] && [ -e "$E/obs/c4a-armed" ] ||' '[ "$STEP" = c4a ] ||'
  neg O-suspend '  "gateway logout") [' '  "sandbox suspend") ;;
  "gateway logout") ['
  neg O-stop-anystep '[ "$STEP" = c4b ] && [ "$#" -eq 3 ] && [ "$3" = "$SBX" ] && [ ! -e "$E/done-m10" ]' '[ "$#" -eq 3 ] && [ "$3" = "$SBX" ] && [ ! -e "$E/done-m10" ]'
  neg cleanup-stops '  if [ -e "$E/done-c0-create" ]; then OT=180 O sandbox delete' '  O sandbox stop "$SBX"; if [ -e "$E/done-c0-create" ]; then OT=180 O sandbox delete'
  neg no-once-c4b '  guard_full; need c4a; once c4b' '  guard_full; need c4a'
  neg raw-kubectl-delete '  ph=$(phase_now); echo "phase_before_stop=$ph"' '  "${KC[@]}" -n "$NS" delete pod x; ph=$(phase_now); echo "phase_before_stop=$ph"'
  neg provider-create '  gw_registered || stop "CLI gateway registration $GWNAME missing"' '  O provider create --name x; gw_registered || stop "CLI gateway registration $GWNAME missing"'
  neg wpod-no-uid "{.metadata.labels.openshell\\.ai/boundary-role} {.metadata.uid}'" "{.metadata.labels.openshell\\.ai/boundary-role}'"
fi
echo "failures=$fails"; [ "$fails" = 0 ]
