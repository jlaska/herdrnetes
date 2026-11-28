#!/usr/bin/env bash
# EXP-008 Stage C4 Phase 1 harness: workload loss (C4a), retained state across native `sandbox stop` /
# `sandbox start` (C4b-N) and native Claude Code resume (C4c), for ONE OpenShell 0.1.9 Kubernetes-driver
# sandbox with its default per-sandbox PVC, on the EXISTING Stage B installation.
# Design: STAGE-C4-PROPOSAL.md (PR #48, f19de00). Procedure, tests and readiness: README.md here.
# Derived from ../stage-c/stagec.sh (C0-C3; unchanged): C0 is reused with the C4 package, the corrected H4
# predicate and the control line; C1-C3 and every gateway mutation are removed. Nothing here is authorized
# until the owner approves an execution package; preparation and offline tests do not touch the cluster.
#
#   stagec4.sh <RUN> <step> [arg]
#   steps (the lead runs them by hand, in this order, and decides between them):
#     pre            read-only: refs, guards, Argo Synced/Healthy, digests, provider present (names only), inventory
#     sampler-start  read-only background samplers (pods, CR, events, sandbox get, P, task, V: PVC/PV/VolumeAttachment)
#     c0-create      M1   create the sandbox (provider attached, fixed image digest, C4 package, never --no-keep)
#     c0-baseline    X*   identity, credential-boundary checks, egress probes (M8), first attach (M2) + control line (M3), M; detach (M4b)
#     c4a            M9   gate; complete reference snapshot R; delete the workload pod --grace-period=1; observe 120 s
#     c4b            M10/M11  sandbox stop (once) from Error; retained-state checks; sandbox start (once); resume precheck vs R
#     c4c            M2/M3/M4b  observe without input; attach; probe; at most one "Continue the task."; classify
#     cleanup        M6   stop clients, delete the sandbox from whatever phase it settled in, residue check
#     post           read-only post-run inventory + diff against pre (only providers/profiles may differ)
#     sampler-stop | logout (M7) | ident <label> | snap <label> | spend | vread <label>
#
# Single attempt: every mutating step writes done-<step> before its first mutation and refuses to run twice;
# M9, M10 and M11 each carry their own once-only marker. After a STOP (exit 3) no experiment step runs; only the
# stop path does: cleanup (once), post (read-only), sampler-stop and logout (M7, the CLI session). A FAIL (exit 4)
# is a harness precondition failure. No step retries a mutation; c4a waits for a suitable in-flight step (a
# gate) but takes the reference snapshot once and STOPs if it is incomplete or late.
#
# MUTATION ALLOWLIST (complete; everything else is refused by the wrappers; each is also bound to its step):
#   M1  openshell sandbox create --name $SBX <exactly CREATE> -- <exactly LAUNCH>                c0-create
#       (only after launch_check passed: every element <= 32,768 bytes, payload <= 24,576 bytes, shape, decode)
#   M2  openshell sandbox connect $SBX, run by the harness inside its own local tmux server     c0-baseline, c4c
#   M3  typing one fixed-form line (+Enter) into that harness-owned tmux pane (c4c: at most 2)   c0-baseline, c4c
#   M3b Ctrl-L (Claude Code's documented full redraw; keeps input) only if the resize redraw was not coherent
#   M4b Ctrl-P Ctrl-Q (clean detach) into that pane; SIGKILL of the harness's own client tree after 10 s
#   (local only: tmux resize-window for the redraw check, and tmux kill-server of the harness's own server in cleanup)
#   M6  openshell sandbox delete $SBX                                                            cleanup
#   M7  openshell gateway logout $GWNAME (isolated local CLI config)                            logout
#   M8  openshell sandbox exec $SBX --no-tty --no-login-shell --timeout 60 -- python3 -I -c <X5PY>  c0-baseline
#   M9  kubectl -n openshell delete pod <THIS sandbox's recorded workload pod, UID re-checked> --grace-period=1 --wait=false
#       c4a only, only after a complete reference snapshot (obs/c4a-armed), once. Never --force / --grace-period=0.
#   M10 openshell sandbox stop $SBX                                                              c4b, once, from Error
#   M11 openshell sandbox start $SBX                                                             c4b, once, after Stopped
# No gateway scale, restart or configuration change; no PVC, label, driver config, provider, profile or credential
# operation. kubectl exec: only into THIS sandbox's CURRENT workload pod (labels AND UID re-checked), only the
# fixed read-only scripts X1-X10 below. The OpenShell provider, the Console key, profile import, OIDC login and
# the GitOps freeze are OWNER steps; this harness never creates, reads or deletes a credential.
set -uo pipefail
[ "$#" -ge 2 ] || { echo "usage: stagec4.sh <RUN> <step> [arg]" >&2; exit 2; }
RUN=$1 STEP=$2 ARG=${3:-}
[[ $RUN =~ ^[0-9]{4}-[0-9]{4}$ ]] || { echo "bad RUN (MMDD-HHMM)" >&2; exit 2; }
[[ $ARG =~ ^[A-Za-z0-9_-]{0,32}$ ]] || { echo "bad arg" >&2; exit 2; }

HX=$HOME/.cache/hxc
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
C0=$HERE/../stage-c # reused, unchanged: metrics.py (m, prefix, usage, screen, rawmode, ledger), restore-check.sh, export.sh
# shellcheck source=/dev/null
. "$HX/site.env" || { echo "missing $HX/site.env" >&2; exit 2; } # CTX, ARGO_APP_GW, ARGO_APP_AS, GITOPS_REPO, PROV, BUDGET_USD, PIN_*
for v in CTX ARGO_APP_GW ARGO_APP_AS GITOPS_REPO PROV BUDGET_USD PIN_KUBE_SYSTEM_UID PIN_GW_STS_UID PIN_GW_PVC_UID; do [ -n "${!v:-}" ] || { echo "site.env: $v unset" >&2; exit 2; }; done
[[ $PROV =~ ^exp008c-[a-z0-9-]{1,20}$ ]] || { echo "PROV must be exp008c-*" >&2; exit 2; }
[[ $BUDGET_USD =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "BUDGET_USD must be a number" >&2; exit 2; }
NS=openshell
GW_STS=openshell
GW_POD=openshell-0
GW_PVC=openshell-data-openshell-0
GWNAME=exp008c # isolated CLI registration name (owner-run login-c.sh)
SBX=exp008c4-${RUN} # the ONLY sandbox this harness may create/stop/start/delete
# Published EXP-006 agent image (Claude Code 2.1.323, sha256-verified at build); no rebuild.
IMG=ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18
GW_DIGEST=sha256:1fd9e1e807990e66c9486a28d3ce9d649fd7528df48d0e830d2de2148b52dfe5
CTRL_DIGEST=sha256:b0ee91a42129919179baf5f429979fee3ab1a3dac6855110b4648a6ff4b44103
CLI_SHA=2db8e54f63feebe9f994efaf6004bbd45c55bc70ea455eda42fe82a0ea7c7e69
CLI=$HX/bin/openshell
R=$HX/run/$RUN
E=$R/e   # evidence candidates (derived; redaction-scanned before any commit)
L=$R/raw # raw local-only material: transcripts, screen captures, PTY logs, container logs, codeword
TL=$E/timeline.log
PROF=claude-code-exp008c # the imported provider profile (../stage-c/task/profile-claude-code-exp008c.yaml)
WALL_MAX=3600       # 60 min from c0-create (proposal 10)
START_MAX=1200      # 20 min after M11 (proposal 5.3 caps)
SETTLE_MAX=300      # stop -> Stopped, start -> Ready, VolumeAttachment release, cleanup settle
STEP_SLEEP=45       # the approved pacing; every attempt line must record sleep=45
GATE_MIN_DONE=6 GATE_MAX_DONE=100
R_AGE_MIN=3000 R_AGE_MAX=12000 KILL_AGE_MAX=30000 # step N in flight: R starts at 3-12 s, re-check <= 30 s (sleep 45 s)
KILL_DEADLINE_AGE=38000 # M9 is refused once the in-flight step could be older than 38 s (7 s before its done)
INPUT_MAX=2 REFUSAL_MAX=10
FREEZE_END_LOCAL=30 # 00:30 America/New_York; Renovate's automerge window opens at 01:00
export TZ=America/New_York
KUBECTL_DIR=$HOME/.local/share/mise/installs/kubectl/1.36.5
GH=$(ls -d "$HOME"/.local/share/mise/installs/gh/*/gh_*/bin/gh 2>/dev/null | sort -V | tail -n 1)
PATH=$KUBECTL_DIR:/usr/bin:/bin
export PATH
for b in "$KUBECTL_DIR/kubectl" "$GH" /usr/bin/jq /usr/bin/python3 /usr/bin/tmux; do [ -x "$b" ] || { echo "missing $b" >&2; exit 2; }; done
KC=("$KUBECTL_DIR/kubectl" --context "$CTX")
# shellcheck source=launcher4.sh
. "$HERE/launcher4.sh"
TM=(/usr/bin/tmux -L "exp008c4-$RUN" -f /dev/null)
M4=("python3" "-I" "$HERE/metrics4.py")
M0=("python3" "-I" "$C0/metrics.py")

umask 077
# a run directory belongs to one harness: never reuse a C0-C3 run directory (or the reverse)
if [ -e "$R" ] && [ "$(cat "$R/stage" 2>/dev/null)" != c4 ]; then echo "$R exists and is not a C4 run directory" >&2; exit 2; fi
mkdir -p "$HX/run" && mkdir -p -m 700 "$R" "$E" "$E/obs" "$E/inv" "$E/term" "$E/metrics" "$L" "$L/tr" "$L/term" "$L/logs" "$L/task"
[ -e "$R/stage" ] || echo c4 >"$R/stage"
for d in "$HX" "$R" "$L"; do [ "$(stat -c %a "$d")" = 700 ] || { echo "$d must be 0700" >&2; exit 2; }; done
[ "$(sha256sum "$CLI" | cut -d' ' -f1)" = "$CLI_SHA" ] || { echo "CLI sha256 mismatch" >&2; exit 2; }
# The harness environment must not carry credentials the CLI could upload (Stage C proposal 5.1 MUST-2/3).
env | grep -q -E '^(ANTHROPIC_|OPENAI_|CLAUDE_|GH_|GITHUB_TOKEN|SSH_AUTH_SOCK)' && { echo "refusing: credential-like variable in the harness environment" >&2; exit 2; }

now() { date -u +%FT%T.%3NZ; }
ems() { date +%s%3N; }
log() { printf '%s [%s] %s\n' "$(now)" "$STEP" "$*" | tee -a "$TL" >&2; }
stop() { log "STOP: $*"; echo "$(now) $STEP: $*" >>"$E/STOPPED"; exit 3; }
fail() { log "FAIL: $*"; exit 4; }
nz() { [ -n "${1:-}" ]; }
once() { # once <step>: single attempt; refuse after any STOP
  [ ! -e "$E/STOPPED" ] || fail "a previous step stopped: $(cat "$E/STOPPED")"
  [ ! -e "$E/done-$1" ] || fail "$1 already ran (single attempt)"
  echo "$(now)" >"$E/done-$1"
}
put1() { [ ! -e "$1" ] || fail "write-once file exists: $1"; printf '%s\n' "$2" >"$1"; } # never overwrite a timestamp
need() { [ -e "$E/obs/$1-done" ] || fail "$1 not done"; }

# ---------------------------------------------------------------- kubectl, read-only
K() { # options before the verb are limited to -n <ns> / -A; the verb must be get|logs|version|wait
  local a=("$@") i=0
  while [ "$i" -lt "${#a[@]}" ]; do
    case ${a[$i]} in -n) i=$((i + 2)) ;; -A) i=$((i + 1)) ;; *) break ;; esac
  done
  case ${a[$i]:-} in get | logs | version | wait) ;;
  *) log "REFUSED K $*"; return 97 ;;
  esac
  "${KC[@]}" --request-timeout=15s "$@"
}
kw() { # kubectl, mutating: exactly M9, in c4a, once, after a complete R, against the recorded workload pod (UID re-checked)
  local f="$*" w; w=$(WPOD)
  case $f in
  "delete pod $w --grace-period=1 --wait=false")
    nz "$w" || { log "REFUSED kw (no recorded workload pod): $f"; return 97; }
    [ "$STEP" = c4a ] && [ -e "$E/obs/c4a-armed" ] || { log "REFUSED kw (not armed by a complete reference snapshot): $f"; return 97; }
    [ ! -e "$E/obs/c4a-m9-issued" ] || { log "REFUSED kw (M9 already issued): $f"; return 97; }
    [ -s "$E/obs/c4a-kill-deadline" ] && [ "$(ems)" -le "$(cat "$E/obs/c4a-kill-deadline")" ] || { log "REFUSED kw (past the M9 deadline: step N may have finished): $f"; return 97; }
    wpod_ok || { log "REFUSED kw (workload pod labels or UID differ from the recorded ones): $f"; return 97; }
    guard_ctx || stop "kube identity guard failed before: $f" ;;
  *) log "REFUSED kw $f"; return 97 ;;
  esac
  log "MUTATE kubectl -n $NS $f (uid $(cat "$E/wuid"))"
  echo "$(ems)" >"$E/obs/c4a-m9-issued"
  "${KC[@]}" --request-timeout=20s -n "$NS" "$@"
}

# ---------------------------------------------------------------- exec: fixed read-only scripts, this workload only
# X1-X7 are the C0-C3 scripts, unchanged. X8-X10 are C4 additions (counts, hashes and fixed records only).
X1='cat /sandbox/c/launch/identity 2>/dev/null; echo boot_id=$(cat /proc/sys/kernel/random/boot_id); echo uid=$(id -u); for p in /proc/[0-9]*; do q=${p#/proc/}; [ "$q" = "$$" ] && continue; x=$(readlink $p/exe 2>/dev/null); case "$x" in /usr/local/bin/cla''ude) f() { case "$1" in "") echo absent;; openshell:resolve:*) echo placeholder;; sk-ant-*) echo REAL-KEY-SHAPE;; *) echo other;; esac; }; ev() { tr "\0" "\n" <$p/environ 2>/dev/null | sed -n "s/^$1=//p"; }; n=$(ev EXP008_NONCE); echo "proc=$q start=$(sed "s/.*) //" $p/stat | awk "{print \$20}") ppid=$(awk "/^PPid/{print \$2}" $p/status) nonce=${n:-unreadable} keyref_form=$(f "$(ev EXP008_ANTHROPIC_KEYREF)") key_form=$(f "$(ev ANTHROPIC_API_KEY)")";; esac; done'
X2='cd /sandbox/c/repo 2>/dev/null || exit 9; for f in attempts progress refusals ledger locks; do echo "$f=$(wc -l <$f.log 2>/dev/null || echo 0) last=$(tail -n 1 $f.log 2>/dev/null)"; done; t=$(ls /sandbox/c/claude/projects/*/*.jsonl 2>/dev/null); echo transcripts=$(echo "$t" | grep -c .); for x in $t; do echo "tr=$(basename $x) lines=$(wc -l <$x) bytes=$(wc -c <$x)"; done; echo lock=$(test -d .state/lock && echo held || echo free)'
X3_LOGS='cd /sandbox/c/repo && tar -cf - $(ls attempts.log progress.log refusals.log ledger.log locks.log 2>/dev/null)'
X3_TR='cat /sandbox/c/claude/projects/'
X4='r=0; u=0; for p in /proc/[0-9]*/environ; do if tr "\0" "\n" <$p >/dev/null 2>&1; then r=$((r+1)); else u=$((u+1)); fi; done; echo "environ_readable=$r environ_unreadable=$u"; for p in /proc/[0-9]*/environ; do tr "\0" "\n" <$p 2>/dev/null | grep -c -E "^[A-Z_]+=sk-ant-" ; done | awk "{s+=\$1} END {print \"env_real_key_shape=\" s+0}"; echo "fs_real_key_shape_files=$(grep -r -l -I -E "sk-ant-(api|admin)[0-9]{2}-" /sandbox 2>/dev/null | wc -l)"; echo "fs_placeholder_files=$(grep -r -l -I -F "openshell:resolve:" /sandbox 2>/dev/null | wc -l)"'
X5PY='import os,socket
k=os.environ.get("ANTHROPIC_API_KEY","")
print("probe_key_form="+("absent" if not k else "placeholder" if k.startswith("openshell:resolve:") else "REAL-KEY-SHAPE" if k.startswith("sk-ant-") else "other"))
for n,h in (("disallowed_host","example.com"),("anthropic_from_python","api.anthropic.com")):
    try:
        s=socket.create_connection((h,443),timeout=15); s.close(); print(n+"=connected")
    except Exception as e:
        print(n+"=blocked:"+type(e).__name__+":"+str(getattr(e,"errno","")))'
X5="python3 -I -c '$X5PY'"
X6='date +%s%3N'
X7='ls -d /sandbox/c/claude/projects/*/ | head -n 1'
# X8 in-flight timing and state identity (workload clock; hashes only; the token itself is never read)
X8='cd /sandbox/c/repo 2>/dev/null || exit 9; echo now_ms=$(date +%s%3N); echo "last_attempt=$(tail -n 1 attempts.log 2>/dev/null)"; echo "last_done=$(tail -n 1 progress.log 2>/dev/null)"; echo "attempts=$(wc -l <attempts.log 2>/dev/null || echo 0) done=$(wc -l <progress.log 2>/dev/null || echo 0)"; echo lock=$(test -d .state/lock && echo held || echo free); echo "token_file_sha256=$(sha256sum .state/next-token.sha256 2>/dev/null | cut -d" " -f1)"; echo "state_id_sha256=$(sha256sum /sandbox/c/state-id 2>/dev/null | cut -d" " -f1)"; echo "sid=$(cat /sandbox/c/launch/sid 2>/dev/null)"'
# X9 the launcher's fixed records (identity-*, precheck-*, refusals): forms, hashes, counts, names
X9='cd /sandbox/c/launch 2>/dev/null || exit 9; for f in identity-* precheck-* refusals; do [ -f "$f" ] && { echo "## $f"; cat "$f"; }; done; echo "## ls"; ls'
# X10 the resume launcher's frozen copy of the state (taken before Claude Code started; to $L only)
X10='cd /sandbox/c/launch/pre-2 && tar -cf - .'
WPOD() { cat "$E/wpod" 2>/dev/null; }
wpod_ok() { # the recorded pod still carries THIS sandbox's workload labels AND the recorded UID (never a replacement)
  local w r; w=$(WPOD); nz "$w" || return 1
  r=$(K -n "$NS" get pod "$w" -o jsonpath='{.metadata.labels.openshell\.ai/boundary-pair} {.metadata.labels.openshell\.ai/boundary-role} {.metadata.uid}' 2>/dev/null) || return 1
  [ "$r" = "$(cat "$E/sbx_id") workload $(cat "$E/wuid" 2>/dev/null)" ]
}
kx() { # kx <X1|X2|X3L|X3T|X4|X5|X6|X7|X8|X9|X10> <outfile> [timeout]
  local w c s; w=$(WPOD) c=$(cat "$E/wctr" 2>/dev/null); nz "$w" && nz "$c" || return 1
  wpod_ok || { echo "workload pod labels/UID do not match this sandbox's recorded workload" >"$2.err"; return 1; }
  case $1 in X1) s=$X1 ;; X2) s=$X2 ;; X3L) s=$X3_LOGS ;; X3T) local r; r=$(cat "$E/tr_rel" 2>/dev/null); [[ $r =~ ^[A-Za-z0-9._-]{1,200}/[0-9a-f-]{36}\.jsonl$ ]] || { echo "bad transcript path" >"$2.err"; return 1; }; s="$X3_TR$r" ;; X4) s=$X4 ;; X5) s=$X5 ;; X6) s=$X6 ;; X7) s=$X7 ;; X8) s=$X8 ;; X9) s=$X9 ;; X10) s=$X10 ;; *) log "REFUSED kx $1"; return 97 ;; esac
  "${KC[@]}" --request-timeout="${3:-20}s" -n "$NS" exec "$w" -c "$c" -- sh -c "$s" >"$2" 2>"$2.err"
}
clock() { # clock <label>: skew = workload - workstation (ms), unc = half the round trip
  local a b r; a=$(ems); kx X6 "$E/obs/$1-clock.raw" 10 || return 1; b=$(ems); r=$(tr -dc 0-9 <"$E/obs/$1-clock.raw")
  nz "$r" || return 1
  echo "skew_ms=$((r - (a + b) / 2)) unc_ms=$(((b - a) / 2))" | tee "$E/obs/$1-clock.txt"
}

# ---------------------------------------------------------------- CLI (isolated HOME; explicit -g; no credentials)
OENV=(env -i HOME="$HX/home" XDG_CONFIG_HOME="$HX/home/.config" XDG_DATA_HOME="$HX/home/.local/share"
  XDG_STATE_HOME="$HX/home/.local/state" XDG_CACHE_HOME="$HX/home/.cache" PATH=/usr/bin:/bin TERM=xterm-256color)
O() {
  local sub="$1 ${2:-}"
  case $sub in
  "sandbox get" | "sandbox list" | "gateway list") ;;
  "provider list") [ "$*" = "provider list --names" ] || { log "REFUSED O $*"; return 97; } ;;
  "profile list") [ "$#" -eq 2 ] || { log "REFUSED O $*"; return 97; } ;;
  "sandbox exec") [ "$STEP" = c0-baseline ] && [ "$#" -eq 12 ] && [ "$3" = "$SBX" ] && [ "${*:4:7}" = "--no-tty --no-login-shell --timeout 60 -- python3 -I" ] && [ "${11}" = -c ] && [ "${12}" = "$X5PY" ] || { log "REFUSED O sandbox exec"; return 97; } ;;
  "sandbox create")
    [ "$STEP" = c0-create ] && [ "${3:-}" = --name ] && [ "${4:-}" = "$SBX" ] && [ "${*:5}" = "${CREATE[*]} -- ${LAUNCH[*]}" ] || { log "REFUSED O sandbox create (not the exact M1 argv)"; return 97; }
    grep -q '^launch_check=pass ' "$E/obs/c0-launch-result.txt" 2>/dev/null || { log "REFUSED O sandbox create (launch_check did not pass)"; return 97; }
    local y; for y in "$@"; do [ "$(printf %s "$y" | LC_ALL=C wc -c)" -le "$ARG_ELEM_MAX" ] || { log "REFUSED O sandbox create (an argument exceeds $ARG_ELEM_MAX bytes)"; return 97; }; done
    [ "$(printf %s "${LAUNCH[3]:-}" | LC_ALL=C wc -c)" -le "$PAYLOAD_BUDGET" ] || { log "REFUSED O sandbox create (payload over the $PAYLOAD_BUDGET-byte budget)"; return 97; }
    local x; for x in "$@"; do case $x in --no-keep | --keep | --driver-config* | --upload* | --workspace* | --editor* | --forward* | --expose* | --restart-policy=*) log "REFUSED O sandbox create ($x)"; return 97 ;; esac; done ;;
  "sandbox delete") [ "$STEP" = cleanup ] && [ "${3:-}" = "$SBX" ] && [ "$#" -eq 3 ] || { log "REFUSED O $*"; return 97; } ;;
  "sandbox stop") # M10: c4b, once
    [ "$STEP" = c4b ] && [ "$#" -eq 3 ] && [ "$3" = "$SBX" ] && [ ! -e "$E/done-m10" ] || { log "REFUSED O $*"; return 97; }
    echo "$(now)" >"$E/done-m10" ;;
  "sandbox start") # M11: c4b, once, only after M10
    [ "$STEP" = c4b ] && [ "$#" -eq 3 ] && [ "$3" = "$SBX" ] && [ -e "$E/done-m10" ] && [ ! -e "$E/done-m11" ] || { log "REFUSED O $*"; return 97; }
    echo "$(now)" >"$E/done-m11" ;;
  "gateway logout") [ "$STEP" = logout ] && [ "${3:-}" = "$GWNAME" ] && [ "$#" -eq 3 ] || { log "REFUSED O $*"; return 97; } ;;
  *) log "REFUSED O $*"; return 97 ;;
  esac
  case $sub in "sandbox create" | "sandbox delete" | "sandbox stop" | "sandbox start" | "gateway logout" | "sandbox exec") log "MUTATE openshell ${*:1:4}" ;; esac
  "${OENV[@]}" timeout -k 5 "${OT:-60}" "$CLI" -g "$GWNAME" "$@"
}
gw_registered() { O gateway list 2>/dev/null | grep -q -w "$GWNAME"; }
sbx_json() { OT=${OT:-20} O sandbox get "$SBX" -o json >"$1" 2>"$1.err"; }
sbx_phase() { jq -r '[.phase, .status.phase, .sandbox.phase, .sandbox.status.phase] | map(select(. != null)) | .[0] // empty' "$1" 2>/dev/null; }
phase_now() { OT=10 sbx_json "$E/obs/phase.json" && sbx_phase "$E/obs/phase.json"; }
sbx_discover() { # read-only, cleanup: does THIS run's sandbox exist? prints present | absent | ambiguous:<why> | mismatch:<why>
  # done-c0-create means a create request was SENT, not that a sandbox exists. Absence is concluded only from an explicit
  # CLI not-found AND a readable Sandbox CR list with no CR for $SBX; every other outcome is reported, never assumed.
  local f=$E/obs/cleanup-sbx.json rc crs mine=0 want r n id lr ls
  OT=20 O sandbox get "$SBX" -o json >"$f" 2>"$f.err"; rc=$?
  want=$(cat "$E/sbx_id" 2>/dev/null)
  if ! crs=$(sandboxes_all 2>/dev/null); then r=ambiguous:sandbox-cr-list-unreadable; crs=""
  else
    mine=$(grep -c -F -e "$SBX" <<<"$crs" || true)
    if [ "$rc" = 0 ]; then
      if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then r=ambiguous:get-output-not-json
      else
        n=$(jq -r '.name // empty' "$f") id=$(jq -r '.id // empty' "$f") lr=$(jq -r '.labels["exp008.run"] // empty' "$f") ls=$(jq -r '.labels["exp008.stage"] // empty' "$f")
        if [ "$n" != "$SBX" ]; then r=mismatch:name
        elif [ "$lr" != "$RUN" ] || [ "$ls" != c4 ]; then r=mismatch:labels
        elif [ -z "$id" ]; then r=mismatch:no-id
        elif [ -n "$want" ] && [ "$want" != none ] && [ "$want" != "$id" ]; then r=mismatch:id-differs-from-recorded
        else r=present; fi
      fi
    elif grep -q 'sandbox not found' "$f.err" 2>/dev/null; then
      [ "$mine" = 0 ] && r=absent || r=ambiguous:cli-not-found-but-sandbox-cr-present
    else r=ambiguous:sandbox-get-failed-rc=$rc; fi
  fi
  echo "discovery=${r%%:*} reason=$([ "${r#*:}" != "$r" ] && echo "${r#*:}" || echo none) cli_rc=$rc cr_total=$(grep -c . <<<"$crs" || true) cr_matching=$mine" >"$E/obs/cleanup-discovery.txt"
  echo "$r"
}

# ---------------------------------------------------------------- guards
ref() { sed -n "s/^$1=//p" "$E/refs.txt" 2>/dev/null; }
guard_ctx() {
  local v
  v=$(K get namespace kube-system -o jsonpath='{.metadata.uid}') && nz "$v" && [ "$v" = "$(ref kube_system_uid)" ] || return 1
  v=$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.metadata.uid}') && nz "$v" && [ "$v" = "$(ref gw_sts_uid)" ] || return 1
  v=$(K -n "$NS" get pvc "$GW_PVC" -o jsonpath='{.metadata.uid}') && nz "$v" && [ "$v" = "$(ref gw_pvc_uid)" ] || return 1
}
argo_state() { local a; for a in "$ARGO_APP_GW" "$ARGO_APP_AS"; do K -n argo-system get applications.argoproj.io "$a" -o jsonpath='{.metadata.name} {.status.sync.status} {.status.health.status} {.status.sync.revision} {.status.operationState.phase} {.status.operationState.startedAt}{"\n"}' || return 1; done; }
argo_healthy() { awk '$2 != "Synced" || $3 != "Healthy" {bad=1} END {exit bad}' <<<"$1"; }
gitops_sha() { env -u SSH_AUTH_SOCK "$GH" api "repos/$GITOPS_REPO/commits/main" --jq .sha 2>/dev/null; }
sandboxes_all() { K get sandboxes.agents.x-k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'; }
providers() { # names, sorted; a CLI failure prints an ERROR marker (never an empty-looking list) and returns 1
  local o; o=$(OT=30 O provider list --names 2>/dev/null) || { echo "ERROR provider-list-failed"; return 1; }
  sort <<<"$o"
}
profiles() { # profile table rows without the header; "No profiles found." becomes empty; failure -> ERROR marker
  local o; o=$(OT=30 O profile list 2>/dev/null) || { echo "ERROR profile-list-failed"; return 1; }
  awk 'NR == 1 && $1 == "NAME" {next} $0 == "No profiles found." {next} {print}' <<<"$o"
}
spend_check() { # as C0-C3; every outcome is appended to obs/spend.txt; a STOP here sets obs/spend-stopped
  [ -e "$E/done-c0-create" ] || return 0 # no model activity yet
  if [ ! -s "$E/tr_rel" ]; then
    [ "$STEP" = c0-baseline ] && [ ! -e "$E/obs/c0-baseline-done" ] && { echo "$(now) step=$STEP usage=not-yet-locatable" >>"$E/obs/spend.txt"; return 0; }
    sstop "spend: model activity began but the transcript is not located (usage unobtainable)"
  fi
  # After M9 the workload is gone by design (and after a refused relaunch it has exited): while the sandbox is
  # not Ready there is no agent process that could spend, so an unreadable transcript is recorded, not a STOP.
  # A Ready sandbox whose transcript cannot be read still STOPs (usage unobtainable while the agent may spend).
  if ! kx X3T "$L/tr/spend.jsonl" 30; then
    local ph; ph=$(phase_now)
    # an unreadable (empty) phase fails closed: only a phase read as not Ready skips the check
    if [ -e "$E/obs/c4a-m9-issued" ] && [ -n "$ph" ] && [ "$ph" != Ready ]; then echo "$(now) step=$STEP usage=workload-not-running phase=${ph:-unreadable}" >>"$E/obs/spend.txt"; return 0; fi
    sstop "spend: transcript copy failed after model activity began (usage unobtainable)"
  fi
  "${M0[@]}" usage "$L/tr/spend.jsonl" >"$E/metrics/spend-latest.json" 2>"$L/spend-metrics.err" \
    && jq -e '.est_usd | numbers' "$E/metrics/spend-latest.json" >/dev/null || sstop "spend: usage calculation failed"
  local u prev rel
  u=$(printf '%.8f' "$(jq -r .est_usd "$E/metrics/spend-latest.json")"); rel=$(jq -r '.reliable and .messages >= 1' "$E/metrics/spend-latest.json")
  prev=$(sed -n 's/.* est_usd=\([0-9.]*\) .*/\1/p' "$E/obs/spend.txt" 2>/dev/null | tail -n 1)
  echo "$(now) step=$STEP est_usd=$u budget=$BUDGET_USD reliable=$rel msgs=$(jq -r .messages "$E/metrics/spend-latest.json") long_ctx=$(jq -r .long_context_messages "$E/metrics/spend-latest.json") reasons=$(jq -r '.unreliable_reasons | join(",")' "$E/metrics/spend-latest.json") (transcript estimate; Console cap is authoritative)" >>"$E/obs/spend.txt"
  [ "$rel" = true ] || sstop "spend: usage not reliably calculable ($(jq -r '.unreliable_reasons | join(",")' "$E/metrics/spend-latest.json"); messages=$(jq -r .messages "$E/metrics/spend-latest.json"))"
  if [ -n "$prev" ] && awk -v u="$u" -v p="$prev" 'BEGIN {exit !(u + 0.00005 < p)}'; then sstop "spend: estimate decreased ($prev -> $u): transcript replaced or truncated"; fi
  awk -v u="$u" -v b="$BUDGET_USD" 'BEGIN {exit !(u >= 0.8 * b)}' && sstop "spend estimate $u >= 80% of $BUDGET_USD (run cleanup now)"
  return 0
}
sstop() { echo "$(now) $*" >>"$E/obs/spend-stopped"; stop "$@"; }
guard_full() { # stop conditions checked at every step boundary (and inside the long C4 loops)
  guard_ctx || stop "cluster/gateway identity guard mismatch"
  local t a s o
  t=$((10#$(date +%H%M)))
  [ "$t" -ge "$FREEZE_END_LOCAL" ] && [ "$t" -lt 700 ] && stop "freeze window: inside/near the Renovate automerge window (local $t)"
  a=$(argo_state) && nz "$a" || stop "Argo state unreadable"
  [ "$a" = "$(cat "$E/argo-ref.txt")" ] || { echo "$a" >"$E/obs/argo-changed-$(ems).txt"; stop "Argo state changed during the run"; }
  s=$(gitops_sha) && nz "$s" || stop "GitOps main unreadable"
  [ "$s" = "$(cat "$E/gitops-ref.txt")" ] || stop "GitOps main moved during the run (freeze broken)"
  s=$(sandboxes_all) || stop "Sandbox CR list unreadable"
  o=$(grep -v -x -F "$(cat "$E/sbx_cr" 2>/dev/null || echo __none__)" <<<"$s" | grep . || true)
  nz "$o" && stop "competing Sandbox CR(s): $o"
  gw_registered || stop "CLI gateway registration $GWNAME missing"
  [ "$(providers)" = "$(cat "$E/providers-ref.txt")" ] || stop "provider list changed during the run (names)"
  [ "$(K -n "$NS" get pod "$GW_POD" -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$(ref gw_pod_uid)" ] || stop "gateway pod replaced during the run (confound; Phase 1 has no gateway operation)"
  if [ -s "$E/obs/c0-create-t0" ] && [ $(( ($(ems) - $(cat "$E/obs/c0-create-t0")) / 1000 )) -gt "$WALL_MAX" ]; then stop "wall clock over ${WALL_MAX}s since c0-create"; fi
  if [ -s "$E/obs/c4b-start-t" ] && [ $(( ($(ems) - $(cat "$E/obs/c4b-start-t")) / 1000 )) -gt "$START_MAX" ]; then stop "over ${START_MAX}s since sandbox start"; fi
  spend_check
  return 0
}

# ---------------------------------------------------------------- inventory (names/UIDs only for Secrets)
inventory() { # inventory <dir>: the C0-C3 inventory plus the gateway pod UID and the namespace's VolumeAttachments
  local d=$1; mkdir -p "$d"
  K version -o yaml >"$d/version.yaml" 2>&1
  K get crd sandboxes.agents.x-k8s.io -o jsonpath='{.metadata.uid}{"\n"}{range .spec.versions[*]}{.name} served={.served} storage={.storage}{"\n"}{end}{.spec.conversion.strategy} {.status.storedVersions}{"\n"}' >"$d/crd.txt" 2>&1
  K get crd -o name 2>&1 | grep -i 'agents.x-k8s.io' >"$d/crds.txt"
  K get sandboxes.agents.x-k8s.io -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid' >"$d/sandboxes.txt" 2>&1
  K -n "$NS" get statefulset,deployment,service,pvc,networkpolicy,serviceaccount,role,rolebinding,configmap,resourcequota,limitrange,secret \
    -o 'custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid' >"$d/openshell-objects.txt" 2>&1
  K -n "$NS" get pods -o 'custom-columns=NAME:.metadata.name' >"$d/openshell-pod-names.txt" 2>&1
  K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.metadata.uid} replicas={.spec.replicas}{"\n"}' >"$d/gw-sts.txt" 2>&1
  K -n "$NS" get statefulset "$GW_STS" -o jsonpath='gen={.metadata.generation}{"\n"}' >"$d/gw-sts-generation.txt" 2>&1
  K -n "$NS" get pod "$GW_POD" -o jsonpath='{.metadata.uid}{"\n"}' >"$d/gw-pod-uid.txt" 2>&1
  K -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{" "}{end}{"\n"}{end}' >"$d/openshell-pod-images.txt" 2>&1
  K -n "$NS" get pvc -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,SC:.spec.storageClassName,VOL:.spec.volumeName,STATUS:.status.phase' >"$d/pvc.txt" 2>&1
  K get pv -o 'custom-columns=NAME:.metadata.name,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase' 2>&1 | awk -v ns="$NS" 'NR==1 || $2==ns' >"$d/pv-openshell.txt"
  K get volumeattachments -o json 2>/dev/null | jq -r --argjson pvs "$(awk 'NR > 1 {print $1}' "$d/pv-openshell.txt" | jq -R . | jq -s .)" '.items[] | select(.spec.source.persistentVolumeName as $p | $pvs | index($p)) | "\(.metadata.name) \(.spec.source.persistentVolumeName)"' >"$d/volumeattachments-openshell.txt" 2>&1
  K -n "$NS" get configmap openshell-config -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}' >"$d/gw-config.txt" 2>&1
  K -n agent-sandbox-system get deployment,pod,service,lease,role,rolebinding,secret -o 'custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid' >"$d/as-objects.txt" 2>&1
  K -n agent-sandbox-system get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{" rc="}{.restartCount}{end}{"\n"}{end}' >"$d/as-pods.txt" 2>&1
  K get clusterrole agent-sandbox-controller -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}{.rules}{"\n"}' >"$d/as-clusterrole.txt" 2>&1
  K get clusterrolebinding agent-sandbox-controller -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}' >"$d/as-clusterrolebinding.txt" 2>&1
  K get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>&1 | grep -i -E 'sandbox|openshell' >"$d/webhooks.txt"
  K get namespace "$NS" agent-sandbox-system -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,LABELS:.metadata.labels' >"$d/namespaces.txt" 2>&1
  { K -n "$NS" get ciliumnetworkpolicies; K get ciliumclusterwidenetworkpolicies; } >"$d/cilium.txt" 2>&1
  argo_state 2>&1 | awk '{print $1, $2, $3, $4}' >"$d/argo.txt"
  providers >"$d/providers.txt" || true
  profiles >"$d/profiles.txt" || true
  OT=30 O sandbox list >"$d/sandbox-list.txt" 2>&1
}

# ---------------------------------------------------------------- identity snapshots
spods() { K -n "$NS" get pods -o json | jq --arg s "$1" --arg r "${2:-}" '{items: [.items[] | select((.metadata.labels["openshell.ai/sandbox-id"] == $s or .metadata.labels["openshell.ai/boundary-pair"] == $s) and ($r == "" or .metadata.labels["openshell.ai/boundary-role"] == $r))]}'; }
PODF='{items: [.items[] | {name: .metadata.name, uid: .metadata.uid, labels: .metadata.labels, annotations: (.metadata.annotations // {} | with_entries(select(.key | test("expires|generation|uid|readiness|topology|session|bootstrap")))), ownerReferences: [.metadata.ownerReferences[]? | {kind, name, uid}], deletionTimestamp: .metadata.deletionTimestamp, creationTimestamp: .metadata.creationTimestamp, node: .spec.nodeName, restartPolicy: .spec.restartPolicy, phase: .status.phase, conditions: .status.conditions, containerStatuses: [.status.initContainerStatuses[]?, .status.containerStatuses[]? | {name, containerID, imageID, restartCount, ready, started, state, lastState}]}]}'
CRF='{name: .metadata.name, uid: .metadata.uid, generation: .metadata.generation, labels: .metadata.labels, annotations: (.metadata.annotations // {} | with_entries(select(.key | test("generation|bootstrap|runtime|admission|retention|phase")))), deletionTimestamp: .metadata.deletionTimestamp, finalizers: .metadata.finalizers, operatingMode: .spec.operatingMode, replicas: .spec.replicas, conditions: .status.conditions}'
ident() { # ident <label>: P (X1), W (pods/CR), G (sandbox get), T (X2); rc 0 only if exactly one claude process was read
  local l=$1 rc=0 sid; sid=$(cat "$E/sbx_id")
  kx X1 "$E/obs/$l-P.txt" || rc=1
  kx X2 "$E/obs/$l-T.txt" || rc=1
  spods "$sid" 2>"$E/obs/$l-C-pods.err" | jq "$PODF" >"$E/obs/$l-C-pods.json"
  K -n "$NS" get sandboxes.agents.x-k8s.io "$(cat "$E/sbx_cr_name")" -o json 2>"$E/obs/$l-C-cr.err" | jq "$CRF" >"$E/obs/$l-C-cr.json"
  K -n "$NS" get pod "$GW_POD" -o jsonpath='{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].imageID} ready={.status.containerStatuses[0].ready}{"\n"}' >"$E/obs/$l-G-gwpod.txt" 2>&1
  OT=10 sbx_json "$E/obs/$l-G-sandbox.json"
  psum "$l" >"$E/obs/$l-summary.txt"
  [ "$(grep -c '^proc=' "$E/obs/$l-P.txt" 2>/dev/null)" = 1 ] || rc=1
  grep -q 'key_form=REAL-KEY-SHAPE' "$E/obs/$l-P.txt" 2>/dev/null && stop "credential boundary: a real-key-shaped value is in the agent environment"
  return $rc
}
psum() {
  local l=$1 p=$E/obs/$1-P.txt
  grep -E '^(mode|launch|pid|start|nonce|boot_id|utc|uid)=' "$p" 2>/dev/null; grep '^proc=' "$p" 2>/dev/null
  echo "task: $(grep -E '^(attempts|progress|refusals|ledger|tr|lock)=' "$E/obs/$l-T.txt" 2>/dev/null | sed -E 's/ last=.* t=([^ ]+)( .*)?$/ last_t=\1/' | tr '\n' ' ')"
  jq -r '.items[] | "pod \(.labels["openshell.ai/boundary-role"] // "?") name=\(.name) uid=\(.uid) phase=\(.phase) node=\(.node) del=\(.deletionTimestamp // "-") \([.containerStatuses[] | "\(.name):cid=\(.containerID // "-"|.[-12:]) rc=\(.restartCount) ready=\(.ready)"]|join(" "))"' "$E/obs/$l-C-pods.json" 2>/dev/null
  echo "gwpod=$(cat "$E/obs/$l-G-gwpod.txt" 2>/dev/null)"
  echo "G phase=$(sbx_phase "$E/obs/$l-G-sandbox.json") instance=$(jq -r '[.. | .main_process_instance_id? // empty][0] // "-"' "$E/obs/$l-G-sandbox.json" 2>/dev/null)"
}
# P: launcher record (pid/start/nonce/boot) AND the live process (proc/start/nonce) must agree
pkeys() { local p=$E/obs/$1-P.txt a b; a=$(sed -n -e 's/^pid=//p' -e 's/^start=//p' -e 's/^nonce=//p' -e 's/^boot_id=//p' "$p" | tr '\n' ' ')
  b=$(sed -n 's/^proc=\([0-9]*\) start=\([0-9]*\) ppid=[0-9]* nonce=\([0-9a-f]*\) .*/\1 \2 \3/p' "$p")
  if nz "$b"; then [ "$(cut -d' ' -f1-3 <<<"$a")" = "$b" ] && echo "$a"; return 0; fi
  b=$(sed -n 's/^proc=\([0-9]*\) start=\([0-9]*\) ppid=[0-9]* nonce=unreadable .*/\1 \2/p' "$p")
  nz "$b" && [ "$(cut -d' ' -f1-2 <<<"$a")" = "$b" ] && echo "$a nonce_source=launch-record"; }
wkeys() { jq -r '.items[] | select(.labels["openshell.ai/boundary-role"]=="workload") | "\(.uid) \([.containerStatuses[] | "\(.name)=\(.containerID)/rc\(.restartCount)"]|join(","))"' "$E/obs/$1-C-pods.json" 2>/dev/null; }
snap() { # snap <label>: local copies of task logs + transcript; S key (path, lines, prefix hash). rc 1 if either copy failed.
  local l=$1 task=1
  kx X3L "$L/task/$l.tar" 30 && mkdir -p "$L/task/$l" && tar -xf "$L/task/$l.tar" -C "$L/task/$l" || task=0
  kx X3T "$L/tr/$l.jsonl" 60 || return 1
  { echo "tr=$(cat "$E/tr_rel") lines=$(wc -l <"$L/tr/$l.jsonl") bytes=$(wc -c <"$L/tr/$l.jsonl") task_logs=$([ "$task" = 1 ] && echo copied || echo failed)"
    "${M0[@]}" prefix "$L/tr/$l.jsonl" "$(wc -c <"$L/tr/$l.jsonl")"
    [ "$task" = 1 ] && "${M0[@]}" ledger "$L/task/$l"; } >"$E/obs/$l-S.txt"
  [ "$task" = 1 ]
}
# V: the sandbox's per-sandbox PVC (owned by its Sandbox CR, or named after the sandbox), its PV, the volume
# handle and every VolumeAttachment of that PV. Raw identity to $L; the exported summary carries the PVC/PV UIDs
# and a sha256 prefix of the volume handle only.
vread() { # vread <label>: rc 0 only if exactly one PVC with a bound PV was read
  local l=$1 cr pv
  cr=$(cat "$E/sbx_cr_name" 2>/dev/null)
  K -n "$NS" get pvc -o json 2>/dev/null | jq --arg cr "$cr" --arg s "$SBX" '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Sandbox" and .name == $cr) or (.metadata.name | contains($s))) | {name: .metadata.name, uid: .metadata.uid, pv: .spec.volumeName, del: .metadata.deletionTimestamp, finalizers: .metadata.finalizers, owners: [.metadata.ownerReferences[]? | {kind, name, uid}], phase: .status.phase}]' >"$L/$l-V-pvc.json" || return 1
  [ "$(jq length "$L/$l-V-pvc.json")" = 1 ] || { jq -c '{pvcs: length}' "$L/$l-V-pvc.json" >"$E/metrics/$l-V.json"; return 1; }
  pv=$(jq -r '.[0].pv // empty' "$L/$l-V-pvc.json"); nz "$pv" || return 1
  K get pv "$pv" -o json 2>/dev/null | jq '{name: .metadata.name, uid: .metadata.uid, handle: (.spec.csi.volumeHandle // ""), reclaim: .spec.persistentVolumeReclaimPolicy, del: .metadata.deletionTimestamp}' >"$L/$l-V-pv.json" || return 1
  K get volumeattachments -o json 2>/dev/null | jq --arg pv "$pv" '[.items[] | select(.spec.source.persistentVolumeName == $pv) | {name: .metadata.name, node: .spec.nodeName, attacher: .spec.attacher, attached: .status.attached, del: .metadata.deletionTimestamp}]' >"$L/$l-V-va.json" || return 1
  jq -n --slurpfile c "$L/$l-V-pvc.json" --slurpfile p "$L/$l-V-pv.json" --slurpfile a "$L/$l-V-va.json" \
    '{pvc_name: $c[0][0].name, pvc_uid: $c[0][0].uid, pvc_deleting: ($c[0][0].del != null), pvc_owner_kinds: [$c[0][0].owners[].kind], pvc_finalizers: $c[0][0].finalizers,
      pv: $p[0].name, pv_uid: $p[0].uid, pv_deleting: ($p[0].del != null), reclaim: $p[0].reclaim, volume_handle: $p[0].handle,
      va: [$a[0][] | {node, attacher, attached, deleting: (.del != null)}]}' >"$L/$l-V.json" || return 1
  jq --arg hh "$(jq -r .volume_handle "$L/$l-V.json" | tr -d '\n' | sha256sum | cut -c1-12)" 'del(.volume_handle) + {volume_handle_sha256_12: $hh}' "$L/$l-V.json" >"$E/metrics/$l-V.json"
}
va_released() { vread "$1" >/dev/null 2>&1 && [ "$(jq '[.va[] | select(.attached == true and .deleting == false)] | length' "$L/$1-V.json")" = 0 ]; }

# ---------------------------------------------------------------- terminal client (M2/M3/M4b), local tmux only
client_start() { # client_start <name>: M2 in a harness-owned tmux session; raw output piped to $L/term
  local c=$1
  [[ $c =~ ^[a-z0-9]{1,12}$ ]] || return 2
  case $STEP in c0-baseline | c4c) ;; *) log "REFUSED client_start in $STEP"; return 97 ;; esac
  [ -z "$(client_scan)" ] || stop "a connect client for $SBX already exists before $c"
  guard_ctx || stop "guard failed before connect"
  log "MUTATE openshell sandbox connect $SBX (tmux session $c)"
  echo "$(ems)" >"$E/obs/term-$c-t0"
  "${TM[@]}" new-session -d -s "$c" -x 160 -y 45 /bin/sh -c 'sleep 1; exec "$@"' sh "${OENV[@]}" "$CLI" -g "$GWNAME" sandbox connect "$SBX" || return 1
  "${TM[@]}" set-option -t "$c" remain-on-exit off >/dev/null
  "${TM[@]}" pipe-pane -o -t "$c" "cat >>'$L/term/$c.raw'"
}
client_tree() { # all pids of the client pane's process tree and its session
  local root all new p i; root=$("${TM[@]}" display-message -p -t "$1" '#{pane_pid}' 2>/dev/null) || return 0
  nz "$root" || return 0
  all=$root new=$root
  for i in 1 2 3 4 5 6; do
    p=$(for x in $new; do pgrep -P "$x" 2>/dev/null; done | tr '\n' ' '); nz "${p// /}" || break; all="$all $p" new=$p
  done
  all="$all $(pgrep -s "$root" 2>/dev/null | tr '\n' ' ')"
  tr ' ' '\n' <<<"$all" | grep . | sort -u
}
client_scan() { # local connect-client processes naming the isolated CLI ($HX), this sandbox or its id
  ps -eo pid=,args= | awk -v hx="$HX" -v sbx="$SBX" -v sid="$(cat "$E/sbx_id" 2>/dev/null)" '
    { n = split($2, p, "/"); b = p[n]; rest = substr($0, index($0, $2))
      if (b != "openshell" && b != "ssh" && b != "sh") next
      if (index(rest, hx) == 0 && index(rest, sbx) == 0 && (sid == "" || index(rest, sid) == 0)) next
      if (b == "sh" && index(rest, "ssh-proxy") == 0) next
      if (rest ~ / (sandbox (get|list|exec|create|delete|stop|start)|gateway (list|logout)|provider list) /) next
      print }'
}
cap() { "${TM[@]}" capture-pane -p -J -t "$1" >"$L/term/$1-$2.txt" 2>/dev/null; "${M0[@]}" screen "$L/term/$1-$2.txt" >"$E/term/$1-$2.json"; }
redraw() { "${TM[@]}" resize-window -t "$1" -x 150 -y 40; sleep 2; "${TM[@]}" resize-window -t "$1" -x 160 -y 45; sleep 3; }
ctrl_l() { log "MUTATE Ctrl-L into $1"; "${TM[@]}" send-keys -t "$1" C-l; sleep 3; }
type_line() { # M3: one fixed-form line + Enter; no control bytes (Ctrl-D/Ctrl-P are client escapes); c4c: at most INPUT_MAX
  local re='^[A-Za-z0-9 .,:=<>-]{1,240}$'
  [[ $2 =~ $re ]] || { log "REFUSED type_line"; return 97; }
  if [ "$STEP" = c4c ]; then
    local n; n=$(cat "$E/obs/c4c-inputs" 2>/dev/null || echo 0)
    [ "$n" -lt "$INPUT_MAX" ] || { log "REFUSED type_line (c4c input cap $INPUT_MAX reached)"; return 97; }
    echo $((n + 1)) >"$E/obs/c4c-inputs"
  fi
  log "MUTATE type into $1: ${3:-line} chars=${#2} sha256=$(printf %s "$2" | sha256sum | cut -c1-12)"
  "${TM[@]}" send-keys -t "$1" -l "$2" && sleep 0.5 && "${TM[@]}" send-keys -t "$1" Enter
}
client_kill() { # SIGKILL the harness's own client tree at once (client_detach fallback only); prove zero survivors twice
  local c=$1 pids t
  pids=$(client_tree "$c" | tr '\n' ' ')
  nz "$pids" || return 0
  echo "pids=$pids" >"$E/obs/term-$c-kill.txt"
  t=$(ems); log "MUTATE kill -KILL client tree of $c: $pids"
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  echo "$t" >"$E/obs/term-$c-kill-t"
  sleep 1; local s1; s1=$(client_scan); sleep 2; local s2; s2=$(client_scan)
  echo "scan1=$(nz "$s1" && echo present || echo none) scan2=$(nz "$s2" && echo present || echo none)" | tee -a "$E/obs/term-$c-kill.txt"
  "${TM[@]}" kill-session -t "$c" 2>/dev/null
  nz "$s2" && stop "client processes survived SIGKILL: $s2"
  return 0
}
client_detach() { # M4b: Ctrl-P Ctrl-Q, then SIGKILL fallback; zero survivors required
  local c=$1 i
  log "MUTATE detach $c (Ctrl-P Ctrl-Q)"
  "${TM[@]}" send-keys -t "$c" C-p; sleep 0.3; "${TM[@]}" send-keys -t "$c" C-q
  for i in $(seq 1 10); do [ -z "$(client_scan)" ] && break; sleep 1; done
  if [ -n "$(client_scan)" ]; then echo "clean_detach=no (fallback SIGKILL)" | tee -a "$E/obs/term-$c-detach.txt"; client_kill "$c"
  else echo "clean_detach=yes after_s=$i" | tee -a "$E/obs/term-$c-detach.txt"; "${TM[@]}" kill-session -t "$c" 2>/dev/null; fi
  echo "$(ems)" >"$E/obs/term-$c-detach-t"
}
# dialog and notice detection on a captured screen (booleans only; the capture itself stays local)
screen_flags() { # screen_flags <capture.txt> -> JSON
  local f=$1; g() { tr -s ' \n' ' ' <"$f" 2>/dev/null | grep -q -i -E "$1" && echo true || echo false; }
  jq -n --argjson trust "$(g 'trust (this|the files in this) folder|Do you trust')" --argjson key "$(g 'custom api key|use this api key')" \
    --argjson summary "$(g 'resume from summary|resume full session')" --argjson interrupted "$(g 'Interrupted')" \
    '{trust_dialog: $trust, custom_key_dialog: $key, resume_summary_dialog: $summary, interrupted_notice: $interrupted}'
}

egress_probes() { # egress_probes <label>: M8 (mediated sandbox exec) and kubectl exec (outside OpenShell mediation)
  local l=$1 rc=0
  OT=90 O sandbox exec "$SBX" --no-tty --no-login-shell --timeout 60 -- python3 -I -c "$X5PY" >"$E/obs/$l-X5-sandbox.txt" 2>"$E/obs/$l-X5-sandbox.err"
  echo "rc=$?" >>"$E/obs/$l-X5-sandbox.txt"
  kx X5 "$E/obs/$l-X5-kubectl.txt" 60; echo "rc=$?" >>"$E/obs/$l-X5-kubectl.txt"
  cat "$E/obs/$l-X5-sandbox.txt" "$E/obs/$l-X5-kubectl.txt" >"$E/obs/$l-X5.txt"
  grep -q 'REAL-KEY-SHAPE' "$E/obs/$l-X5.txt" && rc=1
  grep -q '^disallowed_host=blocked' "$E/obs/$l-X5-sandbox.txt" && grep -q '^anthropic_from_python=blocked' "$E/obs/$l-X5-sandbox.txt" || rc=1
  grep -q '=connected' "$E/obs/$l-X5-kubectl.txt" && log "$l: note: kubectl-exec probe (outside OpenShell mediation) connected: $(grep '=connected' "$E/obs/$l-X5-kubectl.txt" | tr '\n' ' ')"
  return $rc
}

# ---------------------------------------------------------------- task gating
task_count() { sed -n "s/^$1=\([0-9]*\) .*/\1/p" "$2"; }
gate() { # gate <label> <timeout-s>: GATE_MIN_DONE <= done <= GATE_MAX_DONE
  local d=$(( $(ems) + $2 * 1000 )) p
  while [ "$(ems)" -lt "$d" ]; do
    kx X2 "$E/obs/$1-gate.txt" 15 || { sleep 2; continue; }
    p=$(task_count progress "$E/obs/$1-gate.txt")
    if [ "${p:-0}" -ge "$GATE_MIN_DONE" ] && [ "${p:-0}" -le "$GATE_MAX_DONE" ]; then echo "gate done=$p at=$(now)" >>"$E/obs/$1-gate-log.txt"; return 0; fi
    sleep 2
  done
  return 1
}
# x8 <file> -> "N age_ms lock done" for the last attempt line (workload clock), or empty if not parseable
x8_inflight() {
  python3 -I - "$1" <<'PY'
import re, sys
from datetime import datetime
kv = dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[1]) if "=" in l)
a = re.match(r"attempt n=(\d+) t=(\S+)", kv.get("last_attempt", ""))
d = re.match(r"done n=(\d+) ", kv.get("last_done", "") + " ")
if a and kv.get("now_ms", "").isdigit():
    t = int(datetime.strptime(a.group(2).replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z").timestamp() * 1000)
    print(a.group(1), int(kv["now_ms"]) - t, kv.get("lock", "?"), d.group(1) if d else 0, kv.get("attempts", "?").split()[0])
PY
}

# ---------------------------------------------------------------- sampler (read-only, background, own session)
kwatch() { while [ ! -e "$E/sampler.stop" ]; do echo "## watch (re)start $(now)" >>"$1.err"; "${KC[@]}" -n "$NS" get "${@:2}" --watch --output-watch-events -o json 2>>"$1.err" | jq -c --unbuffered '{type, k: .object.kind, name: .object.metadata.name, uid: .object.metadata.uid, rv: .object.metadata.resourceVersion, del: .object.metadata.deletionTimestamp, phase: .object.status.phase, cs: [.object.status.initContainerStatuses[]?, .object.status.containerStatuses[]? | {name, containerID, ready, restartCount, state, lastState}], cond: .object.status.conditions, reason: .object.reason, msg: .object.message, ts: (.object.lastTimestamp // .object.eventTime)}' >>"$1"; sleep 1; done; }
sampler_done() { [ -e "$E/obs/cleanup-done" ] && [ $(( $(ems) - $(cat "$E/obs/cleanup-done") )) -gt 120000 ]; }
sampler_gate() { local i; for i in $(seq 20); do grep -q "^$GW_POD " "$E/samples/pods-1hz.txt" 2>/dev/null && jq -e --arg p "$GW_POD" 'select(.name == $p)' "$E/samples/pods-watch.jsonl" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
sampler() {
  local s=$E/samples n=0 t
  mkdir -p "$s"
  trap 'kill 0' EXIT
  kwatch "$s/pods-watch.jsonl" pods &
  kwatch "$s/cr-watch.jsonl" sandboxes.agents.x-k8s.io &
  kwatch "$s/events-watch.jsonl" events &
  while [ ! -e "$E/sampler.stop" ]; do
    t=$(now)
    { echo "## $t"; K -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.status.phase} del={.metadata.deletionTimestamp} {range .status.containerStatuses[*]}{.name}:{.ready}:{.restartCount}:{.containerID} {end}{"\n"}{end}' 2>&1; } >>"$s/pods-1hz.txt"
    if [ -s "$E/sbx_id" ]; then
      if OT=5 sbx_json "$s/g.json"; then echo "$t $(sbx_phase "$s/g.json") $(jq -c '[.. | .main_process_instance_id? // empty][0]' "$s/g.json" 2>/dev/null)" >>"$s/sandbox-get-1hz.txt"
      else echo "$t ERR $(head -c 160 "$s/g.json.err" | tr '\n' ' ')" >>"$s/sandbox-get-1hz.txt"; fi
      if [ -s "$E/wctr" ]; then
        if [ $((n % 5)) -eq 0 ]; then
          if kx X1 "$s/p.txt" 10; then echo "$t $(grep -E '^(launch|pid|start|nonce)=' "$s/p.txt" | tr '\n' ' ') $(grep '^proc=' "$s/p.txt" | tr '\n' ' ')" >>"$s/P-5s.txt"
          else echo "$t ERR $(head -c 160 "$s/p.txt.err" | tr '\n' ' ')" >>"$s/P-5s.txt"; fi
        fi
        if [ $((n % 10)) -eq 0 ]; then
          if kx X2 "$s/t.txt" 10; then echo "$t $(grep -E '^(attempts|progress|refusals|tr|lock)=' "$s/t.txt" | sed -E 's/ last=.* t=([^ ]+)( .*)?$/ last_t=\1/' | tr '\n' ' ')" >>"$s/T-10s.txt"
          else echo "$t ERR $(head -c 160 "$s/t.txt.err" | tr '\n' ' ')" >>"$s/T-10s.txt"; fi
        fi
      fi
      if [ $((n % 10)) -eq 0 ] && [ -s "$E/sbx_cr_name" ]; then
        if vread sampler >/dev/null 2>&1; then echo "$t $(jq -c '{pvc_uid, pv_uid, pvc_deleting, va: [.va[] | {attached, deleting}]}' "$L/sampler-V.json")" >>"$s/V-10s.txt"
        else echo "$t ERR vread" >>"$s/V-10s.txt"; fi
      fi
      # X: capture state and logs of any pod of this sandbox once when it is Failed/Succeeded/deleting, and once
      # more when a container shows a terminated state (a 1 s-grace delete is marked deleting before it ends)
      spods "$(cat "$E/sbx_id")" 2>/dev/null >"$s/sp.json"
      for u in $(jq -r '.items[] | select(.status.phase == "Failed" or .status.phase == "Succeeded" or .metadata.deletionTimestamp != null or ([.status.initContainerStatuses[]?, .status.containerStatuses[]? | .state.terminated // empty] | length > 0)) | .metadata.uid' "$s/sp.json" 2>/dev/null); do
        term=$(jq -r --arg u "$u" '.items[] | select(.metadata.uid == $u) | [.status.containerStatuses[]? | .state.terminated // empty] | length' "$s/sp.json")
        f="$s/x-$u.json"; [ "${term:-0}" -gt 0 ] && f="$s/x-$u-terminated.json"
        [ -e "$f" ] && continue
        jq --arg u "$u" '.items[] | select(.metadata.uid == $u) | {name: .metadata.name, uid: .metadata.uid, phase: .status.phase, del: .metadata.deletionTimestamp, st: [.status.initContainerStatuses[]?, .status.containerStatuses[]? | {name, state, lastState, restartCount}]}' "$s/sp.json" >"$f"
        nm=$(jq -r .name "$f")
        K -n "$NS" logs "$nm" --all-containers --timestamps >"$L/logs/x-$nm-$u.log" 2>&1
        echo "$t captured state of $nm ($u) -> ${f##*/}" >>"$s/x-captured.txt"
      done
    fi
    if sampler_done; then echo "## $(now) sampler stopped itself: cleanup finished > 120 s ago" >>"$s/pods-1hz.txt"; touch "$E/sampler.stop"; fi
    n=$((n + 1)); sleep 1
  done
}
grab_logs() {
  local l=$1 p
  K -n "$NS" logs "$GW_POD" --timestamps --since=2h >"$L/logs/$l-gateway.log" 2>&1
  for p in $(spods "$(cat "$E/sbx_id")" 2>/dev/null | jq -r '.items[] | "pod/" + .metadata.name'); do
    K -n "$NS" logs "$p" --all-containers --timestamps >"$L/logs/$l-${p#pod/}.log" 2>&1
  done
  K -n agent-sandbox-system logs deploy/agent-sandbox-controller --timestamps --since=2h >"$L/logs/$l-controller.log" 2>&1
}
gw_field() { K -n "$NS" get pod "$GW_POD" -o jsonpath="$1" 2>/dev/null; }
sbx_ready() { OT=10 sbx_json "$E/obs/poll.json" && [ "$(sbx_phase "$E/obs/poll.json")" = Ready ]; }
sbx_phase_is() { [ "$(phase_now)" = "$1" ]; }
waitfor() { local d=$1; shift; while [ "$(ems)" -lt "$d" ]; do "$@" && return 0; sleep 1; done; return 1; }
workload_resolve() { # workload_resolve <label>: exactly one workload pod of this sandbox; records wpod/wuid/wctr
  spods "$(cat "$E/sbx_id")" workload 2>/dev/null | jq "$PODF" >"$E/obs/$1-wpods.json"
  [ "$(jq '.items | length' "$E/obs/$1-wpods.json")" = 1 ] || return 1
  jq -r '.items[0].name' "$E/obs/$1-wpods.json" >"$E/wpod"; jq -r '.items[0].uid' "$E/obs/$1-wpods.json" >"$E/wuid"
  jq -r '.items[0].containerStatuses[].name' "$E/obs/$1-wpods.json" | grep -x agent >"$E/wctr"
}
kv() { sed -n "s/^$1=//p" "$2" | head -n 1; }

# ================================================================ steps
case $STEP in
pre)
  [ ! -e "$E/STOPPED" ] || fail "stopped earlier"
  if [ ! -s "$E/refs.txt" ]; then
    v1=$(K get namespace kube-system -o jsonpath='{.metadata.uid}'); v2=$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.metadata.uid}')
    v3=$(K -n "$NS" get pvc "$GW_PVC" -o jsonpath='{.metadata.uid}'); v4=$(K -n "$NS" get pod "$GW_POD" -o jsonpath='{.status.containerStatuses[0].imageID}')
    v5=$(K -n agent-sandbox-system get pods -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'); v6=$(argo_state); v7=$(gitops_sha)
    v8=$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.spec.replicas}'); v9=$(providers); v10=$(K -n "$NS" get pod "$GW_POD" -o jsonpath='{.metadata.uid}')
    for v in "$v1" "$v2" "$v3" "$v4" "$v5" "$v6" "$v7" "$v8" "$v10"; do nz "$v" || fail "pre: a reference value is empty; refusing to record refs"; done
    printf 'kube_system_uid=%s\ngw_sts_uid=%s\ngw_pvc_uid=%s\ngw_image=%s\nctrl_image=%s\ngw_replicas=%s\ngw_pod_uid=%s\n' "$v1" "$v2" "$v3" "$v4" "$v5" "$v8" "$v10" >"$E/refs.txt"
    echo "$v6" >"$E/argo-ref.txt"; echo "$v7" >"$E/gitops-ref.txt"; echo "$v9" >"$E/providers-ref.txt"
  fi
  guard_ctx || stop "pre: identity guard failed"
  [ "$(ref kube_system_uid)" = "$PIN_KUBE_SYSTEM_UID" ] && [ "$(ref gw_sts_uid)" = "$PIN_GW_STS_UID" ] && [ "$(ref gw_pvc_uid)" = "$PIN_GW_PVC_UID" ] \
    || stop "pre: cluster/gateway UIDs differ from the pinned Stage B values (wrong context, or the gateway was recreated)"
  argo_healthy "$(cat "$E/argo-ref.txt")" || stop "pre: Argo apps not Synced/Healthy: $(tr '\n' ';' <"$E/argo-ref.txt")"
  [ "$(ref gw_replicas)" = 1 ] || stop "pre: gateway replicas=$(ref gw_replicas), expected 1"
  inventory "$E/inv/pre"
  [ "$(ref gw_image)" = "ghcr.io/nvidia/openshell/gateway@$GW_DIGEST" ] || stop "gateway digest differs from Stage B: $(ref gw_image)"
  [ "$(ref ctrl_image)" = "registry.k8s.io/agent-sandbox/agent-sandbox-controller@$CTRL_DIGEST" ] || stop "controller digest differs from Stage B: $(ref ctrl_image)"
  [ "$(gw_field '{.status.containerStatuses[0].ready}')" = true ] || stop "gateway not Ready"
  s=$(sandboxes_all) || stop "Sandbox list unreadable"; nz "$s" && stop "competing Sandbox CRs: $s"
  gw_registered || stop "CLI registration $GWNAME missing (owner login first)"
  OT=30 O sandbox list >"$E/inv/sandbox-list-pre.txt" 2>&1 || stop "sandbox list failed (not logged in?)"
  grep -q -x -F "$PROV" "$E/providers-ref.txt" || stop "provider $PROV not present (owner creates it first)"
  awk -v n="$PROF" '{for (i = 1; i <= NF; i++) if ($i == n) f = 1} END {exit !f}' "$E/inv/pre/profiles.txt" || stop "profile $PROF not listed (owner imports it first), or profile list failed"
  log "pre OK: Argo Synced/Healthy; digests match Stage B; gateway Ready replicas=1 pod=$(ref gw_pod_uid); no Sandbox CRs; provider $PROV present; gitops=$(cat "$E/gitops-ref.txt")"
  ;;
sampler-start)
  [ ! -e "$E/sampler.pid" ] || fail "sampler already started"; rm -f "$E/sampler.stop"
  setsid bash "$(readlink -f "$0")" "$RUN" _sampler </dev/null >>"$E/sampler.log" 2>&1 & echo $! >"$E/sampler.pid"
  sampler_gate || stop "sampler not producing data 20 s after start (pods-1hz lists $GW_POD; pods-watch holds a parsed event)"
  log "sampler started pid=$(cat "$E/sampler.pid") and producing data"
  ;;
_sampler) sampler ;;
sampler-stop) touch "$E/sampler.stop"; sleep 3; log "sampler stop requested" ;;
ident) nz "$ARG" || fail "ident needs a label"; ident "$ARG"; cat "$E/obs/$ARG-summary.txt" ;;
snap) nz "$ARG" || fail "snap needs a label"; snap "$ARG"; cat "$E/obs/$ARG-S.txt" ;;
vread) nz "$ARG" || fail "vread needs a label"; vread "$ARG"; cat "$E/metrics/$ARG-V.json" 2>/dev/null ;;
spend) spend_check; cat "$E/metrics/spend-latest.json" 2>/dev/null ;;
c0-create)
  guard_full; [ -e "$E/sampler.pid" ] || fail "start the sampler first"
  [ ! -e "$E/STOPPED" ] || fail "a previous step stopped: $(cat "$E/STOPPED")"; [ ! -e "$E/done-c0-create" ] || fail "c0-create already ran (single attempt)"
  create_args # defined in launcher4.sh: fills CREATE=(...) and LAUNCH=(...)
  # local byte budget and shape BEFORE the create marker: an oversized or malformed package never reaches OpenShell,
  # and done-c0-create then keeps meaning "a create request was sent"
  launch_check "$E/obs/c0-launch-result.txt" || stop "C0: launch argv failed the local check, no create request sent: $(cat "$E/obs/c0-launch-result.txt")"
  log "C0 launch check: $(cat "$E/obs/c0-launch-result.txt")"
  once c0-create
  put1 "$E/obs/c0-create-t0" "$(ems)"
  OT=420 O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >"$E/obs/c0-create.out" 2>"$E/obs/c0-create.err" </dev/null
  rc=$?; log "create rc=$rc"
  if [ "$rc" != 0 ]; then
    sbx_json "$E/obs/c0-sandbox.json" && jq -r '[.id, .sandbox.id, .metadata.id, .sandbox.metadata.id] | map(select(. != null)) | .[0] // empty' "$E/obs/c0-sandbox.json" >"$E/sbx_id"
    [ -s "$E/sbx_id" ] && grab_logs c0-create-fail
    stop "C0 create failed rc=$rc: $(tr '\n' ' ' <"$E/obs/c0-create.err" | cut -c1-300)"
  fi
  sbx_json "$E/obs/c0-sandbox.json" || stop "C0 sandbox get failed"
  id=$(jq -r '[.id, .sandbox.id, .metadata.id, .sandbox.metadata.id] | map(select(. != null)) | .[0] // empty' "$E/obs/c0-sandbox.json")
  nz "$id" || stop "C0: no sandbox id in sandbox get"
  echo "$id" >"$E/sbx_id"
  # never ephemeral: an ephemeral sandbox is auto-deleted by the gateway after a failed main process
  jq -e '[.. | objects | to_entries[]? | select(.key == "openshell.nvidia.com/retention" and .value == "ephemeral")] | length == 0' "$E/obs/c0-sandbox.json" >/dev/null \
    || stop "C0: the sandbox carries retention=ephemeral (would be auto-deleted; C4 impossible)"
  K get sandboxes.agents.x-k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' >"$E/sbx_cr"
  [ "$(grep -c . "$E/sbx_cr")" = 1 ] && [ "$(cut -d/ -f1 "$E/sbx_cr")" = "$NS" ] || stop "expected exactly one Sandbox CR in $NS; got $(tr '\n' ' ' <"$E/sbx_cr")"
  cut -d/ -f2 "$E/sbx_cr" >"$E/sbx_cr_name"
  waitfor $(( $(cat "$E/obs/c0-create-t0") + 300000 )) sbx_ready || stop "C0: sandbox not Ready within 300 s of create"
  put1 "$E/obs/c0-ready-t" "$(ems)"
  spods "$id" | jq "$PODF" >"$E/obs/c0-pods.json"
  workload_resolve c0 || stop "expected exactly one workload pod with container 'agent'"
  wpod_ok || stop "workload pod labels/UID do not match this sandbox"
  vread c0 || stop "C0: per-sandbox PVC/PV not readable as exactly one PVC with a bound PV"
  echo "$(( $(cat "$E/obs/c0-ready-t") - $(cat "$E/obs/c0-create-t0") ))" >"$E/obs/c0-ready-ms"
  echo "$(ems)" >"$E/obs/c0-create-done"
  log "C0 created id=$id cr=$(cat "$E/sbx_cr") ready_ms=$(cat "$E/obs/c0-ready-ms") wuid=$(cat "$E/wuid") pvc=$(jq -r .pvc_uid "$E/metrics/c0-V.json")"
  ;;
c0-baseline)
  guard_full; need c0-create; once c0-baseline
  wpod_ok || stop "C0: workload pod identity changed"
  waitfor $(( $(ems) + 60000 )) ident c0-base || stop "C0: identity not readable (see obs/c0-base-P.txt)"
  grep -q '^mode=fresh$' "$E/obs/c0-base-P.txt" || stop "C0: the launcher did not start in Fresh mode"
  grep -q '^key_form=placeholder$' "$E/obs/c0-base-P.txt" || stop "C0: launcher saw no OpenShell placeholder ($(grep -o 'key_form=[a-zA-Z-]*' "$E/obs/c0-base-P.txt" | tr '\n' ' '))"
  grep '^proc=' "$E/obs/c0-base-P.txt" | grep -q -E 'keyref_form=absent key_form=placeholder$|nonce=unreadable' || stop "C0: live agent environment: expected the placeholder in ANTHROPIC_API_KEY and no EXP008_ANTHROPIC_KEYREF"
  nz "$(pkeys c0-base)" || stop "C0: launcher record and live process disagree, or nonce unreadable"
  clock c0 || stop "C0: clock read failed"
  kx X4 "$E/obs/c0-X4.txt" 60 || stop "C0: credential scan failed"
  grep -q '^env_real_key_shape=0$' "$E/obs/c0-X4.txt" && grep -q '^fs_real_key_shape_files=0$' "$E/obs/c0-X4.txt" || stop "C0: real-key-shaped value found in the workload ($(tr '\n' ' ' <"$E/obs/c0-X4.txt"))"
  egress_probes c0 || stop "C0: egress/credential probe failed (see obs/c0-X5.txt)"
  # H4 with the shared real-model predicate: a REAL model response, not any assistant entry (run 1126-1017 lesson)
  waitfor $(( $(ems) + 180000 )) bash "$(readlink -f "$0")" "$RUN" _tr_probe X2probe || stop "C0: no transcript with a real model response within 180 s (H4)"
  # first attach; the codeword line is also the pre-fault control probe (proposal 5.6)
  od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^/heron/' >"$L/codeword"
  client_start main || stop "C0: first connect failed"
  for _ in $(seq 1 30); do [ -s "$L/term/main.raw" ] && break; sleep 1; done
  sleep 5; cap main replay; redraw main; cap main redraw
  "${M0[@]}" rawmode "$L/term/main.raw" >"$E/term/main-rawmode.json"
  grep -q -a 'attached read-only' "$L/term/main.raw" && stop "C0: first attach is read-only (another client owns input?)"
  kx X2 "$E/obs/c0-control-T.txt" 15 || stop "C0: task state unreadable before the control line"
  d0=$(task_count progress "$E/obs/c0-control-T.txt"); d0=${d0:-0}
  tok=PROBE-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'); echo "$tok" >"$L/c0-probe"
  type_line main "Remember this codeword: $(cat "$L/codeword"). Reply on one line exactly: $tok CODEWORD=<the codeword> LAST=<number of the last step that printed STEP OK>. Do not run any tool for this reply." control-line || stop "C0: control line refused"
  d=$(( $(ems) + 600000 ))
  while [ "$(ems)" -lt "$d" ]; do
    sleep 15; snap c0-ref || continue
    m=$("${M0[@]}" m "$L/task/c0-ref" | jq -r .M_s)
    "${M4[@]}" probe4 "$L/tr/c0-ref.jsonl" "$tok" "$L/codeword" "$d0,$((d0 + 1)),$((d0 + 2))" >"$E/metrics/c0-control.json"
    [ "$m" != null ] && [ "$(jq -r .reply "$E/metrics/c0-control.json")" = true ] && break
  done
  [ "${m:-null}" != null ] || stop "C0: fewer than 6 first attempts (steps 1-6) within 10 min (agent not following the task?)"
  [ "$(jq -r .delivered "$E/metrics/c0-control.json")" = true ] || stop "C0: the codeword/control line was not delivered into the session within 10 min"
  echo "$m" >"$E/obs/M_s"
  [ -s "$L/task/c0-ref/attempts.log" ] || stop "C0: attempts.log missing from the C0 snapshot"
  grep -v -q 'kf=absent ak=placeholder' "$L/task/c0-ref/attempts.log" && stop "C0: a step.sh run (agent descendant) saw unexpected key forms"
  grep -v -q " sleep=$STEP_SLEEP " "$L/task/c0-ref/attempts.log" && stop "C0: a step did not run with the approved ${STEP_SLEEP} s sleep (pacing assumption broken)"
  "${M0[@]}" usage "$L/tr/c0-ref.jsonl" >"$E/metrics/c0-usage.json"
  client_detach main
  log "C0 baseline: P=$(pkeys c0-base) W=$(wkeys c0-base) M=${m}s control=$(jq -c '{delivered, reply, format_ok, codeword_ok, last_ok, tool_use_before_reply, pass}' "$E/metrics/c0-control.json")"
  spend_check
  echo "$(ems)" >"$E/obs/c0-baseline-done"
  ;;
_tr_probe) # helper for c0-baseline: rc 0 once a transcript with >= 1 REAL model entry exists (records its relative path)
  kx X2 "$E/obs/c0-trprobe.txt" 15 || exit 1
  t=$(sed -n 's/^tr=\([^ ]*\) .*/\1/p' "$E/obs/c0-trprobe.txt"); [ "$(grep -c '^tr=' "$E/obs/c0-trprobe.txt")" = 1 ] || exit 1
  kx X7 "$E/obs/c0-trdir.txt" 15 || exit 1; sed 's#^/sandbox/c/claude/projects/##' "$E/obs/c0-trdir.txt" | tr -d '\n' >"$E/tr_dir"
  printf '%s%s' "$(cat "$E/tr_dir")" "$t" >"$E/tr_rel"
  kx X3T "$L/tr/c0-first.jsonl" 30 && "${M4[@]}" h4 "$L/tr/c0-first.jsonl" >"$E/metrics/c0-h4.json" && [ "$(jq -r .ok "$E/metrics/c0-h4.json")" = true ]
  ;;
c4a)
  guard_full; need c0-baseline; once c4a
  [ -z "$(client_scan)" ] || stop "C4a: a client is attached (must be detached)"
  gate c4a 900 || stop "C4a: progress gate ($GATE_MIN_DONE..$GATE_MAX_DONE done) not met within 15 min (C4 not-tested; nothing deleted)"
  d=$(( $(ems) + 900000 )) k=0 armed=
  while [ "$(ems)" -lt "$d" ] && [ -z "$armed" ]; do
    spend_check
    kx X8 "$E/obs/c4a-x8.txt" 15 || { sleep 2; continue; }
    read -r n age lk dn _ <<<"$(x8_inflight "$E/obs/c4a-x8.txt")"
    if [ -z "${n:-}" ] || [ "$lk" != held ] || [ "$n" != $((dn + 1)) ] || [ "$age" -lt "$R_AGE_MIN" ] || [ "$age" -gt "$R_AGE_MAX" ]; then sleep 1; continue; fi
    k=$((k + 1)) l=c4a-R$k why=
    log "C4a: step $n in flight (age ${age} ms); reference snapshot $l"
    ident "$l" || why="$why P-unreadable"
    nz "$(pkeys "$l")" || why="$why P-keys"
    nz "$(wkeys "$l")" || why="$why W-keys"
    vread "$l" || why="$why V"
    snap "$l" || why="$why snapshot"
    kx X8 "$E/obs/$l-X8.txt" 15 || why="$why X8"
    jq -e .chain_ok "$E/obs/$l-S.txt" >/dev/null 2>&1 || grep -q '"chain_ok": true' "$E/obs/$l-S.txt" || why="$why ledger-chain"
    [ "$(kv state_id_sha256 "$E/obs/$l-X8.txt" | grep -c -E '^[0-9a-f]{64}$')" = 1 ] || why="$why state-id"
    [ "$(kv token_file_sha256 "$E/obs/$l-X8.txt" | grep -c -E '^[0-9a-f]{64}$')" = 1 ] || why="$why token-file"
    "${M4[@]}" h4 "$L/tr/$l.jsonl" >"$E/metrics/$l-h4.json" 2>/dev/null; [ "$(jq -r .ok "$E/metrics/$l-h4.json" 2>/dev/null)" = true ] || why="$why transcript"
    python3 -I -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("m4", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.exit(0 if m.in_flight(sys.argv[2]) == int(sys.argv[3]) and m.find_step_tool_use(m.parse_lines(m.load_bytes(sys.argv[4])), int(sys.argv[3])) else 1)' \
      "$HERE/metrics4.py" "$L/task/$l" "$n" "$L/tr/$l.jsonl" || why="$why in-flight-step-not-in-R"
    kx X8 "$E/obs/$l-recheck.txt" 15 || why="$why recheck"; trc=$(ems)
    read -r n2 age2 lk2 dn2 _ <<<"$(x8_inflight "$E/obs/$l-recheck.txt")"
    { [ "${n2:-}" = "$n" ] && [ "$lk2" = held ] && [ "$dn2" = "$dn" ] && [ "${age2:-999999}" -le "$KILL_AGE_MAX" ]; } || why="$why late-or-changed(n=${n2:-?} age=${age2:-?})"
    if nz "$why"; then echo "$l incomplete:$why" | tee -a "$E/obs/c4a-R-attempts.txt"; stop "C4a: reference snapshot incomplete or late:$why (C4 not-tested; nothing deleted)"; fi
    armed=$l
    echo $((trc + KILL_DEADLINE_AGE - age2)) >"$E/obs/c4a-kill-deadline" # workstation ms; kw refuses after it
  done
  nz "$armed" || stop "C4a: no step in flight inside the R window within 15 min (C4 not-tested; nothing deleted)"
  { echo "R=$armed in_flight_step=$n age_at_R_ms=$age age_at_recheck_ms=$age2 attempts_considered=$k"; } | tee "$E/obs/c4a-R-summary.txt"
  for x in P.txt T.txt C-pods.json C-cr.json S.txt X8.txt; do cp "$E/obs/$armed-$x" "$E/obs/c4a-R-$x"; done
  cp -r "$L/task/$armed" "$L/task/c4a-R"; cp "$L/tr/$armed.jsonl" "$L/tr/c4a-R.jsonl"; cp "$L/$armed-V.json" "$L/c4a-R-V.json"; cp "$E/metrics/$armed-V.json" "$E/metrics/c4a-R-V.json"
  olduid=$(cat "$E/wuid"); echo "$olduid" >"$E/obs/c4a-old-wuid"
  touch "$E/obs/c4a-armed"
  t0=$(ems); put1 "$E/obs/c4a-t0" "$t0"
  kw delete pod "$(WPOD)" --grace-period=1 --wait=false >"$E/obs/c4a-delete.out" 2>"$E/obs/c4a-delete.err" || stop "C4a: M9 refused or failed (rc=$?)"
  # observe 120 s: the original pod's fate, any replacement pod and its fate, the sandbox phase
  while [ "$(ems)" -lt $((t0 + 120000)) ]; do
    { echo "## $(( $(ems) - t0 ))ms phase=$(phase_now)"; spods "$(cat "$E/sbx_id")" workload 2>/dev/null | jq -r '.items[] | "\(.metadata.uid) \(.status.phase) del=\(.metadata.deletionTimestamp // "-") running=\([.status.containerStatuses[]? | select(.state.running != null)] | length)"'; } >>"$E/obs/c4a-observe.txt"
    sleep 2
  done
  ph=$(phase_now)
  # the original pod at the end of the window: absent, present but deleting, or present and not deleting
  orig=$(spods "$(cat "$E/sbx_id")" workload 2>/dev/null | jq -r --arg u "$olduid" '[.items[] | select(.metadata.uid == $u)] | if length == 0 then "absent" elif .[0].metadata.deletionTimestamp != null then "deleting" else "present" end')
  term=$( { [ -e "$E/samples/x-$olduid-terminated.json" ] && echo captured; } || { jq -e --arg u "$olduid" 'select(.uid == $u and ([.cs[]? | .state.terminated // empty] | length > 0))' "$E/samples/pods-watch.jsonl" >/dev/null 2>&1 && echo captured; } || echo not-captured)
  deleted=$(jq -e --arg u "$olduid" 'select(.uid == $u and .type == "DELETED")' "$E/samples/pods-watch.jsonl" >/dev/null 2>&1 && echo yes || echo no)
  exitinfo=$(jq -r --arg u "$olduid" 'select(.uid == $u) | .cs[]? | select(.name == "agent") | (.state.terminated // .lastState.terminated // empty) | "exitCode=\(.exitCode) reason=\(.reason) signal=\(.signal // "-")"' "$E/samples/pods-watch.jsonl" 2>/dev/null | tail -n 1)
  repl=$(awk '/^## /{next} {print $1}' "$E/obs/c4a-observe.txt" | sort -u | grep -v -x "$olduid" || true)
  rfate=none; if nz "$repl"; then rfate=fenced; grep -v "^$olduid " "$E/obs/c4a-observe.txt" | grep -q -E 'running=[1-9]' && rfate=ran; fi
  if [ "$orig" = absent ] && { [ "$term" = captured ] || [ "$deleted" = yes ]; }; then proc=ended
  elif [ "$orig" = present ] && kx X1 "$E/obs/c4a-after-P.txt" 10 && grep -q "^nonce=$(sed -n 's/^nonce=//p' "$E/obs/c4a-R-P.txt")$" "$E/obs/c4a-after-P.txt"; then proc=survived
  else proc=inconclusive; fi
  { echo "step=c4a original_process=$proc original_pod=$orig termination=$term deleted_event=$deleted"
    echo "termination_observed: ${exitinfo:-none} (requested grace 1 s; the recorded state, not the request, says how it ended)"
    echo "replacement_pod=$rfate replacement_uids=$(echo "$repl" | grep -c .) phase_120s=$ph"; } | tee "$E/obs/c4a-result.txt"
  grab_logs c4a; echo "$(ems)" >"$E/obs/c4a-done"
  log "C4a done"
  ;;
c4b)
  guard_full; need c4a; once c4b
  grep -q 'original_process=ended' "$E/obs/c4a-result.txt" || { echo "step=c4b value=not-tested reason=c4a-not-ended" | tee "$E/obs/c4b-result.txt"; stop "C4b: C4a did not end the original process (C4b/C4c not-tested)"; }
  ph=$(phase_now); echo "phase_before_stop=$ph" >"$E/obs/c4b-times.txt"
  ident c4b-prestop >/dev/null 2>&1 || true # P is unreadable by design (no workload); W and CR are recorded
  vread c4b-prestop || log "C4b: V unreadable before stop"
  [ "$ph" = Error ] || { echo "step=c4b value=not-tested reason=phase-$ph-not-Error" | tee "$E/obs/c4b-result.txt"; stop "C4b: sandbox phase is '$ph', not Error (no stop issued)"; }
  nr() { # not-restartable: record and stop; cleanup deletes from the settled phase
    { echo "step=c4b value=not-restartable reason=$1 phase=$(phase_now)"; } | tee "$E/obs/c4b-result.txt"
    K -n "$NS" get sandboxes.agents.x-k8s.io "$(cat "$E/sbx_cr_name")" -o json 2>/dev/null | jq "$CRF" >"$E/obs/c4b-nr-C-cr.json"
    jq -n --arg r "$1" '{not_restartable: $r}' >"$L/c4b-bundle.json"; "${M4[@]}" c4b "$L/c4b-bundle.json" >"$E/metrics/c4b.json"
    grab_logs c4b-nr; stop "C4b: not-restartable ($1)"; }
  t=$(ems); put1 "$E/obs/c4b-stop-t" "$t"
  OT=$((SETTLE_MAX + 30)) O sandbox stop "$SBX" >"$E/obs/c4b-stop.out" 2>"$E/obs/c4b-stop.err"; rc=$?
  echo "stop_rc=$rc stop_cli_ms=$(( $(ems) - t ))" >>"$E/obs/c4b-times.txt"
  [ "$rc" = 0 ] || nr "stop-refused-rc$rc"
  waitfor $((t + SETTLE_MAX * 1000)) sbx_phase_is Stopped || nr "stop-rc$rc-not-Stopped-within-${SETTLE_MAX}s"
  echo "stopped_ms=$(( $(ems) - t ))" >>"$E/obs/c4b-times.txt"
  # proposal 5.3: the CR exists and is suspended, no pod remains, the attachment is released (gates, not notes)
  nopods() { ident c4b-stopped >/dev/null 2>&1; [ "$(jq '.items | length' "$E/obs/c4b-stopped-C-pods.json" 2>/dev/null)" = 0 ]; }
  waitfor $(( $(ems) + SETTLE_MAX * 1000 )) nopods || nr "pods-remain-while-Stopped"
  jq -e '.uid != null and .deletionTimestamp == null' "$E/obs/c4b-stopped-C-cr.json" >/dev/null 2>&1 || nr "sandbox-CR-missing-or-deleting-while-Stopped"
  jq -e '.operatingMode == "Suspended" or .replicas == 0' "$E/obs/c4b-stopped-C-cr.json" >/dev/null 2>&1 || nr "sandbox-CR-not-suspended-while-Stopped"
  waitfor $(( $(ems) + SETTLE_MAX * 1000 )) va_released c4b-stopped || nr "volume-attachment-not-released-within-${SETTLE_MAX}s"
  vread c4b-stopped || { echo "step=c4b value=lost reason=volume-unreadable-after-stop" | tee "$E/obs/c4b-result.txt"; stop "C4b: PVC/PV not readable after stop (no start issued)"; }
  for f in pvc_uid pv pv_uid volume_handle; do
    [ "$(jq -r ".$f" "$L/c4a-R-V.json")" = "$(jq -r ".$f" "$L/c4b-stopped-V.json")" ] || { echo "step=c4b value=lost reason=$f-changed" | tee "$E/obs/c4b-result.txt"; stop "C4b: volume identity changed ($f); no start issued"; }
  done
  jq -e '.pvc_deleting == false and .pv_deleting == false' "$L/c4b-stopped-V.json" >/dev/null || { echo "step=c4b value=lost reason=volume-deleting" | tee "$E/obs/c4b-result.txt"; stop "C4b: PVC or PV is being deleted; no start issued"; }
  t=$(ems); put1 "$E/obs/c4b-start-t" "$t"
  OT=$((SETTLE_MAX + 30)) O sandbox start "$SBX" >"$E/obs/c4b-start.out" 2>"$E/obs/c4b-start.err"; rc=$?
  echo "start_rc=$rc start_cli_ms=$(( $(ems) - t ))" >>"$E/obs/c4b-times.txt"
  # the relaunched canonical command either runs (Ready) or the launcher refuses and the main process exits
  # (Error, MainProcessFailed): a refusal is a C4b state result read from the workload log, not a restart failure
  ready_or_exited() { case $(phase_now) in Ready | Error | Completed) return 0 ;; esac; return 1; }
  waitfor $((t + SETTLE_MAX * 1000)) ready_or_exited || nr "start-rc$rc-not-Ready-within-${SETTLE_MAX}s"
  ph2=$(phase_now); echo "phase_after_start=$ph2 settled_ms=$(( $(ems) - t ))" >>"$E/obs/c4b-times.txt"; echo "$(ems)" >"$E/obs/c4b-started"
  workload_resolve c4b-start || nr "no-single-workload-pod-after-start"
  [ "$(cat "$E/wuid")" != "$(cat "$E/obs/c4a-old-wuid")" ] || nr "workload-pod-uid-unchanged-after-start"
  if [ "$ph2" = Ready ]; then [ "$rc" = 0 ] || nr "start-refused-rc$rc"; fi
  launcher_log=""
  if [ "$ph2" != Ready ]; then # read the fixed refusal phrase from the exited launcher's log (local copy only)
    K -n "$NS" logs "$(WPOD)" -c agent >"$L/logs/c4b-launcher.log" 2>&1
    launcher_log=$(sed -n 's/^exp008c4-launch: \(.*\); not starting the agent$/\1/p' "$L/logs/c4b-launcher.log" | tail -n 1 | tr -cd 'A-Za-z0-9 ().=,-')
  fi
  vread c4b-started || log "C4b: V unreadable after start"
  # the launcher freezes the state and writes its precheck (or a refusal) before exec: wait up to 60 s for either
  lrec() { kx X9 "$E/obs/c4b-launch-summary.txt" 20 && grep -q -E '^## (precheck-2|refusals)$' "$E/obs/c4b-launch-summary.txt"; }
  if [ "$ph2" = Ready ]; then waitfor $(( $(ems) + 60000 )) lrec || log "C4b: no precheck-2 or refusal record within 60 s"; fi
  pre_ok=false; kx X10 "$L/task/c4b-pre.tar" 60 && mkdir -p "$L/task/c4b-pre" && tar -xf "$L/task/c4b-pre.tar" -C "$L/task/c4b-pre" && pre_ok=true
  awk '/^## precheck-2$/{f=1; next} /^## /{f=0} f' "$E/obs/c4b-launch-summary.txt" >"$E/obs/c4b-precheck.txt"
  refusal=$(awk '/^## refusals$/{f=1; next} /^## /{f=0} f && /^refused=/' "$E/obs/c4b-launch-summary.txt" 2>/dev/null | tail -n 1 | sed 's/^refused=//')
  nz "$refusal" || refusal=$launcher_log
  lmode=$(awk '/^## identity-2$/{f=1; next} /^## /{f=0} f && /^mode=/' "$E/obs/c4b-launch-summary.txt" 2>/dev/null | sed 's/^mode=//')
  listed=$(grep -q '^## precheck-2$' "$E/obs/c4b-launch-summary.txt" 2>/dev/null && echo true || echo false)
  vafter=$L/c4b-started-V.json; [ -s "$vafter" ] || vafter=$L/c4b-stopped-V.json
  pc=$(awk -F= 'NF >= 2 {k=$1; sub(/^[^=]*=/, ""); printf "%s\t%s\n", k, $0}' "$E/obs/c4b-precheck.txt" | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add // {}')
  present=$( [ "$pre_ok" = true ] && [ -s "$E/obs/c4b-precheck.txt" ] && echo true || echo false)
  jq -n --arg rd "$L/task/c4a-R" --arg pd "$L/task/c4b-pre" --arg rt "$L/tr/c4a-R.jsonl" --arg pt "$L/task/c4b-pre/transcript.jsonl" \
    --slurpfile vb "$L/c4a-R-V.json" --slurpfile va "$vafter" --arg sid "$(kv state_id_sha256 "$E/obs/c4a-R-X8.txt")" \
    --arg tok "$(kv token_file_sha256 "$E/obs/c4a-R-X8.txt")" --argjson pc "$pc" --argjson present "$present" --arg ref "$refusal" \
    --arg lmode "${lmode:-unknown}" --argjson listed "$listed" --arg ph2 "$ph2" \
    '{R_dir: $rd, pre_dir: $pd, R_transcript: $rt, pre_transcript: $pt, V_before: $vb[0], V_after: $va[0], R_state_id_sha256: $sid,
      R_token_file_sha256: $tok, precheck: $pc, precheck_present: $present, launcher_refusal: $ref, launch_mode: $lmode,
      precheck_listed: $listed, phase_after_start: $ph2}' >"$L/c4b-bundle.json"
  "${M4[@]}" c4b "$L/c4b-bundle.json" >"$E/metrics/c4b.json" || stop "C4b: comparator failed"
  { echo "step=c4b value=$(jq -r .value "$E/metrics/c4b.json") in_flight_state=$(jq -r .in_flight_state "$E/metrics/c4b.json") chain_broken_by_fault=$(jq -r .chain_broken_by_fault "$E/metrics/c4b.json") allowance=$(jq -r '(.allowance // []) | join(",")' "$E/metrics/c4b.json") reasons=$(jq -r '(.reasons // []) | join(",")' "$E/metrics/c4b.json")"
    echo "launcher_refusal=${refusal:-none} approval_tail=$(kv approval_tail "$E/obs/c4b-precheck.txt") claude_code_env_names=$(kv claude_code_env_names "$E/obs/c4b-precheck.txt")"
    cat "$E/obs/c4b-times.txt"; } | tee "$E/obs/c4b-result.txt"
  grab_logs c4b; echo "$(ems)" >"$E/obs/c4b-done"
  log "C4b done"
  ;;
c4c)
  guard_full; need c4b; once c4c
  start_t=$(( $(cat "$E/obs/c4b-started") + $(sed -n 's/^skew_ms=\(-\{0,1\}[0-9]*\) .*/\1/p' "$E/obs/c0-clock.txt" 2>/dev/null || echo 0) )) # workload clock
  m=$(cat "$E/obs/M_s"); wa=$(awk -v m="$m" 'BEGIN {h = 4 * m; if (h < 120) h = 120; printf "%d", h}')
  # process axis: new-process; not-started (the launcher refused, or the workload is readable and no claude
  # process runs); unreadable (the exec itself failed: never counted as not-started); same-as-original (impossible)
  if waitfor $(( $(ems) + 60000 )) ident c4c-start; then
    if [ "$(sed -n 's/^nonce=//p' "$E/obs/c4c-start-P.txt")" = "$(sed -n 's/^nonce=//p' "$E/obs/c4a-R-P.txt")" ]; then proc="same-as-original"
    elif nz "$(pkeys c4c-start)" && [ "$(pkeys c4c-start)" != "$(pkeys c4a-R)" ]; then proc="new-process"
    else proc="unreadable"; fi
    echo "launcher_mode_after_start=$(sed -n 's/^mode=//p' "$E/obs/c4c-start-P.txt")" >>"$E/obs/c4c-mode.txt"
  elif ! grep -q '^launcher_refusal=none' "$E/obs/c4b-result.txt" 2>/dev/null; then proc="not-started"
  elif grep -q '^mode=' "$E/obs/c4c-start-P.txt" 2>/dev/null && ! grep -q '^proc=' "$E/obs/c4c-start-P.txt"; then proc="not-started"
  else proc="unreadable"; fi
  echo "process=$proc" >"$E/obs/c4c-times.txt"
  probe_typed=false cont_typed=false dialogs='{}'
  if [ "$proc" = new-process ]; then
    # (a) no client and no input for max(4M, 120 s)
    ta=$(ems); while [ "$(ems)" -lt $((ta + wa * 1000)) ]; do sleep 10; spend_check; [ -z "$(client_scan)" ] || stop "C4c: a client appeared during (a)"; done
    snap c4c-a || log "C4c: snapshot after (a) failed"
    "${M4[@]}" activity "$L/tr/c4c-a.jsonl" "$(wc -c <"$L/task/c4b-pre/transcript.jsonl" 2>/dev/null || echo 0)" >"$E/metrics/c4c-a-activity.json" 2>/dev/null
    echo "a_window_s=$wa" >>"$E/obs/c4c-times.txt"
    # (b) attach, capture, probe (first input)
    client_start r1 || stop "C4c: connect failed"
    for _ in $(seq 1 30); do [ -s "$L/term/r1.raw" ] && break; sleep 1; done
    sleep 5; cap r1 replay; redraw r1; cap r1 redraw
    [ "$(jq -r .coherent "$E/term/r1-redraw.json")" = true ] || { ctrl_l r1; cap r1 ctrl-l; }
    "${TM[@]}" capture-pane -p -J -S - -t r1 >"$L/term/r1-history.txt" 2>/dev/null
    screen_flags "$L/term/r1-history.txt" >"$E/term/r1-flags.json"
    dialogs=$(jq -c '{trust: .trust_dialog, custom_key: .custom_key_dialog, resume_summary: .resume_summary_dialog}' "$E/term/r1-flags.json")
    kx X2 "$E/obs/c4c-probe-T.txt" 15
    tok=PROBE-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'); echo "$tok" >"$L/c4c-probe"
    type_line r1 "Reply on one line exactly: $tok CODEWORD=<the codeword I gave you> LAST=<number of the last step that printed STEP OK>. Do not run any tool for this reply." probe && probe_typed=true
    last_in=$(ems)
    echo "probe_t=$(ems)" >>"$E/obs/c4c-times.txt"
    pb=$(wc -c <"$L/task/c4b-pre/transcript.jsonl" 2>/dev/null || echo 0)
    lastdone=$(( $(jq -r .in_flight_step "$E/metrics/c4b.json") - 1 ))
    dd=$(( $(ems) + 240000 ))
    while [ "$(ems)" -lt "$dd" ]; do
      sleep 10; spend_check
      kx X3T "$L/tr/c4c-probe.jsonl" 60 || continue
      "${M4[@]}" probe4 "$L/tr/c4c-probe.jsonl" "$tok" "$L/codeword" "$lastdone" "$pb" >"$E/metrics/c4c-probe.json" || continue
      [ "$(jq -r .reply "$E/metrics/c4c-probe.json")" = true ] && break
    done
    echo "probe_wait_end=$(ems)" >>"$E/obs/c4c-times.txt"
    # (c) if step N was not accepted within 2M of the reply (or of the probe timeout): one fixed continuation line
    n=$(jq -r .in_flight_step "$E/metrics/c4b.json"); a0=$(task_count attempts "$E/obs/c4a-R-T.txt")
    acc() { kx X2 "$E/obs/c4c-acc.txt" 15 && [ "$(task_count attempts "$E/obs/c4c-acc.txt")" -gt "${a0:-0}" ]; }
    if ! waitfor $(( $(ems) + $(awk -v m="$m" 'BEGIN {printf "%d", 2 * m * 1000}') )) acc; then
      type_line r1 "Continue the task." continue && cont_typed=true && last_in=$(ems)
      echo "continue_t=$(ems)" >>"$E/obs/c4c-times.txt"
    fi
    # (d) until done for N, N+1, N+2, or 6M after the last input; caps: 20 min after start (guard), 10 refusals
    r0=$(task_count refusals "$E/obs/c4a-R-T.txt")
    while [ "$(ems)" -lt $((last_in + $(awk -v m="$m" 'BEGIN {printf "%d", 6 * m * 1000}'))) ]; do
      sleep 10; guard_full
      kx X2 "$E/obs/c4c-d.txt" 15 || continue
      [ $(( $(task_count refusals "$E/obs/c4c-d.txt") - ${r0:-0} )) -le "$REFUSAL_MAX" ] || { echo "refusal_cap=hit" >>"$E/obs/c4c-times.txt"; break; }
      [ "$(sed -n 's/^progress=[0-9]* last=done n=\([0-9]*\) .*/\1/p' "$E/obs/c4c-d.txt")" -ge $((n + 2)) ] 2>/dev/null && break
    done
    cap r1 final; client_detach r1
  fi
  snap c4c-final || log "C4c: final snapshot incomplete"
  kx X2 "$E/obs/c4c-final-T.txt" 15
  names=$(sed -n 's/^tr=\([^ ]*\) .*/\1/p' "$E/obs/c4c-final-T.txt" | jq -R . | jq -s -c .)
  jq -n --slurpfile c4b "$E/metrics/c4b.json" --arg rd "$L/task/c4a-R" --arg fd "$L/task/c4c-final" --arg rt "$L/tr/c4a-R.jsonl" \
    --arg pt "$L/task/c4b-pre/transcript.jsonl" --arg ft "$L/tr/c4c-final.jsonl" --argjson names "${names:-[]}" --arg rn "$(basename -- "$(cat "$E/tr_rel")")" \
    --arg proc "$proc" --argjson refused "$(grep -q '^launcher_refusal=none' "$E/obs/c4b-result.txt" && echo false || echo true)" \
    --arg tok "$(cat "$L/c4c-probe" 2>/dev/null)" --arg cw "$(cat "$L/codeword")" --argjson last "[$(( $(jq -r '.in_flight_step // 1' "$E/metrics/c4b.json") - 1 ))]" \
    --argjson ctl "$(jq -r '.pass // false' "$E/metrics/c0-control.json")" --argjson m "$m" --argjson st "$start_t" \
    --argjson dialogs "$dialogs" --argjson ss "$([ -e "$E/obs/spend-stopped" ] && echo true || echo false)" \
    --argjson pt_ "$probe_typed" --argjson ct "$cont_typed" \
    '{c4b: $c4b[0], R_dir: $rd, final_dir: $fd, R_transcript: $rt, pre_transcript: $pt, final_transcript: $ft, transcripts_after: $names,
      R_transcript_name: $rn, process: $proc, launcher_refused: $refused, probe_token: $tok, codeword: $cw, expected_last: $last,
      control_pass: $ctl, M_s: $m, start_t: $st, dialogs: $dialogs, spend_stop: $ss, probe_typed: $pt_, continue_typed: $ct}' >"$L/c4c-bundle.json"
  "${M4[@]}" c4c "$L/c4c-bundle.json" >"$E/metrics/c4c.json" || stop "C4c: classifier failed"
  { echo "step=c4c resume=$(jq -r .axes.resume "$E/metrics/c4c.json") decision=$(jq -r .decision_path "$E/metrics/c4c.json") primary_pass=$(jq -r .primary_pass "$E/metrics/c4c.json")"
    jq -r '.axes | to_entries | map("\(.key)=\(.value)") | join(" ")' "$E/metrics/c4c.json"
    cat "$E/obs/c4c-times.txt"; } | tee "$E/obs/c4c-result.txt"
  grab_logs c4c; echo "$(ems)" >"$E/obs/c4c-done"
  log "C4c done"
  ;;
cleanup)
  # cleanup is the stop path: it runs once even after a STOP (its own marker), and also when create failed.
  # It never stops or starts the sandbox and never touches the gateway: it waits for a settled phase and deletes.
  [ ! -e "$E/done-cleanup" ] || fail "cleanup already ran (single attempt)"; echo "$(now)" >"$E/done-cleanup"
  [ -e "$E/STOPPED" ] && log "cleanup after STOP: $(tail -n 1 "$E/STOPPED")"
  guard_ctx || stop "guard failed before cleanup"
  [ "$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.spec.replicas}')" = "$(ref gw_replicas)" ] || log "cleanup: gateway replicas differ from pre (not changed by C4; recorded for the owner)"
  "${TM[@]}" kill-server 2>/dev/null; sleep 1
  [ -z "$(client_scan)" ] || { client_scan >"$E/obs/cleanup-clients.txt"; log "cleanup: client processes remain (see obs)"; }
  # read-only discovery before any delete (a failed create is never reported as a deletion)
  disc=no-create
  if [ -e "$E/done-c0-create" ]; then
    disc=$(sbx_discover); log "cleanup: $(cat "$E/obs/cleanup-discovery.txt")"
    case $disc in present | absent) ;; *) stop "cleanup: sandbox discovery $disc; no delete issued and absence not assumed. Cleanup is single-attempt and will not rerun: the owner inspects read-only (sandbox get $SBX, Sandbox CR list) and, only if it is this run's sandbox, deletes exactly $SBX by hand; then post. See obs/cleanup-discovery.txt" ;; esac
  else echo "discovery=not-run reason=no-create-request cli_rc=none cr_total=none cr_matching=none" >"$E/obs/cleanup-discovery.txt"; fi
  if [ ! -s "$E/sbx_id" ]; then
    [ "$disc" = present ] && jq -r '.id // empty' "$E/obs/cleanup-sbx.json" >"$E/sbx_id"
    [ -s "$E/sbx_id" ] || { echo none >"$E/sbx_id"; log "cleanup: no sandbox id recorded or resolvable; checking residue by name only"; }
  fi
  if [ ! -s "$E/tr_rel" ] && [ -s "$E/wctr" ] && [ "$(cat "$E/sbx_id")" != none ]; then
    bash "$(readlink -f "$0")" "$RUN" _tr_probe cleanup >/dev/null 2>&1; log "cleanup: transcript path located before final snapshot: $([ -s "$E/tr_rel" ] && echo yes || echo no)"
  fi
  snap cleanup-final || log "cleanup: final snapshot incomplete (no readable workload is expected after C4a/while Stopped)"
  [ -s "$L/tr/cleanup-final.jsonl" ] && { "${M0[@]}" usage "$L/tr/cleanup-final.jsonl" >"$E/metrics/final-usage.json" 2>/dev/null || log "cleanup: final usage estimate failed (Console figure is authoritative)"; }
  grab_logs cleanup-pre
  # settle: never delete during Stopping/Starting/Provisioning; wait up to SETTLE_MAX for a settled phase
  if [ "$disc" = present ]; then
    ph=$(phase_now); echo "phase_at_cleanup=${ph:-unreadable}" >"$E/obs/cleanup-phase.txt"
    settled() { case $(phase_now) in Stopping | Starting | Provisioning | Suspending) return 1 ;; esac; }
    case $ph in Stopping | Starting | Provisioning | Suspending) waitfor $(( $(ems) + SETTLE_MAX * 1000 )) settled \
      || log "cleanup: phase did not settle within ${SETTLE_MAX}s; deleting anyway"; echo "phase_settled=$(phase_now)" >>"$E/obs/cleanup-phase.txt" ;; esac
  fi
  vread cleanup-pre >/dev/null 2>&1 || true
  { K -n "$NS" get pvc -o json | jq -r --arg s "$(cat "$E/sbx_id")" '.items[] | select(.metadata.labels["openshell.ai/sandbox-id"] == $s or .metadata.labels["openshell.ai/boundary-pair"] == $s or (.metadata.name | contains("'"$SBX"'"))) | "\(.metadata.name) \(.spec.volumeName)"'
    for f in "$L"/c0-V.json "$L"/c4a-R-V.json "$L"/cleanup-pre-V.json; do [ -s "$f" ] && jq -r '"\(.pvc_name) \(.pv)"' "$f"; done; } | sort -u >"$E/obs/cleanup-pvcs.txt"
  case $disc in
  present) OT=180 O sandbox delete "$SBX" >"$E/obs/cleanup-delete.out" 2>"$E/obs/cleanup-delete.err"; rc=$?; log "sandbox delete rc=$rc"; echo "delete=issued delete_rc=$rc" >>"$E/obs/cleanup-discovery.txt" ;;
  absent) log "cleanup: delete=skipped-verified-absent (the create request left no sandbox)"; echo "delete=skipped-verified-absent" >>"$E/obs/cleanup-discovery.txt" ;;
  *) log "cleanup: c0-create never ran; no delete issued"; echo "delete=not-issued-no-create" >>"$E/obs/cleanup-discovery.txt" ;;
  esac
  id=$(cat "$E/sbx_id")
  KINDS=pods,pvc,secret,service,networkpolicy,configmap,serviceaccount,role,rolebinding
  objs() { local o o2 o3 c pv pv2 va; o=$(K -n "$NS" get "$KINDS" -l "openshell.ai/sandbox-id=$id" -o name 2>/dev/null) || return 1; o2=$(K -n "$NS" get "$KINDS" -l "openshell.ai/boundary-pair=$id" -o name 2>/dev/null) || return 1
    local pat=(-e "$SBX"); [ "$id" != none ] && pat+=(-e "$id")
    o3=$(K -n "$NS" get "$KINDS" -o name 2>/dev/null | grep -F "${pat[@]}"); c=$(sandboxes_all 2>/dev/null) || return 1
    pv="" va=""; while read -r _ v; do nz "$v" && [ "$v" != null ] && { K get pv "$v" -o name >/dev/null 2>&1 && pv="$pv pv/$v"; va="$va$(K get volumeattachments -o json 2>/dev/null | jq -r --arg v "$v" '.items[] | select(.spec.source.persistentVolumeName == $v) | " volumeattachment/" + .metadata.name')"; }; done <"$E/obs/cleanup-pvcs.txt"
    pv2=$(K get pv -o jsonpath='{range .items[*]}{.metadata.name} {.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}{end}' 2>/dev/null | grep -F "${pat[@]}" | grep "^[^ ]* $NS/" || true)
    printf '%s%s%s%s%s%s%s' "$o" "$o2" "$o3" "$c" "$pv" "$pv2" "$va"; }
  gone() { local x; x=$(objs) || return 1; [ -z "$x" ]; }
  waitfor $(($(ems) + 300000)) gone || { objs >"$E/obs/cleanup-residue.txt"; stop "cleanup: experiment objects remain (see obs/cleanup-residue.txt; no manual finalizer/controller action; owner decides)"; }
  { K -n "$NS" get ciliumnetworkpolicies -o name 2>/dev/null | grep -F -e "$SBX" $([ "$id" != none ] && printf -- '-e %s' "$id") || true; } >"$E/obs/cleanup-cilium-residue.txt"
  [ -s "$E/obs/cleanup-cilium-residue.txt" ] && stop "cleanup: Cilium policy residue (see obs/cleanup-cilium-residue.txt)"
  echo "$(ems)" >"$E/obs/cleanup-done"
  log "experiment objects gone ($KINDS by labels and names, Sandbox CRs, PVs and VolumeAttachments of the recorded PVCs, Cilium policies)"
  ;;
post)
  # read-only, re-runnable; every run is kept as inv/post-N. Only providers and profiles may differ from pre:
  # Phase 1 changes no gateway object, so ANY gateway StatefulSet generation or gateway pod UID change is NOT-CLEAN.
  n=1; while [ -e "$E/inv/post-$n" ]; do n=$((n + 1)); done
  P=$E/inv/post-$n D=$E/inv/diff-$n; mkdir -p "$D"
  inventory "$P"
  for f in "$E"/inv/pre/*; do b=${f##*/}; d="$D/diff-${b%.txt}.txt"; diff -u "$f" "$P/$b" >"$d" 2>&1 && rm -f "$d"; done
  (cd "$D" && ls diff-* 2>/dev/null) >"$E/inv/diff-files-$n.txt" || true
  grep -v -x -E 'diff-(providers|profiles)\.txt' "$E/inv/diff-files-$n.txt" >"$E/inv/unexpected-diffs-$n.txt" || true
  gen=$(bash "$C0/restore-check.sh" generation "$E/inv/pre/gw-sts-generation.txt" "$P/gw-sts-generation.txt" /dev/null)
  prv=$(bash "$C0/restore-check.sh" names "$E/inv/pre/providers.txt" "$P/providers.txt" "$PROV")
  prf=$(bash "$C0/restore-check.sh" names "$E/inv/pre/profiles.txt" "$P/profiles.txt" "$PROF")
  { echo "post_run=$n"; echo "gw_sts_generation=$gen"; echo "gw_pod_uid=$([ "$(cat "$E/inv/pre/gw-pod-uid.txt")" = "$(cat "$P/gw-pod-uid.txt")" ] && echo unchanged || echo CHANGED)"; echo "providers=$prv"; echo "profiles=$prf"; } >"$E/inv/restore-checks-$n.txt"
  v=$(bash "$C0/restore-check.sh" verdict "$E/inv/unexpected-diffs-$n.txt" "$gen" "$prv" "$prf")
  v=${v/generation explained by recorded scale operations/gateway generation and pod unchanged}
  { echo "$v"; cat "$E/inv/restore-checks-$n.txt"; [ -e "$E/done-cleanup" ] || echo "note: cleanup step has not run"; } >"$E/inv/restoration-$n.txt"
  cp "$E/inv/restoration-$n.txt" "$E/inv/restoration.txt"; cat "$E/inv/restoration.txt"
  log "post run $n: $v; $(tr '\n' ' ' <"$E/inv/restore-checks-$n.txt")"
  ;;
logout) O gateway logout "$GWNAME" >"$E/obs/logout.out" 2>&1; log "gateway logout rc=$?" ;;
*) echo "unknown step $STEP" >&2; exit 2 ;;
esac
