#!/usr/bin/env bash
# Dynamic offline test of stagec4.sh: the REAL wrapper functions (O, kw, kx, wpod_ok, type_line, client_scan) and
# the REAL c4a / c4b / cleanup step bodies are extracted from the script and run against a stub CLI, a stub
# kubectl and a simulated clock. No cluster, no network, no credential. Proves: mutations only with their guards,
# each tied to the recorded sandbox/workload identity, once only, no retries; stop/start timeouts and phases;
# cleanup from Stopped/Error/settling phases, and residue reported instead of bypassed.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
H=$D/stagec4.sh
T=$(mktemp -d); if [ -n "${KEEP:-}" ]; then echo "T=$T" >&2; else trap 'rm -rf "$T"' EXIT; fi
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
# the function section of the harness (between the first helper and the step dispatcher), and step bodies
awk '/^now\(\) \{/ {p=1} /^# =+ steps$/ {p=0} p' "$H" >"$T/lib.sh"
body() { awk -v s="$1" '$0 ~ "^"s"\\)" {p=1; next} p && /^  ;;$/ {exit} p' "$H"; }
for s in c4a c4b cleanup; do { echo "run_${s}() {"; body "$s"; echo "}"; } >"$T/step-$s.sh"; done
grep -q '^kw() {' "$T/lib.sh" && grep -q '^O() {' "$T/lib.sh" && [ -s "$T/step-c4b.sh" ] && ok "functions and step bodies extracted" || { no "extraction"; exit 1; }

# ---------------------------------------------------------------- simulator
cp "$D/tests/openshell-stub.sh" "$T/cli" # shared stub CLI (enforces the 32,768-byte per-element create limit)
chmod +x "$T/cli"
cat >"$T/kubectl" <<'EOF'
#!/usr/bin/env bash
# stub kubectl for kw/kx: records mutating calls; exec prints scripted output
echo "$*" >>"$SIM/kubectl-calls"
case " $* " in *" exec "*) cat "$SIM/exec-out" 2>/dev/null ;; *" delete pod "*) echo gone >"$SIM/wpod-state" ;; esac
EOF
chmod +x "$T/kubectl"

setup() { # setup <name>: a fresh simulated run in its own directory
  SIM=$T/sim-$1; E=$SIM/e; L=$SIM/l; export SIM
  mkdir -p "$SIM" "$E/obs" "$E/metrics" "$E/samples" "$E/term" "$L/tr" "$L/task" "$L/term" "$L/logs"
  echo Error >"$SIM/phase"; echo ok >"$SIM/stop-mode"; echo ok >"$SIM/start-mode"; : >"$SIM/cli-calls"; : >"$SIM/kubectl-calls"; : >"$SIM/residue"
  echo sid-1 >"$E/sbx_id"; echo default--exp008c4-0101-0101 >"$E/sbx_cr_name"; echo "openshell/default--exp008c4-0101-0101" >"$E/sbx_cr"
  echo wpod-1 >"$E/wpod"; echo uid-old >"$E/wuid"; echo agent >"$E/wctr"; echo live >"$SIM/wpod-state"
  echo 46.0 >"$E/obs/M_s"
}
common() { # shared definitions + stubs (sourced inside each scenario subshell)
  RUN=0101-0101 SBX=exp008c4-0101-0101 NS=openshell GW_POD=openshell-0 GW_STS=openshell GWNAME=exp008c HX=$T/hx TL=$SIM/tl
  HERE=$D C0=$D/../stage-c M4=(python3 -I "$D/metrics4.py") M0=(python3 -I "$D/../stage-c/metrics.py")
  SETTLE_MAX=300 ARG_ELEM_MAX=32768 PAYLOAD_BUDGET=24576 INPUT_MAX=2 R_AGE_MIN=3000 R_AGE_MAX=12000 KILL_AGE_MAX=30000 KILL_DEADLINE_AGE=38000 STEP_SLEEP=45 TM=(true)
  # shellcheck source=/dev/null
  . "$T/lib.sh"
  CLI=$T/cli OENV=(env SIM="$SIM") KC=("$T/kubectl")
  CLK=1000000; ems() { echo "$CLK"; }; sleep() { local s=${1%%.*}; CLK=$((CLK + ${s:-1} * 1000 + 1)); }
  log() { echo "$*" >>"$TL"; }; stop() { echo "STOP: $*" >>"$SIM/stops"; exit 3; }; fail() { echo "FAIL: $*" >>"$SIM/stops"; exit 4; }
  guard_full() { :; }; guard_ctx() { :; }; spend_check() { :; }; grab_logs() { :; }; client_scan() { :; }
  K() { # read-only cluster stub: labels/UID of the workload pod, empty residue unless SIM/residue says otherwise
    case " $* " in
    *" get pod wpod-1 "*) [ "$(cat "$SIM/wpod-state")" = live ] && echo "sid-1 workload $(cat "$SIM/live-uid" 2>/dev/null || echo uid-old)" ;;
    *" get pod openshell-0 "*) echo gwuid ;;
    *" sandboxes.agents.x-k8s.io "*) [ -e "$SIM/crs-fail" ] && return 1; cat "$SIM/crs" 2>/dev/null; return 0 ;;
    *" logs "*) cat "$SIM/launcher-log" 2>/dev/null ;;
    *" -o name"*) cat "$SIM/residue" ;;
    *" -o json "*) echo '{"items": []}' ;;
    *) : ;;
    esac; }
}

# ---------------------------------------------------------------- O(): step binding, exact argv, once-only stop/start
( setup o; common
  STEP=c4a; O sandbox stop "$SBX" >/dev/null 2>&1; [ $? = 97 ] && ok "O: stop refused outside c4b" || no "O: stop accepted outside c4b"
  STEP=c4b; O sandbox start "$SBX" >/dev/null 2>&1; [ $? = 97 ] && ok "O: start refused before stop" || no "O: start before stop accepted"
  O sandbox stop other >/dev/null 2>&1; [ $? = 97 ] && ok "O: stop of another sandbox refused" || no "O: stop other accepted"
  O sandbox stop "$SBX" --force >/dev/null 2>&1; [ $? = 97 ] && ok "O: stop with an extra argument refused" || no "O: stop extra arg accepted"
  O sandbox stop "$SBX" && ok "O: stop \$SBX accepted in c4b" || no "O: stop refused in c4b"
  O sandbox stop "$SBX" >/dev/null 2>&1; [ $? = 97 ] && ok "O: second stop refused (once)" || no "O: second stop accepted"
  O sandbox start "$SBX" && ok "O: start accepted after stop" || no "O: start refused after stop"
  O sandbox start "$SBX" >/dev/null 2>&1; [ $? = 97 ] && ok "O: second start refused (once)" || no "O: second start accepted"
  [ "$(grep -c -E '^sandbox (stop|start) ' "$SIM/cli-calls")" = 2 ] && ok "O: exactly one stop and one start reached the CLI" || no "O: CLI calls: $(cat "$SIM/cli-calls")"
  for st in c0-create c4a c4c cleanup; do STEP=$st; O sandbox suspend "$SBX" >/dev/null 2>&1; [ $? = 97 ] || no "O: suspend accepted in $st"; done; ok "O: suspend/resume never allowed"
  STEP=c4b; O sandbox delete "$SBX" >/dev/null 2>&1; [ $? = 97 ] && ok "O: delete refused outside cleanup" || no "O: delete outside cleanup"
  STEP=cleanup; O sandbox delete "$SBX" >/dev/null && ok "O: delete accepted in cleanup" || no "O: delete refused in cleanup"
  STEP=c0-create; CREATE=(--from x --provider p --detach --tty --restart-policy never --no-auto-providers) LAUNCH=(/bin/sh -c boot pkg sha)
  O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >/dev/null 2>&1; [ $? = 97 ] && ok "O: create refused without a passing launch_check record" || no "O: create accepted without launch_check"
  echo "launch_check=fail argc=5" >"$E/obs/c0-launch-result.txt"
  O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >/dev/null 2>&1; [ $? = 97 ] && ok "O: create refused with a failed launch_check record" || no "O: create accepted with launch_check=fail"
  echo "launch_check=pass argc=5" >"$E/obs/c0-launch-result.txt"
  O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >/dev/null && ok "O: the exact M1 argv accepted" || no "O: exact create refused"
  LAUNCH=(/bin/sh -c boot "$(head -c 24576 /dev/zero | tr '\0' A)" sha); O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >/dev/null && ok "O: a 24,576-byte payload (at the budget) accepted" || no "O: payload at the budget refused"
  LAUNCH=(/bin/sh -c boot "$(head -c 24577 /dev/zero | tr '\0' A)" sha); O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >/dev/null 2>&1; [ $? = 97 ] && ok "O: a 24,577-byte payload refused (budget 24,576)" || no "O: payload over budget accepted"
  LAUNCH=(/bin/sh -c "$(head -c 32769 /dev/zero | tr '\0' A)" pkg sha); O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >/dev/null 2>&1; [ $? = 97 ] && ok "O: a 32,769-byte element refused" || no "O: element over the limit accepted"
  [ "$(grep -c '^sandbox create ' "$SIM/cli-calls")" = 2 ] && ok "O: only the in-budget creates reached the CLI" || no "O: create calls: $(grep -c '^sandbox create ' "$SIM/cli-calls")"
  LAUNCH=(/bin/sh -c boot pkg sha)
  O sandbox create --name "$SBX" "${CREATE[@]}" --no-keep -- "${LAUNCH[@]}" >/dev/null 2>&1; [ $? = 97 ] && ok "O: create with --no-keep refused" || no "O: --no-keep accepted"
  O sandbox create --name "$SBX" "${CREATE[@]}" --driver-config-json '{}' -- "${LAUNCH[@]}" >/dev/null 2>&1; [ $? = 97 ] && ok "O: create with driver config refused" || no "O: driver config accepted"
  CREATE+=(--no-keep); O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >/dev/null 2>&1; [ $? = 97 ] && ok "O: --no-keep refused even inside CREATE" || no "O: CREATE with --no-keep accepted"
  STEP=c4a; O sandbox create --name "$SBX" --from x -- y >/dev/null 2>&1; [ $? = 97 ] && ok "O: create refused outside c0-create" || no "O: create outside c0-create"
  for bad in "provider create --name x" "provider delete x" "profile import -f x" "sandbox connect $SBX" "sandbox upload $SBX x" "sandbox exec $SBX -- sh"; do
    # shellcheck disable=SC2086
    O $bad >/dev/null 2>&1; [ $? = 97 ] || no "O: NOT refused: $bad"
  done; ok "O: provider/profile/connect/upload/arbitrary exec refused"
) || no "O scenario aborted"

# ---------------------------------------------------------------- kw(): M9 only armed, once, c4a, recorded UID
( setup kw; common; echo uid-old >"$SIM/live-uid"
  STEP=c4a; kw delete pod wpod-1 --grace-period=1 --wait=false >/dev/null 2>&1; [ $? = 97 ] && ok "kw: refused before the reference snapshot arms it" || no "kw: unarmed delete accepted"
  touch "$E/obs/c4a-armed"
  STEP=c4b; kw delete pod wpod-1 --grace-period=1 --wait=false >/dev/null 2>&1; [ $? = 97 ] && ok "kw: refused outside c4a" || no "kw: accepted outside c4a"
  STEP=c4a
  for bad in "delete pod wpod-1 --grace-period=0 --wait=false" "delete pod wpod-1 --force --grace-period=1 --wait=false" "delete pod openshell-0 --grace-period=1 --wait=false" \
    "delete pod wpod-1" "scale statefulset/openshell --replicas=0" "delete pvc workspace-x"; do
    # shellcheck disable=SC2086
    kw $bad >/dev/null 2>&1; [ $? = 97 ] || no "kw NOT refused: $bad"
  done; ok "kw: grace 0, --force, gateway pod, default grace, scale and PVC delete refused"
  echo uid-new >"$SIM/live-uid"; kw delete pod wpod-1 --grace-period=1 --wait=false >/dev/null 2>&1; [ $? = 97 ] && ok "kw: refused when the pod UID is not the recorded one (replacement)" || no "kw: replacement pod deleted"
  echo uid-old >"$SIM/live-uid"
  kw delete pod wpod-1 --grace-period=1 --wait=false >/dev/null 2>&1; [ $? = 97 ] && ok "kw: refused without a kill deadline" || no "kw: accepted without a deadline"
  echo $((CLK - 1)) >"$E/obs/c4a-kill-deadline"; kw delete pod wpod-1 --grace-period=1 --wait=false >/dev/null 2>&1; [ $? = 97 ] && ok "kw: refused past the kill deadline (step N may have finished)" || no "kw: accepted past the deadline"
  echo $((CLK + 5000)) >"$E/obs/c4a-kill-deadline"
  kw delete pod wpod-1 --grace-period=1 --wait=false >/dev/null && ok "kw: M9 accepted when armed in c4a with the recorded UID" || no "kw: armed delete refused"
  kw delete pod wpod-1 --grace-period=1 --wait=false >/dev/null 2>&1; [ $? = 97 ] && ok "kw: second M9 refused (once)" || no "kw: second delete accepted"
  [ "$(grep -c 'delete pod' "$SIM/kubectl-calls")" = 1 ] && grep -q -- '-n openshell delete pod wpod-1 --grace-period=1 --wait=false' "$SIM/kubectl-calls" && ok "kw: exactly one delete reached kubectl" || no "kw calls: $(cat "$SIM/kubectl-calls")"
) || no "kw scenario aborted"

# ---------------------------------------------------------------- kx(): never into a same-name replacement
( setup kx; common; echo uid-old >"$SIM/live-uid"; echo "hello" >"$SIM/exec-out"; STEP=c4a
  kx X8 "$SIM/x8" && grep -q hello "$SIM/x8" && ok "kx: exec into the recorded workload" || no "kx: recorded workload exec failed"
  echo uid-repl >"$SIM/live-uid"; : >"$SIM/kubectl-calls"
  kx X8 "$SIM/x8b"; [ $? != 0 ] && [ ! -s "$SIM/kubectl-calls" ] && ok "kx: refused for a same-name pod with another UID (no exec issued)" || no "kx: exec into a replacement"
  echo uid-old >"$SIM/live-uid"; kx X99 "$SIM/x"; rc=$?; [ "$rc" = 97 ] && ok "kx: unknown script refused (rc 97)" || no "kx: unknown script rc=$rc"
) || no "kx scenario aborted"

# ---------------------------------------------------------------- type_line(): c4c input cap, fixed text, no control bytes
( setup tl; common; STEP=c4c
  P1='Reply on one line exactly: PROBE-0a1b2c3d CODEWORD=<the codeword I gave you> LAST=<number of the last step that printed STEP OK>. Do not run any tool for this reply.'
  type_line r1 "$P1" probe && ok "type_line: the approved probe line is accepted" || no "type_line: probe refused"
  type_line r1 "Continue the task." continue && ok "type_line: the continuation line is accepted" || no "type_line: continue refused"
  type_line r1 "Continue the task." continue >/dev/null 2>&1; [ $? = 97 ] && ok "type_line: third c4c input refused (cap 2)" || no "type_line: cap not enforced"
  STEP=c0-baseline; type_line main $'x\x04' >/dev/null 2>&1; [ $? = 97 ] && ok "type_line: Ctrl-D refused" || no "type_line: control byte accepted"
  type_line main 'a\b' >/dev/null 2>&1; [ $? = 97 ] && ok "type_line: backslash refused" || no "type_line: backslash accepted"
  grep -q 'PROBE-0a1b2c3d' "$TL" && no "type_line logged the probe text" || ok "type_line logs length and hash only"
  STEP=c4a; client_start r9 >/dev/null 2>&1; [ $? = 97 ] && ok "client_start refused outside c0-baseline/c4c" || no "client_start accepted in c4a"
) || no "type_line scenario aborted"

# ---------------------------------------------------------------- c4a: no delete without a complete, timely R
c4a_world() { # stubs for the c4a body; $1 = scripted X8 sequence file
  cat >>"$SIM/c4a-stubs.sh" <<'EOF'
gate() { return 0; }
ident() { printf 'pid=71\nstart=5\nnonce=aa\nboot_id=b\nproc=71 start=5 ppid=1 nonce=aa keyref_form=absent key_form=placeholder\n' >"$E/obs/$1-P.txt"; : >"$E/obs/$1-T.txt"; echo '{}' >"$E/obs/$1-C-pods.json"; echo '{}' >"$E/obs/$1-C-cr.json"; [ ! -e "$SIM/ident-fail" ]; }
pkeys() { echo "71 5 aa b"; }; wkeys() { echo "uid-old c"; }
vread() { echo '{"pvc_uid":"p","pv":"v","pv_uid":"vu","volume_handle":"h","pvc_deleting":false,"pv_deleting":false,"va":[]}' >"$L/$1-V.json"; cp "$L/$1-V.json" "$E/metrics/$1-V.json"; }
snap() { mkdir -p "$L/task/$1"; cp "$SIM/fx/"*.log "$L/task/$1/"; cp "$SIM/fx/t.jsonl" "$L/tr/$1.jsonl"; echo '{"chain_ok": true}' >"$E/obs/$1-S.txt"; [ ! -e "$SIM/snap-fail" ]; }
kx() { local q; case $1 in X8) q=$(cat "$SIM/x8n" 2>/dev/null || echo 0); q=$((q + 1)); echo $q >"$SIM/x8n"; sed -n "${q}p" "$SIM/x8seq" | tr '|' '\n' >"$2"; [ -s "$2" ] ;; X1) [ -s "$SIM/x1-out" ] && cp "$SIM/x1-out" "$2" ;; *) return 1 ;; esac; }
spods() { if [ -e "$E/obs/c4a-m9-issued" ] && [ -s "$SIM/spods-after" ]; then cat "$SIM/spods-after"; else echo '{"items": []}'; fi; }
phase_now() { echo Error; }
EOF
}
fixture_task() { # 6 done, step 7 in flight; a transcript with the step-7 tool_use and a real model entry
  mkdir -p "$SIM/fx"
  for i in 1 2 3 4 5 6 7; do echo "attempt n=$i t=2027-01-01T00:0$i:00.000Z prior_attempts=0 sleep=45 pid=1"; done >"$SIM/fx/attempts.log"
  for i in 1 2 3 4 5 6; do echo "done n=$i t=2027-01-01T00:0$i:45.000Z pid=1"; done >"$SIM/fx/progress.log"
  : >"$SIM/fx/refusals.log"; : >"$SIM/fx/ledger.log"; : >"$SIM/fx/locks.log"
  printf '%s\n' '{"type":"assistant","uuid":"a","message":{"id":"m1","model":"claude-haiku-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t7","name":"Bash","input":{"command":"./step.sh 7 abc123"}}]}}' >"$SIM/fx/t.jsonl"
  echo '{"type":"DELETED","uid":"uid-old","cs":[]}' >"$E/samples/pods-watch.jsonl"
}
x8line() { # x8line <age_ms> [n] [done]: one scripted X8 output (fields joined by |)
  local now=1798761700000 n=${2:-7} d=${3:-6}
  local t; t=$(date -u -d "@$(( (now - $1) / 1000 ))" +%FT%T).$(printf %03d $(( (now - $1) % 1000 )))Z
  echo "now_ms=$now|last_attempt=attempt n=$n t=$t prior_attempts=0 sleep=45|last_done=done n=$d t=x|attempts=$n done=$d|lock=held|token_file_sha256=$(printf a%.0s {1..64})|state_id_sha256=$(printf b%.0s {1..64})|sid=s"
}
run_c4a_case() { # run_c4a_case <name> <x8 lines...>
  local name=$1; shift
  ( setup "c4a-$name"; common; c4a_world; fixture_task; printf '%s\n' "$@" >"$SIM/x8seq"; echo uid-old >"$SIM/live-uid"
    [ -n "${C4A_PRE:-}" ] && eval "$C4A_PRE"
    . "$SIM/c4a-stubs.sh"; . "$T/step-c4a.sh"; STEP=c4a; once() { :; }; need() { :; }
    run_c4a ) >/dev/null 2>&1
  echo "$T/sim-c4a-$name"
}
s=$(run_c4a_case good "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
[ "$(grep -c 'delete pod' "$s/kubectl-calls")" = 1 ] && [ -e "$s/e/obs/c4a-armed" ] && ok "c4a: complete R with step 7 in flight -> exactly one M9" || no "c4a good: $(cat "$s/stops" 2>/dev/null) calls=$(cat "$s/kubectl-calls")"
grep -q 'original_process=ended' "$s/e/obs/c4a-result.txt" 2>/dev/null && ok "c4a: original process ended (pod gone + DELETED event)" || no "c4a result: $(cat "$s/e/obs/c4a-result.txt" 2>/dev/null)"
grep -q 'requested grace 1 s; the recorded state, not the request' "$s/e/obs/c4a-result.txt" && ok "c4a: the observed termination (not the request) is recorded" || no "c4a termination note"
s=$(run_c4a_case late "$(x8line 5000)" "$(x8line 6000)" "$(x8line 31000)")
[ ! -s "$s/kubectl-calls" ] && grep -q 'reference snapshot incomplete or late' "$s/stops" && ok "c4a: step aged past 30 s at the re-check -> no delete, STOP (R taken once)" || no "c4a late: calls=$(cat "$s/kubectl-calls") stops=$(cat "$s/stops" 2>/dev/null)"
[ "$(cat "$s/x8n")" = 3 ] && ok "c4a: no second reference snapshot after an incomplete one" || no "c4a: R retried ($(cat "$s/x8n") X8 reads)"
POD() { printf '{"items": [{"metadata": {"uid": "%s", "deletionTimestamp": %s}, "status": {"phase": "Running", "containerStatuses": [{"state": {%s}}]}}]}' "$1" "$2" "$3"; }
C4A_PRE='POD uid-old null "\"running\": {}" >"$SIM/spods-after"; printf "nonce=aa\nproc=71 start=5 ppid=1 nonce=aa x\n" >"$SIM/x1-out"; : >"$E/samples/pods-watch.jsonl"' s=$(run_c4a_case survived "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
grep -q 'original_process=survived original_pod=present' "$s/e/obs/c4a-result.txt" && ok "c4a: original pod still present with the same nonce -> survived" || no "c4a survived: $(cat "$s/e/obs/c4a-result.txt" 2>/dev/null)"
C4A_PRE='POD uid-old "\"2027-01-01T00:00:00Z\"" "\"running\": {}" >"$SIM/spods-after"; : >"$E/samples/pods-watch.jsonl"' s=$(run_c4a_case deleting "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
grep -q 'original_process=inconclusive original_pod=deleting' "$s/e/obs/c4a-result.txt" && ok "c4a: original pod still deleting after 120 s -> inconclusive (not survived)" || no "c4a deleting: $(cat "$s/e/obs/c4a-result.txt" 2>/dev/null)"
C4A_PRE=': >"$E/samples/pods-watch.jsonl"' s=$(run_c4a_case nocapture "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
grep -q 'original_process=inconclusive original_pod=absent termination=not-captured deleted_event=no' "$s/e/obs/c4a-result.txt" && ok "c4a: pod gone but no termination or DELETED event -> inconclusive, not-captured" || no "c4a nocapture: $(cat "$s/e/obs/c4a-result.txt" 2>/dev/null)"
C4A_PRE='POD uid-repl null "\"running\": {}" >"$SIM/spods-after"' s=$(run_c4a_case ran "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
grep -q 'replacement_pod=ran' "$s/e/obs/c4a-result.txt" && grep -q 'original_process=ended' "$s/e/obs/c4a-result.txt" && ok "c4a: a running replacement pod -> replacement_pod=ran" || no "c4a ran: $(cat "$s/e/obs/c4a-result.txt" 2>/dev/null)"
C4A_PRE='POD uid-repl null "\"waiting\": {}" >"$SIM/spods-after"' s=$(run_c4a_case fenced "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
grep -q 'replacement_pod=fenced' "$s/e/obs/c4a-result.txt" && ok "c4a: a replacement pod that never ran -> fenced (FIND-090 pattern)" || no "c4a fenced: $(cat "$s/e/obs/c4a-result.txt" 2>/dev/null)"
grep -q 'replacement_pod=none' "$T/sim-c4a-good/e/obs/c4a-result.txt" && ok "c4a: no replacement pod -> none" || no "c4a none"
s=$(run_c4a_case done "$(x8line 5000)" "$(x8line 6000)" "$(x8line 7000 7 7)")
[ ! -s "$s/kubectl-calls" ] && ok "c4a: step finished between R and re-check -> no delete" || no "c4a done-between: $(cat "$s/kubectl-calls")"
s=$(run_c4a_case old "$(x8line 20000)" "$(x8line 21000)")
[ ! -s "$s/kubectl-calls" ] && ok "c4a: R never starts on a step older than 12 s -> no delete" || no "c4a old: $(cat "$s/kubectl-calls")"
C4A_PRE='touch "$SIM/snap-fail"' s=$(run_c4a_case snapfail "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
[ ! -s "$s/kubectl-calls" ] && grep -q 'snapshot' "$s/e/obs/c4a-R-attempts.txt" && ok "c4a: snapshot failure -> R incomplete, no delete" || no "c4a snapfail"
C4A_PRE='touch "$SIM/ident-fail"' s=$(run_c4a_case identfail "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
[ ! -s "$s/kubectl-calls" ] && ok "c4a: identity unreadable -> R incomplete, no delete" || no "c4a identfail"
C4A_PRE='echo uid-other >"$SIM/live-uid"' s=$(run_c4a_case uidchange "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
[ "$(grep -c 'delete pod' "$s/kubectl-calls")" = 0 ] && ok "c4a: workload UID changed before the kill -> M9 refused" || no "c4a uidchange: $(cat "$s/kubectl-calls")"
C4A_PRE='printf "%s\n" "{\"type\":\"user\"}" >"$SIM/fx/t.jsonl"' s=$(run_c4a_case notool "$(x8line 5000)" "$(x8line 6000)" "$(x8line 9000)")
[ ! -s "$s/kubectl-calls" ] && grep -q -E 'transcript|in-flight-step-not-in-R' "$s/e/obs/c4a-R-attempts.txt" && ok "c4a: in-flight step's tool_use or a real model entry missing from R -> no delete" || no "c4a notool"

# ---------------------------------------------------------------- c4b: stop/start once, from Error only, timeouts
c4b_case() { # c4b_case <name> <setup cmds>
  local name=$1 pre=$2
  ( setup "c4b-$name"; common
    echo 'step=c4a original_process=ended' >"$E/obs/c4a-result.txt"; echo uid-old >"$E/obs/c4a-old-wuid"
    echo '{"pvc_uid":"p","pv":"v","pv_uid":"vu","volume_handle":"h"}' >"$L/c4a-R-V.json"; printf 'state_id_sha256=s\ntoken_file_sha256=t\n' >"$E/obs/c4a-R-X8.txt"
    ident() { : >"$E/obs/$1-P.txt"; cat "$SIM/pods" 2>/dev/null >"$E/obs/$1-C-pods.json" || echo '{"items": []}' >"$E/obs/$1-C-pods.json"; [ -s "$E/obs/$1-C-pods.json" ] || echo '{"items": []}' >"$E/obs/$1-C-pods.json"
      cat "$SIM/cr" 2>/dev/null >"$E/obs/$1-C-cr.json"; [ -s "$E/obs/$1-C-cr.json" ] || echo '{"uid": "cr", "deletionTimestamp": null, "operatingMode": "Suspended"}' >"$E/obs/$1-C-cr.json"; return 1; }
    vread() { cat "$SIM/V" 2>/dev/null >"$L/$1-V.json" || echo '{"pvc_uid":"p","pv":"v","pv_uid":"vu","volume_handle":"h","pvc_deleting":false,"pv_deleting":false,"va":[]}' >"$L/$1-V.json"; }
    va_released() { [ ! -e "$SIM/va-attached" ]; }
    workload_resolve() { echo wpod-1 >"$E/wpod"; echo uid-new >"$E/wuid"; }
    kx() { return 1; }
    eval "$pre"
    . "$T/step-c4b.sh"; STEP=c4b; once() { :; }; need() { :; }
    run_c4b ) >/dev/null 2>&1
  echo "$T/sim-c4b-$name"
}
s=$(c4b_case normal '')
[ "$(grep -c '^sandbox stop ' "$s/cli-calls")" = 1 ] && [ "$(grep -c '^sandbox start ' "$s/cli-calls")" = 1 ] && ok "c4b: one stop then one start from Error" || no "c4b normal: $(grep -E 'stop|start' "$s/cli-calls")"
[ "$(grep -n -E '^sandbox (stop|start) ' "$s/cli-calls" | cut -d: -f2 | cut -d' ' -f2 | tr '\n' ,)" = "stop,start," ] && ok "c4b: stop precedes start" || no "c4b order"
grep -q '^step=c4b value=unmeasured ' "$s/e/obs/c4b-result.txt" && ok "c4b: with the precheck unreadable (stubbed exec) the value is unmeasured, never corrupt" || no "c4b normal result: $(head -n 1 "$s/e/obs/c4b-result.txt" 2>/dev/null)"
s=$(c4b_case launcherrefuses 'echo launcher-refuses >"$SIM/start-mode"; echo "exp008c4-launch: transcript for the recorded session is missing or not unique; not starting the agent" >"$SIM/launcher-log"')
grep -q '^step=c4b value=lost ' "$s/e/obs/c4b-result.txt" && grep -q 'launcher_refusal=transcript for the recorded session is missing or not unique' "$s/e/obs/c4b-result.txt" && [ ! -s "$s/stops" ] \
  && ok "c4b: a launcher refusal at start is read from the workload log and classified (lost), not a restart failure" || no "c4b launcher refusal: $(head -n 2 "$s/e/obs/c4b-result.txt" 2>/dev/null) stops=$(cat "$s/stops" 2>/dev/null)"
s=$(c4b_case launchercred 'echo launcher-refuses >"$SIM/start-mode"; echo "exp008c4-launch: ANTHROPIC_API_KEY is absent, not an OpenShell placeholder; not starting the agent" >"$SIM/launcher-log"')
grep -q '^step=c4b value=unmeasured ' "$s/e/obs/c4b-result.txt" && ok "c4b: a credential refusal at start leaves the state unmeasured (not corrupt, not lost)" || no "c4b cred refusal: $(head -n 1 "$s/e/obs/c4b-result.txt" 2>/dev/null)"
s=$(c4b_case ready 'echo Ready >"$SIM/phase"')
! grep -q -E '^sandbox (stop|start) ' "$s/cli-calls" && grep -q "phase is 'Ready', not Error" "$s/stops" && ok "c4b: not from Error -> no stop, STOP (not-tested)" || no "c4b ready: $(cat "$s/cli-calls")"
s=$(c4b_case stophang 'echo hang >"$SIM/stop-mode"')
grep -q '^sandbox stop ' "$s/cli-calls" && ! grep -q '^sandbox start ' "$s/cli-calls" && grep -q 'value=not-restartable reason=stop-' "$s/e/obs/c4b-result.txt" \
  && ok "c4b: stop never reaches Stopped within 300 s -> not-restartable, no start, no retry" || no "c4b stophang: $(cat "$s/cli-calls" | grep -E 'stop|start') / $(cat "$s/e/obs/c4b-result.txt" 2>/dev/null)"
[ "$(grep -c '^sandbox stop ' "$s/cli-calls")" = 1 ] && ok "c4b: the stop is not retried" || no "c4b stop retried"
s=$(c4b_case stopfail 'echo fail >"$SIM/stop-mode"')
grep -q 'value=not-restartable reason=stop-refused-rc1' "$s/e/obs/c4b-result.txt" && ! grep -q '^sandbox start ' "$s/cli-calls" && ok "c4b: stop refused (rc 1) -> not-restartable, no start" || no "c4b stopfail"
s=$(c4b_case stoprefusedstopped 'echo refused-stopped >"$SIM/stop-mode"')
grep -q 'value=not-restartable reason=stop-refused-rc1' "$s/e/obs/c4b-result.txt" && ! grep -q '^sandbox start ' "$s/cli-calls" && ok "c4b: stop refused even though the phase became Stopped -> not-restartable, no start" || no "c4b stop refused/stopped: $(cat "$s/e/obs/c4b-result.txt" 2>/dev/null)"
s=$(c4b_case startrefused 'echo refused-ready >"$SIM/start-mode"')
grep -q 'value=not-restartable reason=start-refused-rc1' "$s/e/obs/c4b-result.txt" && [ "$(grep -c '^sandbox start ' "$s/cli-calls")" = 1 ] && ok "c4b: start refused (rc 1) -> not-restartable, not retried" || no "c4b start refused: $(cat "$s/e/obs/c4b-result.txt" 2>/dev/null)"
s=$(c4b_case crnotsuspended 'echo "{\"uid\": \"cr\", \"deletionTimestamp\": null, \"operatingMode\": \"Running\"}" >"$SIM/cr"')
grep -q 'reason=sandbox-CR-not-suspended-while-Stopped' "$s/e/obs/c4b-result.txt" && ! grep -q '^sandbox start ' "$s/cli-calls" && ok "c4b: CR not suspended while Stopped -> not-restartable, no start" || no "c4b cr: $(cat "$s/e/obs/c4b-result.txt" 2>/dev/null)"
s=$(c4b_case podsremain 'echo "{\"items\": [{\"name\": \"x\"}]}" >"$SIM/pods"')
grep -q 'reason=pods-remain-while-Stopped' "$s/e/obs/c4b-result.txt" && ! grep -q '^sandbox start ' "$s/cli-calls" && ok "c4b: pods remain 300 s after Stopped -> not-restartable, no start" || no "c4b pods: $(cat "$s/e/obs/c4b-result.txt" 2>/dev/null)"
s=$(c4b_case vaattached 'touch "$SIM/va-attached"')
grep -q 'reason=volume-attachment-not-released' "$s/e/obs/c4b-result.txt" && ! grep -q '^sandbox start ' "$s/cli-calls" && ok "c4b: VolumeAttachment not released -> not-restartable, no start (no multi-attach risk)" || no "c4b va: $(cat "$s/e/obs/c4b-result.txt" 2>/dev/null)"
s=$(c4b_case starthang 'echo hang >"$SIM/start-mode"')
[ "$(grep -c '^sandbox start ' "$s/cli-calls")" = 1 ] && grep -q 'value=not-restartable reason=start-' "$s/e/obs/c4b-result.txt" && ok "c4b: start never Ready -> not-restartable, start not retried" || no "c4b starthang"
s=$(c4b_case vchanged 'echo "{\"pvc_uid\":\"OTHER\",\"pv\":\"v\",\"pv_uid\":\"vu\",\"volume_handle\":\"h\",\"pvc_deleting\":false,\"pv_deleting\":false,\"va\":[]}" >"$SIM/V"')
! grep -q '^sandbox start ' "$s/cli-calls" && grep -q 'value=lost reason=pvc_uid-changed' "$s/e/obs/c4b-result.txt" && ok "c4b: PVC identity changed while Stopped -> lost, no start" || no "c4b vchanged: $(cat "$s/e/obs/c4b-result.txt" 2>/dev/null)"
s=$(c4b_case pvdeleting 'echo "{\"pvc_uid\":\"p\",\"pv\":\"v\",\"pv_uid\":\"vu\",\"volume_handle\":\"h\",\"pvc_deleting\":true,\"pv_deleting\":false,\"va\":[]}" >"$SIM/V"')
! grep -q '^sandbox start ' "$s/cli-calls" && grep -q 'value=lost reason=volume-deleting' "$s/e/obs/c4b-result.txt" && ok "c4b: PVC being deleted -> lost, no start" || no "c4b pvdeleting"
s=$(c4b_case c4anotended 'echo "step=c4a original_process=inconclusive" >"$E/obs/c4a-result.txt"')
! grep -q -E '^sandbox (stop|start) ' "$s/cli-calls" && grep -q 'value=not-tested reason=c4a-not-ended' "$s/e/obs/c4b-result.txt" && ok "c4b: C4a not ended -> nothing stopped (not-tested)" || no "c4b c4a-not-ended"

# ---------------------------------------------------------------- cleanup: from Stopped, Error and settling phases; residue reported
cl_case() { # cl_case <name> <setup cmds>
  local name=$1 pre=$2
  ( setup "cl-$name"; common; touch "$E/done-c0-create"; echo "x/y.jsonl" >"$E/tr_rel"
    snap() { return 1; }; vread() { return 1; }; ref() { echo 1; }
    eval "$pre"
    . "$T/step-cleanup.sh"; STEP=cleanup
    run_cleanup ) >/dev/null 2>&1
  echo "$T/sim-cl-$name"
}
for ph in Stopped Error Ready; do
  s=$(cl_case "$ph" "echo $ph >\"\$SIM/phase\"")
  [ "$(grep -c '^sandbox delete ' "$s/cli-calls")" = 1 ] && ! grep -q -E '^sandbox (stop|start) ' "$s/cli-calls" && [ -e "$s/e/obs/cleanup-done" ] \
    && ok "cleanup from $ph: one delete, no stop/start, done" || no "cleanup $ph: $(cat "$s/cli-calls") stops=$(cat "$s/stops" 2>/dev/null)"
done
s=$(cl_case starting 'echo Starting >"$SIM/phase"; echo "6 Ready" >"$SIM/phase-after"')
grep -q 'phase_settled=Ready' "$s/e/obs/cleanup-phase.txt" && [ "$(grep -c '^sandbox delete ' "$s/cli-calls")" = 1 ] && ! grep -q -E '^sandbox (stop|start) ' "$s/cli-calls" && ok "cleanup during Starting: waits, then deletes once" || no "cleanup starting"
s=$(cl_case stuck 'echo Provisioning >"$SIM/phase"')
grep -q 'phase_settled=Provisioning' "$s/e/obs/cleanup-phase.txt" && [ "$(grep -c '^sandbox delete ' "$s/cli-calls")" = 1 ] && ok "cleanup when the phase never settles: deletes after 300 s (recorded)" || no "cleanup stuck"
s=$(cl_case settling 'echo Stopping >"$SIM/phase"; echo "6 Stopped" >"$SIM/phase-after"')
grep -q 'phase_at_cleanup=Stopping' "$s/e/obs/cleanup-phase.txt" && grep -q 'phase_settled=Stopped' "$s/e/obs/cleanup-phase.txt" && [ "$(grep -c '^sandbox delete ' "$s/cli-calls")" = 1 ] \
  && ok "cleanup during Stopping: waits for a settled phase, then deletes once" || no "cleanup settling: $(cat "$s/e/obs/cleanup-phase.txt" 2>/dev/null)"
s=$(cl_case residue 'K() { case " $* " in *" -o name"*) echo "pod/default--exp008c4-0101-0101";; *" -o json "*) echo "{\"items\": []}";; esac; }')
grep -q 'experiment objects remain' "$s/stops" && grep -q 'pod/default--exp008c4' "$s/e/obs/cleanup-residue.txt" && [ ! -e "$s/e/obs/cleanup-done" ] \
  && ok "cleanup with residue: STOP, residue listed, not marked done (owner decides)" || no "cleanup residue: $(cat "$s/stops" 2>/dev/null)"
s=$(cl_case nocreate 'rm -f "$E/done-c0-create"')
! grep -q '^sandbox delete ' "$s/cli-calls" && ok "cleanup when create never ran: no delete issued" || no "cleanup nocreate deleted"
# cleanup after a failed or partial create (Correction C): done-c0-create means "a create request was sent"
dl() { grep -c '^sandbox delete ' "$1/cli-calls"; }
disc() { cat "$1/e/obs/cleanup-discovery.txt" 2>/dev/null | tr '\n' ' '; }
s=$(cl_case rejected 'echo absent >"$SIM/phase"; rm -f "$E/sbx_id"')
[ "$(dl "$s")" = 0 ] && grep -q '^discovery=absent reason=none cli_rc=1 cr_total=0 cr_matching=0' "$s/e/obs/cleanup-discovery.txt" && grep -q '^delete=skipped-verified-absent$' "$s/e/obs/cleanup-discovery.txt" && [ -e "$s/e/obs/cleanup-done" ] && [ "$(cat "$s/e/sbx_id")" = none ] \
  && ok "cleanup, create rejected before admission (run 1127-1814): no delete, delete=skipped-verified-absent, residue checked, done" || no "cleanup rejected: $(disc "$s") deletes=$(dl "$s")"
grep -q 'sandbox delete rc=' "$s/tl" && no "cleanup rejected: a deletion was logged" || ok "cleanup, create rejected: no deletion is reported"
s=$(cl_case absent 'echo absent >"$SIM/phase"')
[ "$(dl "$s")" = 0 ] && grep -q '^delete=skipped-verified-absent$' "$s/e/obs/cleanup-discovery.txt" && [ -e "$s/e/obs/cleanup-done" ] && ok "cleanup, sandbox recorded but verified absent: no delete, skipped-verified-absent" || no "cleanup absent: $(disc "$s")"
s=$(cl_case partial 'echo Provisioning >"$SIM/phase"; echo "4 Error" >"$SIM/phase-after"; echo "openshell/default--exp008c4-0101-0101" >"$SIM/crs"')
[ "$(dl "$s")" = 1 ] && grep -q '^discovery=present ' "$s/e/obs/cleanup-discovery.txt" && grep -q '^delete=issued delete_rc=0$' "$s/e/obs/cleanup-discovery.txt" && [ -e "$s/e/obs/cleanup-done" ] \
  && ok "cleanup, create partially succeeded before the CLI failed: discovered present, one guarded delete" || no "cleanup partial: $(disc "$s") deletes=$(dl "$s")"
s=$(cl_case present-noid 'echo Error >"$SIM/phase"; rm -f "$E/sbx_id"; echo "openshell/default--exp008c4-0101-0101" >"$SIM/crs"')
[ "$(dl "$s")" = 1 ] && [ "$(cat "$s/e/sbx_id")" = sid-1 ] && [ -e "$s/e/obs/cleanup-done" ] && ok "cleanup, sandbox present with no recorded id: id taken from discovery, one delete" || no "cleanup present-noid: $(disc "$s")"
s=$(cl_case getfail 'touch "$SIM/get-fail"')
[ "$(dl "$s")" = 0 ] && grep -q 'discovery ambiguous:sandbox-get-failed-rc=1' "$s/stops" && [ ! -e "$s/e/obs/cleanup-done" ] && ok "cleanup, lookup failure: STOP, no delete, absence not assumed" || no "cleanup getfail: $(cat "$s/stops" 2>/dev/null)"
s=$(cl_case crfail 'echo absent >"$SIM/phase"; touch "$SIM/crs-fail"')
[ "$(dl "$s")" = 0 ] && grep -q 'discovery ambiguous:sandbox-cr-list-unreadable' "$s/stops" && [ ! -e "$s/e/obs/cleanup-done" ] && ok "cleanup, Sandbox CR list unreadable: STOP, no delete" || no "cleanup crfail: $(cat "$s/stops" 2>/dev/null)"
s=$(cl_case notfound-cr 'echo absent >"$SIM/phase"; echo "openshell/default--exp008c4-0101-0101" >"$SIM/crs"')
[ "$(dl "$s")" = 0 ] && grep -q 'discovery ambiguous:cli-not-found-but-sandbox-cr-present' "$s/stops" && ok "cleanup, CLI not-found but a Sandbox CR for the run exists: STOP, no delete" || no "cleanup notfound-cr: $(cat "$s/stops" 2>/dev/null)"
s=$(cl_case badjson 'echo "not json" >"$SIM/sbx-json"')
[ "$(dl "$s")" = 0 ] && grep -q 'discovery ambiguous:get-output-not-json' "$s/stops" && ok "cleanup, unparseable sandbox get: STOP, no delete" || no "cleanup badjson: $(cat "$s/stops" 2>/dev/null)"
s=$(cl_case idmismatch 'echo "{\"id\": \"sid-9\", \"name\": \"exp008c4-0101-0101\", \"labels\": {\"exp008.run\": \"0101-0101\", \"exp008.stage\": \"c4\"}, \"phase\": \"Error\"}" >"$SIM/sbx-json"')
[ "$(dl "$s")" = 0 ] && grep -q 'discovery mismatch:id-differs-from-recorded' "$s/stops" && ok "cleanup, sandbox id differs from the recorded one: STOP, no delete" || no "cleanup idmismatch: $(cat "$s/stops" 2>/dev/null)"
s=$(cl_case labelmismatch 'echo "{\"id\": \"sid-1\", \"name\": \"exp008c4-0101-0101\", \"labels\": {\"exp008.run\": \"0202-0202\", \"exp008.stage\": \"c4\"}, \"phase\": \"Error\"}" >"$SIM/sbx-json"')
[ "$(dl "$s")" = 0 ] && grep -q 'discovery mismatch:labels' "$s/stops" && ok "cleanup, run label mismatch: STOP, no delete" || no "cleanup labelmismatch: $(cat "$s/stops" 2>/dev/null)"
s=$(cl_case namemismatch 'echo "{\"id\": \"sid-1\", \"name\": \"other\", \"labels\": {\"exp008.run\": \"0101-0101\", \"exp008.stage\": \"c4\"}, \"phase\": \"Error\"}" >"$SIM/sbx-json"')
[ "$(dl "$s")" = 0 ] && grep -q 'discovery mismatch:name' "$s/stops" && ok "cleanup, name mismatch: STOP, no delete" || no "cleanup namemismatch: $(cat "$s/stops" 2>/dev/null)"
s=$(cl_case nocreate2 'rm -f "$E/done-c0-create"')
grep -q '^discovery=not-run reason=no-create-request' "$s/e/obs/cleanup-discovery.txt" && grep -q '^delete=not-issued-no-create$' "$s/e/obs/cleanup-discovery.txt" && ! grep -q '^sandbox get ' "$s/cli-calls" && ok "cleanup, no create request: no discovery call, delete=not-issued-no-create" || no "cleanup nocreate2: $(disc "$s")"
( setup cl-twice; common; touch "$E/done-cleanup"; . "$T/step-cleanup.sh"; STEP=cleanup; run_cleanup ) >/dev/null 2>&1; [ $? = 4 ] && ok "cleanup is single-attempt" || no "cleanup ran twice"

# ---------------------------------------------------------------- spend_check after M9 (review blocker B1): the real function
sc_case() { # sc_case <name> <setup>: runs the REAL spend_check with the transcript unreadable; prints rc
  ( setup "sc-$1"; common; . "$T/lib.sh"; CLI=$T/cli OENV=(env SIM="$SIM") KC=("$T/kubectl")
    log() { :; }; stop() { echo "STOP: $*" >>"$SIM/stops"; exit 3; }; kx() { return 1; }
    touch "$E/done-c0-create"; echo "x/00000000-0000-0000-0000-000000000000.jsonl" >"$E/tr_rel"; STEP=c4b BUDGET_USD=2
    eval "$2"; spend_check ) >/dev/null 2>&1; echo $?
}
[ "$(sc_case before-m9 'echo Ready >"$SIM/phase"')" = 3 ] && ok "spend_check: unreadable transcript before M9 -> STOP" || no "spend_check before M9"
[ "$(sc_case after-m9-error 'echo Error >"$SIM/phase"; touch "$E/obs/c4a-m9-issued"')" = 0 ] && ok "spend_check: after M9 with the sandbox in Error -> recorded, no STOP (c4b reachable)" || no "spend_check after M9 (Error) stopped"
[ "$(sc_case after-m9-stopped 'echo Stopped >"$SIM/phase"; touch "$E/obs/c4a-m9-issued"')" = 0 ] && ok "spend_check: while Stopped -> recorded, no STOP" || no "spend_check Stopped"
[ "$(sc_case after-m9-ready 'echo Ready >"$SIM/phase"; touch "$E/obs/c4a-m9-issued"')" = 3 ] && ok "spend_check: Ready but transcript unreadable -> STOP (agent may be spending)" || no "spend_check Ready unreadable"
[ "$(sc_case after-m9-nophase ': >"$SIM/phase"; touch "$E/obs/c4a-m9-issued"')" = 3 ] && ok "spend_check: phase unreadable -> STOP (fails closed)" || no "spend_check empty phase"
grep -q 'usage=workload-not-running phase=Error' "$T/sim-sc-after-m9-error/e/obs/spend.txt" && ok "spend_check: the skipped check is logged" || no "spend_check log"

# ---------------------------------------------------------------- sampler stops itself after a successful cleanup
( setup samp; common; echo $((CLK - 130000)) >"$E/obs/cleanup-done"; sampler_done ) && ok "sampler_done: true 120 s after cleanup-done" || no "sampler_done"
( setup samp2; common; sampler_done ) && no "sampler_done true without cleanup" || ok "sampler_done: false before cleanup"
grep -q 'if sampler_done; then' "$T/lib.sh" && grep -q 'touch "$E/sampler.stop"' "$T/lib.sh" && ok "the sampler loop stops itself via sampler_done" || no "sampler self-stop missing"
echo "failures=$fails"; [ "$fails" = 0 ]
