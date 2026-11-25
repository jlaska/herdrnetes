#!/usr/bin/env bash
# EXP-008 Stage C harness (C0-C3 only): a real Claude Code agent as the canonical main process of one
# OpenShell 0.1.9 Kubernetes-driver sandbox, on the EXISTING Stage B installation.
# Plan and approval request: README.md in this directory. Nothing here is authorized until the owner
# approves that execution package; preparation and offline tests do not touch the cluster.
#
#   stagec.sh <RUN> <step> [arg]
#   steps (the lead runs them by hand, in this order, and decides between them):
#     pre            read-only: refs, guards, Argo Synced/Healthy, digests, provider present (names only), inventory
#     sampler-start  read-only background samplers (pods, CR, events, sandbox get, P every 5 s, task every 10 s)
#     c0-create      M1  create the sandbox (provider attached, fixed image digest and launcher)
#     c0-baseline    X*  identity, credential-boundary checks, egress probes, first attach (M2) + codeword (M3), M
#     c1             M4  abrupt kill of the only client while working; hold >= 4M detached; window metrics
#     c1-reattach    M2/M3  C3a: fresh client, replay + redraw captures, one probe, Q/R metrics; clean detach
#     c2             M5  gateway scale 0 -> 90 s -> 1 while detached and working; window metrics
#     c2-reattach    M2/M3  C3b: as c1-reattach
#     cleanup        M6  stop clients, delete the sandbox, residue check, replicas restored
#     post           read-only post-run inventory + diff against this run's pre inventory
#     sampler-stop | logout (M7) | ident <label> | snap <label> | spend
#
# Single attempt: every mutating step writes done-<step> before its first mutation and refuses to run twice;
# nothing runs after a STOP (exit 3). A FAIL (exit 4) is a harness precondition failure.
#
# MUTATION ALLOWLIST (complete; everything else is refused by the wrappers):
#   M1 openshell sandbox create --name $SBX --from $IMG --provider $PROV ... -- <fixed launcher>   c0-create
#   M2 openshell sandbox connect $SBX, run by the harness inside its own local tmux server        c0-baseline, c*-reattach
#   M3 typing one fixed-form line (+Enter) into that harness-owned tmux pane                        c0-baseline, c*-reattach
#   M4 SIGKILL of the harness-owned client process tree (local processes only)                     c1
#   M4b Ctrl-P Ctrl-Q (clean detach) into that pane; SIGKILL fallback after 10 s                   c*-reattach
#   M3b Ctrl-L (Claude Code's documented full redraw; keeps input) only if the resize redraw was not coherent
#   M5 kubectl -n openshell scale statefulset/openshell --replicas=0|<pre value>                    c2 (+ rollback)
#   M6 openshell sandbox delete $SBX                                                                cleanup (or emergency)
#   M7 openshell gateway logout $GWNAME (isolated local CLI config)                                logout
#   M8 openshell sandbox exec $SBX --no-tty --no-login-shell --timeout 60 -- python3 -I -c <X5PY>     c0-baseline
#      (network probes only: TCP connects to a disallowed host and to api.anthropic.com from a binary the
#       profile does not name; no HTTP request, no credential use, nothing written)
# kubectl exec: only into THIS sandbox's workload pod (labels re-checked), only the fixed scripts X1-X7 below.
# The OpenShell provider, the Console key, profile import (if any), OIDC login and the GitOps freeze are
# OWNER steps; this harness never creates, reads or deletes a credential.
set -uo pipefail
[ "$#" -ge 2 ] || { echo "usage: stagec.sh <RUN> <step> [arg]" >&2; exit 2; }
RUN=$1 STEP=$2 ARG=${3:-}
[[ $RUN =~ ^[0-9]{4}-[0-9]{4}$ ]] || { echo "bad RUN (MMDD-HHMM)" >&2; exit 2; }
[[ $ARG =~ ^[A-Za-z0-9_-]{0,32}$ ]] || { echo "bad arg" >&2; exit 2; }

HX=$HOME/.cache/hxc
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
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
SBX=exp008c-${RUN} # the ONLY sandbox this harness may create/delete
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
OUTAGE_MAX=240        # gateway Ready within 240 s of scale-down, or STOP
WALL_MAX=5400         # 90 min from c0-create
FREEZE_END_LOCAL=30   # 00:30 America/New_York; Renovate's automerge window opens at 01:00
JWT_MARGIN=900        # c2 must start >= 15 min before the earliest supervisor-token expiry annotation
# Spend guard: Haiku 5.5 list prices (USD/MTok, prompts <= 100K): input 0.10, output 0.50; cache write/read
# taken as the standard 1.25x / 0.1x multipliers (inference). Applied to transcript usage; STOP at 80 %.
PRICES="0.10 0.125 0.01 0.50"
export TZ=America/New_York
KUBECTL_DIR=$HOME/.local/share/mise/installs/kubectl/1.36.5
GH=$(ls -d "$HOME"/.local/share/mise/installs/gh/*/gh_*/bin/gh 2>/dev/null | sort -V | tail -n 1)
PATH=$KUBECTL_DIR:/usr/bin:/bin
export PATH
for b in "$KUBECTL_DIR/kubectl" "$GH" /usr/bin/jq /usr/bin/python3 /usr/bin/tmux; do [ -x "$b" ] || { echo "missing $b" >&2; exit 2; }; done
KC=("$KUBECTL_DIR/kubectl" --context "$CTX")
# shellcheck source=launcher.sh
. "$HERE/launcher.sh"
TM=(/usr/bin/tmux -L "exp008c-$RUN" -f /dev/null)

umask 077
mkdir -p "$HX/run" && mkdir -p -m 700 "$R" "$E" "$E/obs" "$E/inv" "$E/term" "$E/metrics" "$L" "$L/tr" "$L/term" "$L/logs" "$L/task"
for d in "$HX" "$R" "$L"; do [ "$(stat -c %a "$d")" = 700 ] || { echo "$d must be 0700" >&2; exit 2; }; done
[ "$(sha256sum "$CLI" | cut -d' ' -f1)" = "$CLI_SHA" ] || { echo "CLI sha256 mismatch" >&2; exit 2; }
# The harness environment must not carry credentials the CLI could upload (proposal 5.1 MUST-2/3).
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
kw() { # kubectl, mutating: exact allowlist only (M5); logged before it runs
  local f="$*"
  case $f in
  "scale statefulset/$GW_STS --replicas=0") guard_ctx || stop "kube identity guard failed before: $f" ;;
  "scale statefulset/$GW_STS --replicas=$(ref gw_replicas)") ;; # scale-up/rollback is never blocked by a guard
  *) log "REFUSED kw $f"; return 97 ;;
  esac
  log "MUTATE kubectl -n $NS $f"
  "${KC[@]}" --request-timeout=20s -n "$NS" "$@"
}

# ---------------------------------------------------------------- exec: fixed read-only scripts, this workload only
# X1 identity: the launcher's record + the live main process (exe, start, nonce, placeholder form; never values)
# The case pattern is split with '' so this script's own command line cannot match it.
X1='cat /sandbox/c/launch/identity 2>/dev/null; echo boot_id=$(cat /proc/sys/kernel/random/boot_id); echo uid=$(id -u); for p in /proc/[0-9]*; do q=${p#/proc/}; [ "$q" = "$$" ] && continue; x=$(readlink $p/exe 2>/dev/null); case "$x" in /usr/local/bin/cla''ude) f() { case "$1" in "") echo absent;; openshell:resolve:*) echo placeholder;; sk-ant-*) echo REAL-KEY-SHAPE;; *) echo other;; esac; }; ev() { tr "\0" "\n" <$p/environ 2>/dev/null | sed -n "s/^$1=//p"; }; n=$(ev EXP008_NONCE); echo "proc=$q start=$(sed "s/.*) //" $p/stat | awk "{print \$20}") ppid=$(awk "/^PPid/{print \$2}" $p/status) nonce=${n:-unreadable} keyref_form=$(f "$(ev EXP008_ANTHROPIC_KEYREF)") key_form=$(f "$(ev ANTHROPIC_API_KEY)")";; esac; done'
# X2 task state (counts and last lines only; the logs carry timestamps and step numbers, no model text)
X2='cd /sandbox/c/repo 2>/dev/null || exit 9; for f in attempts progress refusals ledger locks; do echo "$f=$(wc -l <$f.log 2>/dev/null || echo 0) last=$(tail -n 1 $f.log 2>/dev/null)"; done; t=$(ls /sandbox/c/claude/projects/*/*.jsonl 2>/dev/null); echo transcripts=$(echo "$t" | grep -c .); for x in $t; do echo "tr=$(basename $x) lines=$(wc -l <$x) bytes=$(wc -c <$x)"; done; echo lock=$(test -d .state/lock && echo held || echo free)'
# X3 copy: the task logs and the transcript (to $L only)
X3_LOGS='cd /sandbox/c/repo && tar -cf - $(ls attempts.log progress.log refusals.log ledger.log locks.log 2>/dev/null)'
X3_TR='cat /sandbox/c/claude/projects/'
# X4 credential boundary: count real-key-shaped strings in every process environment and under /sandbox (counts only)
X4='r=0; u=0; for p in /proc/[0-9]*/environ; do if tr "\0" "\n" <$p >/dev/null 2>&1; then r=$((r+1)); else u=$((u+1)); fi; done; echo "environ_readable=$r environ_unreadable=$u"; for p in /proc/[0-9]*/environ; do tr "\0" "\n" <$p 2>/dev/null | grep -c -E "^[A-Z_]+=sk-ant-" ; done | awk "{s+=\$1} END {print \"env_real_key_shape=\" s+0}"; echo "fs_real_key_shape_files=$(grep -r -l -I -E "sk-ant-(api|admin)[0-9]{2}-" /sandbox 2>/dev/null | wc -l)"; echo "fs_placeholder_files=$(grep -r -l -I -F "openshell:resolve:" /sandbox 2>/dev/null | wc -l)"'
# X5 network probes (stdlib socket only; prints outcome classes, never values or messages)
X5PY='import os,socket
k=os.environ.get("ANTHROPIC_API_KEY","")
print("probe_key_form="+("absent" if not k else "placeholder" if k.startswith("openshell:resolve:") else "REAL-KEY-SHAPE" if k.startswith("sk-ant-") else "other"))
for n,h in (("disallowed_host","example.com"),("anthropic_from_python","api.anthropic.com")):
    try:
        s=socket.create_connection((h,443),timeout=15); s.close(); print(n+"=connected")
    except Exception as e:
        print(n+"=blocked:"+type(e).__name__+":"+str(getattr(e,"errno","")))'
X5="python3 -I -c '$X5PY'"
# X6 clock
X6='date +%s%3N'
# X7 transcript directory name (one per cwd slug)
X7='ls -d /sandbox/c/claude/projects/*/ | head -n 1'
WPOD() { cat "$E/wpod" 2>/dev/null; }
wpod_ok() { # the recorded pod still carries THIS sandbox's workload labels
  local w r; w=$(WPOD); nz "$w" || return 1
  r=$(K -n "$NS" get pod "$w" -o jsonpath='{.metadata.labels.openshell\.ai/boundary-pair} {.metadata.labels.openshell\.ai/boundary-role}' 2>/dev/null) || return 1
  [ "$r" = "$(cat "$E/sbx_id") workload" ]
}
kx() { # kx <X1|X2|X3L|X3T|X4|X5|X6> <outfile> [timeout]
  local w c s; w=$(WPOD) c=$(cat "$E/wctr" 2>/dev/null); nz "$w" && nz "$c" || return 1
  wpod_ok || { echo "workload pod labels do not match this sandbox" >"$2.err"; return 1; }
  case $1 in X1) s=$X1 ;; X2) s=$X2 ;; X3L) s=$X3_LOGS ;; X3T) local r; r=$(cat "$E/tr_rel" 2>/dev/null); [[ $r =~ ^[A-Za-z0-9._-]{1,200}/[0-9a-f-]{36}\.jsonl$ ]] || { echo "bad transcript path" >"$2.err"; return 1; }; s="$X3_TR$r" ;; X4) s=$X4 ;; X5) s=$X5 ;; X6) s=$X6 ;; X7) s=$X7 ;; *) log "REFUSED kx $1"; return 97 ;; esac
  "${KC[@]}" --request-timeout="${3:-20}s" -n "$NS" exec "$w" -c "$c" -- sh -c "$s" >"$2" 2>"$2.err"
}
clock() { # clock <label>: skew = workload - workstation (ms), unc = half the round trip
  local a b r; a=$(ems); kx X6 "$E/obs/$1-clock.raw" 10 || return 1; b=$(ems); r=$(tr -dc 0-9 <"$E/obs/$1-clock.raw")
  nz "$r" || return 1
  echo "skew_ms=$((r - (a + b) / 2)) unc_ms=$(((b - a) / 2))" | tee "$E/obs/$1-clock.txt"
}
skew() { sed -n 's/^skew_ms=\(-\{0,1\}[0-9]*\) .*/\1/p' "$E/obs/$1-clock.txt"; }
margin() { local u; u=$(sed -n 's/.* unc_ms=\([0-9]*\)/\1/p' "$E/obs/$1-clock.txt"); echo $((${u:-0} + 1000)); }

# ---------------------------------------------------------------- CLI (isolated HOME; explicit -g; no credentials)
OENV=(env -i HOME="$HX/home" XDG_CONFIG_HOME="$HX/home/.config" XDG_DATA_HOME="$HX/home/.local/share"
  XDG_STATE_HOME="$HX/home/.local/state" XDG_CACHE_HOME="$HX/home/.cache" PATH=/usr/bin:/bin TERM=xterm-256color)
O() {
  local sub="$1 ${2:-}"
  case $sub in
  "sandbox get" | "sandbox list" | "gateway list") ;;
  "provider list") [ "$*" = "provider list --names" ] || { log "REFUSED O $*"; return 97; } ;;
  "sandbox exec") [ "$#" -eq 12 ] && [ "$3" = "$SBX" ] && [ "${*:4:7}" = "--no-tty --no-login-shell --timeout 60 -- python3 -I" ] && [ "${11}" = -c ] && [ "${12}" = "$X5PY" ] || { log "REFUSED O sandbox exec"; return 97; } ;;
  "sandbox create") [ "${3:-}" = --name ] && [ "${4:-}" = "$SBX" ] || { log "REFUSED O $*"; return 97; } ;;
  "sandbox delete") [ "${3:-}" = "$SBX" ] && [ "$#" -eq 3 ] || { log "REFUSED O $*"; return 97; } ;;
  "gateway logout") [ "${3:-}" = "$GWNAME" ] && [ "$#" -eq 3 ] || { log "REFUSED O $*"; return 97; } ;;
  *) log "REFUSED O $*"; return 97 ;;
  esac
  case $sub in "sandbox create" | "sandbox delete" | "gateway logout" | "sandbox exec") log "MUTATE openshell ${*:1:4}" ;; esac
  "${OENV[@]}" timeout -k 5 "${OT:-60}" "$CLI" -g "$GWNAME" "$@"
}
gw_registered() { O gateway list 2>/dev/null | grep -q -w "$GWNAME"; }
sbx_json() { OT=${OT:-20} O sandbox get "$SBX" -o json >"$1" 2>"$1.err"; }
sbx_phase() { jq -r '[.phase, .status.phase, .sandbox.phase, .sandbox.status.phase] | map(select(. != null)) | .[0] // empty' "$1" 2>/dev/null; }

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
providers() { OT=30 O provider list --names 2>/dev/null | sort; }
spend_check() { # STOP at 80 % of BUDGET_USD, estimated from transcript usage (the Console cap is the hard control)
  [ -s "$E/tr_rel" ] || return 0
  kx X3T "$L/tr/spend.jsonl" 30 || { log "spend: transcript copy failed (not a stop by itself)"; return 0; }
  # shellcheck disable=SC2086
  python3 -I "$HERE/metrics.py" usage "$L/tr/spend.jsonl" $PRICES >"$E/metrics/spend-latest.json" || return 0
  local u; u=$(jq -r .est_usd "$E/metrics/spend-latest.json")
  echo "$(now) est_usd=$u budget=$BUDGET_USD" >>"$E/obs/spend.txt"
  awk -v u="$u" -v b="$BUDGET_USD" 'BEGIN {exit !(u >= 0.8 * b)}' && stop "spend estimate $u >= 80% of $BUDGET_USD (run cleanup now)"
  return 0
}
guard_full() { # stop conditions checked at every step boundary
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
  if [ -s "$E/obs/c0-create-t0" ] && [ $(( ($(ems) - $(cat "$E/obs/c0-create-t0")) / 1000 )) -gt "$WALL_MAX" ]; then stop "wall clock over ${WALL_MAX}s since c0-create"; fi
  spend_check
  return 0
}

# ---------------------------------------------------------------- inventory (names/UIDs only for Secrets)
inventory() { # inventory <dir>
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
  K -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{" "}{end}{"\n"}{end}' >"$d/openshell-pod-images.txt" 2>&1
  K -n "$NS" get pvc -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,SC:.spec.storageClassName,VOL:.spec.volumeName,STATUS:.status.phase' >"$d/pvc.txt" 2>&1
  K get pv -o 'custom-columns=NAME:.metadata.name,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase' 2>&1 | awk -v ns="$NS" 'NR==1 || $2==ns' >"$d/pv-openshell.txt"
  K -n "$NS" get configmap openshell-config -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}' >"$d/gw-config.txt" 2>&1
  K -n agent-sandbox-system get deployment,pod,service,lease,role,rolebinding,secret -o 'custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid' >"$d/as-objects.txt" 2>&1
  K -n agent-sandbox-system get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{" rc="}{.restartCount}{end}{"\n"}{end}' >"$d/as-pods.txt" 2>&1
  K get clusterrole agent-sandbox-controller -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}{.rules}{"\n"}' >"$d/as-clusterrole.txt" 2>&1
  K get clusterrolebinding agent-sandbox-controller -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}' >"$d/as-clusterrolebinding.txt" 2>&1
  K get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>&1 | grep -i -E 'sandbox|openshell' >"$d/webhooks.txt"
  K get namespace "$NS" agent-sandbox-system -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,LABELS:.metadata.labels' >"$d/namespaces.txt" 2>&1
  { K -n "$NS" get ciliumnetworkpolicies; K get ciliumclusterwidenetworkpolicies; } >"$d/cilium.txt" 2>&1
  argo_state 2>&1 | awk '{print $1, $2, $3, $4}' >"$d/argo.txt"
  providers >"$d/providers.txt"
  OT=30 O sandbox list >"$d/sandbox-list.txt" 2>&1
}

# ---------------------------------------------------------------- identity snapshots
spods() { K -n "$NS" get pods -o json | jq --arg s "$1" --arg r "${2:-}" '{items: [.items[] | select((.metadata.labels["openshell.ai/sandbox-id"] == $s or .metadata.labels["openshell.ai/boundary-pair"] == $s) and ($r == "" or .metadata.labels["openshell.ai/boundary-role"] == $r))]}'; }
PODF='{items: [.items[] | {name: .metadata.name, uid: .metadata.uid, labels: .metadata.labels, annotations: (.metadata.annotations // {} | with_entries(select(.key | test("expires|generation|uid|readiness|topology|session|bootstrap")))), ownerReferences: [.metadata.ownerReferences[]? | {kind, name, uid}], deletionTimestamp: .metadata.deletionTimestamp, creationTimestamp: .metadata.creationTimestamp, node: .spec.nodeName, restartPolicy: .spec.restartPolicy, phase: .status.phase, conditions: .status.conditions, containerStatuses: [.status.initContainerStatuses[]?, .status.containerStatuses[]? | {name, containerID, imageID, restartCount, ready, started, state, lastState}]}]}'
CRF='{name: .metadata.name, uid: .metadata.uid, generation: .metadata.generation, labels: .metadata.labels, deletionTimestamp: .metadata.deletionTimestamp, operatingMode: .spec.operatingMode, conditions: .status.conditions}'
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
  grep -E '^(pid|start|nonce|boot_id|utc|uid)=' "$p" 2>/dev/null; grep '^proc=' "$p" 2>/dev/null
  echo "task: $(grep -E '^(attempts|progress|refusals|ledger|tr|lock)=' "$E/obs/$l-T.txt" 2>/dev/null | sed -E 's/ last=.* t=([^ ]+)( .*)?$/ last_t=\1/' | tr '\n' ' ')"
  jq -r '.items[] | "pod \(.labels["openshell.ai/boundary-role"] // "?") name=\(.name) uid=\(.uid) phase=\(.phase) node=\(.node) del=\(.deletionTimestamp // "-") \([.containerStatuses[] | "\(.name):cid=\(.containerID // "-"|.[-12:]) rc=\(.restartCount) ready=\(.ready)"]|join(" "))"' "$E/obs/$l-C-pods.json" 2>/dev/null
  echo "gwpod=$(cat "$E/obs/$l-G-gwpod.txt" 2>/dev/null)"
  echo "G phase=$(sbx_phase "$E/obs/$l-G-sandbox.json") instance=$(jq -r '[.. | .main_process_instance_id? // empty][0] // "-"' "$E/obs/$l-G-sandbox.json" 2>/dev/null)"
}
# P: launcher record (pid/start/nonce/boot) AND the live process (proc/start/nonce) must agree
pkeys() { local p=$E/obs/$1-P.txt a b; a=$(sed -n -e 's/^pid=//p' -e 's/^start=//p' -e 's/^nonce=//p' -e 's/^boot_id=//p' "$p" | tr '\n' ' ')
  b=$(sed -n 's/^proc=\([0-9]*\) start=\([0-9]*\) ppid=[0-9]* nonce=\([0-9a-f]*\) .*/\1 \2 \3/p' "$p")
  if nz "$b"; then [ "$(cut -d' ' -f1-3 <<<"$a")" = "$b" ] && echo "$a"; return 0; fi
  # live environ unreadable: identity = launcher record + live pid/start (nonce source recorded as launch-record)
  b=$(sed -n 's/^proc=\([0-9]*\) start=\([0-9]*\) ppid=[0-9]* nonce=unreadable .*/\1 \2/p' "$p")
  nz "$b" && [ "$(cut -d' ' -f1-2 <<<"$a")" = "$b" ] && echo "$a nonce_source=launch-record"; }
wkeys() { jq -r '.items[] | select(.labels["openshell.ai/boundary-role"]=="workload") | "\(.uid) \([.containerStatuses[] | "\(.name)=\(.containerID)/rc\(.restartCount)"]|join(","))"' "$E/obs/$1-C-pods.json" 2>/dev/null; }
snap() { # snap <label>: local copies of task logs + transcript; S key (path, lines, prefix hash)
  local l=$1
  kx X3L "$L/task/$l.tar" 30 && mkdir -p "$L/task/$l" && tar -xf "$L/task/$l.tar" -C "$L/task/$l" || return 1
  kx X3T "$L/tr/$l.jsonl" 60 || return 1
  { echo "tr=$(cat "$E/tr_rel") lines=$(wc -l <"$L/tr/$l.jsonl") bytes=$(wc -c <"$L/tr/$l.jsonl")"
    python3 -I "$HERE/metrics.py" prefix "$L/tr/$l.jsonl" "$(cat "$E/obs/prefix_n" 2>/dev/null || wc -c <"$L/tr/$l.jsonl")"
    python3 -I "$HERE/metrics.py" ledger "$L/task/$l"; } >"$E/obs/$l-S.txt"
}
same_p() { local a b; a=$(pkeys "$1") b=$(pkeys "$2"); if nz "$a" && [ "$a" = "$b" ]; then echo yes; elif nz "$a" && nz "$b"; then echo no; else echo unknown; fi; }
same_w() { local a b; a=$(wkeys "$1") b=$(wkeys "$2"); if nz "$a" && [ "$a" = "$b" ]; then echo yes; elif nz "$a" && nz "$b"; then echo no; else echo unknown; fi; }
prefix_ok() { # transcript at <later> still starts with the bytes hashed at <earlier>
  local n h; n=$(sed -n 's/.*"prefix_bytes": \([0-9]*\).*/\1/p' "$E/obs/$1-S.txt"); h=$(sed -n 's/.*"prefix_sha256": "\([0-9a-f]*\)".*/\1/p' "$E/obs/$1-S.txt")
  [ "$(python3 -I "$HERE/metrics.py" prefix "$L/tr/$2.jsonl" "$n" | jq -r .prefix_sha256)" = "$h" ] && echo yes || echo no; }

# ---------------------------------------------------------------- terminal client (M2/M3/M4), local tmux only
client_start() { # client_start <name>: M2 in a harness-owned tmux session; raw output piped to $L/term
  local c=$1
  [[ $c =~ ^[a-z0-9]{1,12}$ ]] || return 2
  [ -z "$(client_scan)" ] || stop "a connect client for $SBX already exists before $c"
  guard_ctx || stop "guard failed before connect"
  log "MUTATE openshell sandbox connect $SBX (tmux session $c)"
  echo "$(ems)" >"$E/obs/term-$c-t0"
  # the client execs 1 s after the pane exists, so pipe-pane is attached before its first byte
  "${TM[@]}" new-session -d -s "$c" -x 160 -y 45 /bin/sh -c 'sleep 1; exec "$@"' sh "${OENV[@]}" "$CLI" -g "$GWNAME" sandbox connect "$SBX" || return 1
  "${TM[@]}" set-option -t "$c" remain-on-exit off >/dev/null
  "${TM[@]}" pipe-pane -o -t "$c" "cat >>'$L/term/$c.raw'"
}
client_tree() { # all pids of the client pane's process tree (openshell -> ssh -> sh -> openshell ssh-proxy) and its session
  local root all new p i; root=$("${TM[@]}" display-message -p -t "$1" '#{pane_pid}' 2>/dev/null) || return 0
  nz "$root" || return 0
  all=$root new=$root
  for i in 1 2 3 4 5 6; do
    p=$(for x in $new; do pgrep -P "$x" 2>/dev/null; done | tr '\n' ' '); nz "${p// /}" || break; all="$all $p" new=$p
  done
  all="$all $(pgrep -s "$root" 2>/dev/null | tr '\n' ' ')"
  tr ' ' '\n' <<<"$all" | grep . | sort -u
}
client_scan() { # local connect-client processes: argv[0] basename openshell|ssh (or the ProxyCommand sh), naming
  # the isolated CLI ($HX), this sandbox or its id; harness reads (get/list/exec/...) and kubectl never match
  ps -eo pid=,args= | awk -v hx="$HX" -v sbx="$SBX" -v sid="$(cat "$E/sbx_id" 2>/dev/null)" '
    { n = split($2, p, "/"); b = p[n]; rest = substr($0, index($0, $2))
      if (b != "openshell" && b != "ssh" && b != "sh") next
      if (index(rest, hx) == 0 && index(rest, sbx) == 0 && (sid == "" || index(rest, sid) == 0)) next
      if (b == "sh" && index(rest, "ssh-proxy") == 0) next
      if (rest ~ / (sandbox (get|list|exec|create|delete)|gateway (list|logout)|provider list) /) next
      print }'
}
cap() { "${TM[@]}" capture-pane -p -J -t "$1" >"$L/term/$1-$2.txt" 2>/dev/null; python3 -I "$HERE/metrics.py" screen "$L/term/$1-$2.txt" >"$E/term/$1-$2.json"; }
redraw() { "${TM[@]}" resize-window -t "$1" -x 150 -y 40; sleep 2; "${TM[@]}" resize-window -t "$1" -x 160 -y 45; sleep 3; }
ctrl_l() { log "MUTATE Ctrl-L into $1"; "${TM[@]}" send-keys -t "$1" C-l; sleep 3; }
type_line() { # M3: one fixed-form line + Enter; no control bytes can be sent (Ctrl-D/Ctrl-P are client escapes, K4)
  [[ $2 =~ ^[A-Za-z0-9\ .,:-]{1,200}$ ]] || { log "REFUSED type_line"; return 97; }
  # the text (codeword, probe token) is never logged: only its length and a hash prefix
  log "MUTATE type into $1: ${3:-line} chars=${#2} sha256=$(printf %s "$2" | sha256sum | cut -c1-12)"
  "${TM[@]}" send-keys -t "$1" -l "$2" && sleep 0.5 && "${TM[@]}" send-keys -t "$1" Enter
}
client_kill() { # M4: SIGKILL the whole client tree at once; then prove zero survivors twice
  local c=$1 pids t
  pids=$(client_tree "$c" | tr '\n' ' ')
  nz "$pids" || stop "client $c has no processes to kill"
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

egress_probes() { # egress_probes <label>: M8 (mediated sandbox exec) and kubectl exec (outside OpenShell mediation)
  local l=$1 rc=0
  OT=90 O sandbox exec "$SBX" --no-tty --no-login-shell --timeout 60 -- python3 -I -c "$X5PY" >"$E/obs/$l-X5-sandbox.txt" 2>"$E/obs/$l-X5-sandbox.err"
  echo "rc=$?" >>"$E/obs/$l-X5-sandbox.txt"
  kx X5 "$E/obs/$l-X5-kubectl.txt" 60; echo "rc=$?" >>"$E/obs/$l-X5-kubectl.txt"
  cat "$E/obs/$l-X5-sandbox.txt" "$E/obs/$l-X5-kubectl.txt" >"$E/obs/$l-X5.txt"
  grep -q 'REAL-KEY-SHAPE' "$E/obs/$l-X5.txt" && rc=1
  # gate: the mediated (sandbox exec) probe must be blocked for both; the kubectl-exec probe is an observation only
  grep -q '^disallowed_host=blocked' "$E/obs/$l-X5-sandbox.txt" && grep -q '^anthropic_from_python=blocked' "$E/obs/$l-X5-sandbox.txt" || rc=1
  grep -q '=connected' "$E/obs/$l-X5-kubectl.txt" && log "$l: note: kubectl-exec probe (outside OpenShell mediation) connected: $(grep '=connected' "$E/obs/$l-X5-kubectl.txt" | tr '\n' ' ')"
  return $rc
}

# ---------------------------------------------------------------- task gating and windows
task_count() { sed -n "s/^$1=\([0-9]*\) .*/\1/p" "$2"; }
gate() { # gate <label> <timeout-s> [inflight]: >= 3 done and <= 112 done; with "inflight", also a step running now
  local d=$(( $(ems) + $2 * 1000 )) a p k
  while [ "$(ems)" -lt "$d" ]; do
    kx X2 "$E/obs/$1-gate.txt" 15 || { sleep 2; continue; }
    a=$(task_count attempts "$E/obs/$1-gate.txt") p=$(task_count progress "$E/obs/$1-gate.txt"); k=$(sed -n 's/^lock=//p' "$E/obs/$1-gate.txt")
    if [ "${p:-0}" -ge 3 ] && [ "${p:-0}" -le 112 ] && { [ "${3:-}" != inflight ] || { [ "${a:-0}" -gt "${p:-0}" ] && [ "$k" = held ]; }; }; then
      echo "gate${3:+ $3} attempts=$a done=$p lock=$k at=$(now)" >>"$E/obs/$1-gate-log.txt"; return 0
    fi
    sleep 2
  done
  return 1
}
window_metrics() { # window_metrics <step> <open_ms> <close_ms> <snap-label> <clock-label>
  python3 -I "$HERE/metrics.py" window "$L/task/$4" "$L/tr/$4.jsonl" "$2" "$3" "$(cat "$E/obs/M_s")" "$(skew "$5")" "$(margin "$5")" >"$E/metrics/$1-window.json"
}
unavailable() { # unavailable <step> <reason>: record the process axis as unavailable, keep evidence, then STOP
  ident "$1-unavail" >/dev/null 2>&1; snap "$1-unavail" >/dev/null 2>&1; grab_logs "$1-unavail"
  echo "step=$1 process=unavailable reason=$2 P_after=$(pkeys "$1-unavail") W_after=$(wkeys "$1-unavail")" | tee "$E/obs/$1-result.txt"
  stop "$1: $2 (process=unavailable)"
}
classify_process() { # classify_process <before> <after> <window.json>
  local sp sw fz; sp=$(same_p "$1" "$2") sw=$(same_w "$1" "$2"); fz=$(jq -r .frozen "$3" 2>/dev/null)
  if [ "$sp" = yes ] && [ "$sw" = yes ]; then [ "$fz" = true ] && echo "survived-frozen($(jq -r .max_activity_gap_s "$3")s)" || echo survived
  elif [ "$sp" = no ] || [ "$sw" = no ]; then echo restarted
  else echo inconclusive; fi
}

# ---------------------------------------------------------------- reattach (C3)
reattach() { # reattach <step> <client-name> <previous-client-name>
  local st=$1 c=$2 tok last
  ident "$st-before" || stop "$st: identity not readable before reattach"
  client_start "$c" || stop "$st: connect failed to start"
  local t0; t0=$(cat "$E/obs/term-$c-t0")
  # wait up to 30 s for any replayed/live output
  for _ in $(seq 1 30); do [ -s "$L/term/$c.raw" ] && break; sleep 1; done
  local fo; fo=$(date -r "$L/term/$c.raw" +%s%3N 2>/dev/null); [[ $fo =~ ^[0-9]{13}$ ]] && fo=$((fo - t0)) || fo=none
  echo "first_output_ms_upper_bound=$fo raw_bytes_at_settle=$(stat -c %s "$L/term/$c.raw" 2>/dev/null || echo 0)" >"$E/obs/$st-R.txt"
  sleep 5; cap "$c" replay
  redraw "$c"; cap "$c" redraw
  [ "$(jq -r .coherent "$E/term/$c-redraw.json")" = true ] || { ctrl_l "$c"; cap "$c" ctrl-l; }
  "${TM[@]}" capture-pane -p -J -S - -t "$c" >"$L/term/$c-history.txt" 2>/dev/null
  grep -q -a 'attached read-only' "$L/term/$c.raw" "$L/term/$c-history.txt" && echo "read_only_notice=yes" >>"$E/obs/$st-R.txt" || echo "read_only_notice=no" >>"$E/obs/$st-R.txt"
  grep -q -a 'fell behind' "$L/term/$c.raw" && echo "fell_behind=yes" >>"$E/obs/$st-R.txt" || echo "fell_behind=no" >>"$E/obs/$st-R.txt"
  # A stale owner is released on channel EOF, or at worst by the 60 s SSH peer deadline (v0.1.9 ssh.rs:47-48).
  # If this client is read-only, wait until 75 s after the previous client's end before the single probe;
  # input from a read-only client retries ownership and prints "input enabled" (ssh.rs:1011-1026).
  if grep -q -a 'attached read-only' "$L/term/$c.raw" "$L/term/$c-history.txt"; then
    local kt; kt=$(cat "$E/obs/term-$3-kill-t" 2>/dev/null || cat "$E/obs/term-$3-detach-t" 2>/dev/null || echo 0)
    while [ "$(ems)" -lt $((kt + 75000)) ]; do sleep 2; done
    echo "waited_for_owner_release_until_ms_after_end=75000" >>"$E/obs/$st-R.txt"
  fi
  last=$(task_count progress "$E/obs/$st-before-T.txt")
  tok=PROBE-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'); echo "$tok" >"$L/$st-probe"
  echo "$(ems)" >"$E/obs/$st-probe-t"
  type_line "$c" "Reply $tok and the last step you completed, then continue the task" probe || stop "$st: probe refused"
  # wait for the probe and its reply in the transcript (one probe; no retyping)
  local d=$(( $(ems) + 240000 ))
  while [ "$(ems)" -lt "$d" ]; do
    sleep 10
    kx X3T "$L/tr/$st-probe.jsonl" 60 || continue
    python3 -I "$HERE/metrics.py" probe "$L/tr/$st-probe.jsonl" "$tok" "$L/codeword" "${last:-0}" >"$E/metrics/$st-probe.json" || continue
    [ "$(jq -r .reply "$E/metrics/$st-probe.json")" = true ] && break
  done
  cap "$c" after-probe
  grep -q -a 'input enabled' "$L/term/$c.raw" && echo "input_enabled_notice=yes" >>"$E/obs/$st-R.txt" || echo "input_enabled_notice=no" >>"$E/obs/$st-R.txt"
  ident "$st-after" || stop "$st: identity not readable after reattach"
  snap "$st-after" || log "$st: snapshot failed"
  local sp ro inp rep cls
  sp=$(same_p "$st-before" "$st-after"); ro=$(sed -n 's/^read_only_notice=//p' "$E/obs/$st-R.txt")
  inp=$(jq -r .probe_in_transcript "$E/metrics/$st-probe.json" 2>/dev/null); rep=$(jq -r .reply "$E/metrics/$st-probe.json" 2>/dev/null)
  if [ "$sp" != yes ]; then cls=replacement
  elif grep -q '=yes' <<<"$(grep fell_behind "$E/obs/$st-R.txt")"; then cls=lagged
  elif [ "$inp" = true ]; then cls=same-process-writer
  elif [ "$ro" = yes ]; then cls=same-process-read-only
  else cls=failed; fi
  local ts; if [ "$(jq -r .coherent "$E/term/$c-replay.json")" = true ]; then ts=coherent-on-replay
  elif [ "$(jq -r .coherent "$E/term/$c-redraw.json")" = true ]; then ts=coherent-after-redraw
  elif [ "$(jq -r .coherent "$E/term/$c-ctrl-l.json" 2>/dev/null)" = true ]; then ts=coherent-after-ctrl-l; else ts=garbled; fi
  python3 -I "$HERE/metrics.py" rawmode "$L/term/$c.raw" >"$E/term/$c-rawmode.json"
  { echo "step=$st P_same=$sp W_same=$(same_w "$st-before" "$st-after") prefix_preserved=$(prefix_ok c0-ref "$st-after")"
    echo "reattachment=$cls terminal=$ts probe_in_transcript=$inp reply=$rep"
    echo "conversation_same_session=$(jq -r '(.session_ids // []) | length == 1' "$E/metrics/$st-probe.json" 2>/dev/null) codeword=$(jq -r .reply_codeword "$E/metrics/$st-probe.json" 2>/dev/null) tool_use_before_reply=$(jq -r .tool_use_before_reply "$E/metrics/$st-probe.json" 2>/dev/null)"
    cat "$E/obs/$st-R.txt"; } | tee "$E/obs/$st-result.txt"
  client_detach "$c"
}

# ---------------------------------------------------------------- sampler (read-only, background, own session)
sampler() {
  local s=$E/samples n=0 t
  mkdir -p "$s"
  trap 'kill 0' EXIT
  KWATCH() { while [ ! -e "$E/sampler.stop" ]; do echo "## watch (re)start $(now)" >>"$1.err"; "${KC[@]}" -n "$NS" get "${@:2}" --watch --output-watch-events -o json 2>>"$1.err" | jq -c '{type, k: .object.kind, name: .object.metadata.name, uid: .object.metadata.uid, rv: .object.metadata.resourceVersion, del: .object.metadata.deletionTimestamp, phase: .object.status.phase, cs: [.object.status.initContainerStatuses[]?, .object.status.containerStatuses[]? | {name, containerID, ready, restartCount, state, lastState}], cond: .object.status.conditions, reason: .object.reason, msg: .object.message, ts: (.object.lastTimestamp // .object.eventTime)}' >>"$1"; sleep 1; done; }
  KWATCH "$s/pods-watch.jsonl" pods &
  KWATCH "$s/cr-watch.jsonl" sandboxes.agents.x-k8s.io &
  KWATCH "$s/events-watch.jsonl" events &
  while [ ! -e "$E/sampler.stop" ]; do
    t=$(now)
    { echo "## $t"; K -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.status.phase} del={.metadata.deletionTimestamp} {range .status.containerStatuses[*]}{.name}:{.ready}:{.restartCount}:{.containerID} {end}{"\n"}{end}' 2>&1; } >>"$s/pods-1hz.txt"
    if [ -s "$E/sbx_id" ]; then
      if OT=5 sbx_json "$s/g.json"; then echo "$t $(sbx_phase "$s/g.json") $(jq -c '[.. | .main_process_instance_id? // empty][0]' "$s/g.json" 2>/dev/null)" >>"$s/sandbox-get-1hz.txt"
      else echo "$t ERR $(head -c 160 "$s/g.json.err" | tr '\n' ' ')" >>"$s/sandbox-get-1hz.txt"; fi
      if [ -s "$E/wctr" ]; then
        if [ $((n % 5)) -eq 0 ]; then
          if kx X1 "$s/p.txt" 10; then echo "$t $(grep -E '^(pid|start|nonce)=' "$s/p.txt" | tr '\n' ' ') $(grep '^proc=' "$s/p.txt" | tr '\n' ' ')" >>"$s/P-5s.txt"
          else echo "$t ERR $(head -c 160 "$s/p.txt.err" | tr '\n' ' ')" >>"$s/P-5s.txt"; fi
        fi
        if [ $((n % 10)) -eq 0 ]; then
          if kx X2 "$s/t.txt" 10; then echo "$t $(grep -E '^(attempts|progress|refusals|tr|lock)=' "$s/t.txt" | sed -E 's/ last=.* t=([^ ]+)( .*)?$/ last_t=\1/' | tr '\n' ' ')" >>"$s/T-10s.txt"
          else echo "$t ERR $(head -c 160 "$s/t.txt.err" | tr '\n' ' ')" >>"$s/T-10s.txt"; fi
        fi
      fi
      # X: on any pod of this sandbox reaching a terminated container / Failed / deletion, capture state and logs once per pod UID
      spods "$(cat "$E/sbx_id")" 2>/dev/null >"$s/sp.json"
      for u in $(jq -r '.items[] | select(.status.phase == "Failed" or .status.phase == "Succeeded" or .metadata.deletionTimestamp != null or ([.status.initContainerStatuses[]?, .status.containerStatuses[]? | .state.terminated // empty] | length > 0)) | .metadata.uid' "$s/sp.json" 2>/dev/null); do
        [ -e "$s/x-$u.json" ] && continue
        jq --arg u "$u" '.items[] | select(.metadata.uid == $u) | {name: .metadata.name, uid: .metadata.uid, phase: .status.phase, del: .metadata.deletionTimestamp, st: [.status.initContainerStatuses[]?, .status.containerStatuses[]? | {name, state, lastState, restartCount}]}' "$s/sp.json" >"$s/x-$u.json"
        nm=$(jq -r .name "$s/x-$u.json")
        K -n "$NS" logs "$nm" --all-containers --timestamps >"$L/logs/x-$nm-$u.log" 2>&1
        K -n "$NS" logs "$nm" --all-containers --timestamps --previous >"$L/logs/x-$nm-$u-previous.log" 2>&1
        echo "$t captured termination state of $nm ($u)" >>"$s/x-captured.txt"
      done
    fi
    n=$((n + 1)); sleep 1
  done
}
grab_logs() {
  local l=$1 p
  K -n "$NS" logs "$GW_POD" --timestamps --since=2h >"$L/logs/$l-gateway.log" 2>&1
  K -n "$NS" logs "$GW_POD" --timestamps --previous >"$L/logs/$l-gateway-previous.log" 2>&1
  for p in $(spods "$(cat "$E/sbx_id")" 2>/dev/null | jq -r '.items[] | "pod/" + .metadata.name'); do
    K -n "$NS" logs "$p" --all-containers --timestamps >"$L/logs/$l-${p#pod/}.log" 2>&1
  done
  K -n agent-sandbox-system logs deploy/agent-sandbox-controller --timestamps --since=2h >"$L/logs/$l-controller.log" 2>&1
}
gw_field() { K -n "$NS" get pod "$GW_POD" -o jsonpath="$1" 2>/dev/null; }
gw_ready() { [ "$(gw_field '{.status.containerStatuses[0].ready}')" = true ]; }
gw_new_ready() { local u r; u=$(gw_field '{.metadata.uid}') r=$(gw_field '{.status.containerStatuses[0].ready}'); nz "$u" && [ "$u" != "$1" ] && [ "$r" = true ]; }
sbx_ready() { OT=10 sbx_json "$E/obs/poll.json" && [ "$(sbx_phase "$E/obs/poll.json")" = Ready ]; }
waitfor() { local d=$1; shift; while [ "$(ems)" -lt "$d" ]; do "$@" && return 0; sleep 1; done; return 1; }
token_expiry_ok() { # earliest supervisor-token expiry annotation must be >= JWT_MARGIN s away (unparseable -> record, not stop)
  local e; e=$(jq -r '[.items[].annotations["openshell.ai/supervisor-token-expires-at"] // empty] | min // empty' "$E/obs/$1-C-pods.json" 2>/dev/null)
  echo "token_expires_at=${e:--}" >>"$E/obs/$1-token.txt"
  nz "$e" || return 0
  local es; es=$(date -d "$e" +%s 2>/dev/null || { [[ $e =~ ^[0-9]{13}$ ]] && echo $((e / 1000)); } || echo "")
  nz "$es" || return 0
  [ $((es - $(date +%s))) -ge "$JWT_MARGIN" ]
}

# ================================================================ steps
case $STEP in
pre)
  [ ! -e "$E/STOPPED" ] || fail "stopped earlier"
  if [ ! -s "$E/refs.txt" ]; then
    v1=$(K get namespace kube-system -o jsonpath='{.metadata.uid}'); v2=$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.metadata.uid}')
    v3=$(K -n "$NS" get pvc "$GW_PVC" -o jsonpath='{.metadata.uid}'); v4=$(K -n "$NS" get pod "$GW_POD" -o jsonpath='{.status.containerStatuses[0].imageID}')
    v5=$(K -n agent-sandbox-system get pods -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'); v6=$(argo_state); v7=$(gitops_sha)
    v8=$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.spec.replicas}'); v9=$(providers)
    for v in "$v1" "$v2" "$v3" "$v4" "$v5" "$v6" "$v7" "$v8"; do nz "$v" || fail "pre: a reference value is empty; refusing to record refs"; done
    printf 'kube_system_uid=%s\ngw_sts_uid=%s\ngw_pvc_uid=%s\ngw_image=%s\nctrl_image=%s\ngw_replicas=%s\n' "$v1" "$v2" "$v3" "$v4" "$v5" "$v8" >"$E/refs.txt"
    echo "$v6" >"$E/argo-ref.txt"; echo "$v7" >"$E/gitops-ref.txt"; echo "$v9" >"$E/providers-ref.txt"
  fi
  guard_ctx || stop "pre: identity guard failed"
  # independent pins (site.env, from Stage B run 3's refs): a wrong CTX cannot become the baseline
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
  log "pre OK: Argo Synced/Healthy; digests match Stage B; gateway Ready replicas=1; no Sandbox CRs; provider $PROV present; providers=$(grep -c . "$E/providers-ref.txt") gitops=$(cat "$E/gitops-ref.txt")"
  ;;
sampler-start)
  [ ! -e "$E/sampler.pid" ] || fail "sampler already started"; rm -f "$E/sampler.stop"
  setsid bash "$(readlink -f "$0")" "$RUN" _sampler </dev/null >>"$E/sampler.log" 2>&1 & echo $! >"$E/sampler.pid"
  sleep 8
  [ -s "$E/samples/pods-1hz.txt" ] && [ -s "$E/samples/pods-watch.jsonl" ] || stop "sampler not producing data 8 s after start (Stage B attempt-1 defect check)"
  log "sampler started pid=$(cat "$E/sampler.pid") and producing data"
  ;;
_sampler) sampler ;;
sampler-stop) touch "$E/sampler.stop"; sleep 3; log "sampler stop requested" ;;
ident) nz "$ARG" || fail "ident needs a label"; ident "$ARG"; cat "$E/obs/$ARG-summary.txt" ;;
snap) nz "$ARG" || fail "snap needs a label"; snap "$ARG"; cat "$E/obs/$ARG-S.txt" ;;
spend) spend_check; cat "$E/metrics/spend-latest.json" 2>/dev/null ;;
c0-create)
  guard_full; [ -e "$E/sampler.pid" ] || fail "start the sampler first"; once c0-create
  put1 "$E/obs/c0-create-t0" "$(ems)"
  create_args # defined in launcher.sh: fills CREATE=(...) and LAUNCH=(...)
  OT=420 O sandbox create --name "$SBX" "${CREATE[@]}" -- "${LAUNCH[@]}" >"$E/obs/c0-create.out" 2>"$E/obs/c0-create.err" </dev/null
  rc=$?; log "create rc=$rc"
  if [ "$rc" != 0 ]; then # record the id if the sandbox exists anyway, so cleanup can find its objects
    sbx_json "$E/obs/c0-sandbox.json" && jq -r '[.id, .sandbox.id, .metadata.id, .sandbox.metadata.id] | map(select(. != null)) | .[0] // empty' "$E/obs/c0-sandbox.json" >"$E/sbx_id"
    [ -s "$E/sbx_id" ] && grab_logs c0-create-fail
    stop "C0 create failed rc=$rc: $(tr '\n' ' ' <"$E/obs/c0-create.err" | cut -c1-300)"
  fi
  sbx_json "$E/obs/c0-sandbox.json" || stop "C0 sandbox get failed"
  id=$(jq -r '[.id, .sandbox.id, .metadata.id, .sandbox.metadata.id] | map(select(. != null)) | .[0] // empty' "$E/obs/c0-sandbox.json")
  nz "$id" || stop "C0: no sandbox id in sandbox get"
  echo "$id" >"$E/sbx_id"
  K get sandboxes.agents.x-k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' >"$E/sbx_cr"
  [ "$(grep -c . "$E/sbx_cr")" = 1 ] && [ "$(cut -d/ -f1 "$E/sbx_cr")" = "$NS" ] || stop "expected exactly one Sandbox CR in $NS; got $(tr '\n' ' ' <"$E/sbx_cr")"
  cut -d/ -f2 "$E/sbx_cr" >"$E/sbx_cr_name"
  waitfor $(( $(cat "$E/obs/c0-create-t0") + 300000 )) sbx_ready || stop "C0: sandbox not Ready within 300 s of create"
  put1 "$E/obs/c0-ready-t" "$(ems)"
  spods "$id" | jq "$PODF" >"$E/obs/c0-pods.json"
  jq -r '.items[] | select(.labels["openshell.ai/boundary-role"]=="workload") | .name' "$E/obs/c0-pods.json" >"$E/wpod"
  [ "$(grep -c . "$E/wpod")" = 1 ] || stop "expected exactly one workload pod; got: $(tr '\n' ' ' <"$E/wpod")"
  jq -r '.items[] | select(.labels["openshell.ai/boundary-role"]=="workload") | .containerStatuses[].name' "$E/obs/c0-pods.json" | grep -x agent >"$E/wctr" || stop "workload container 'agent' not found"
  wpod_ok || stop "workload pod labels do not match this sandbox"
  echo "$(( $(cat "$E/obs/c0-ready-t") - $(cat "$E/obs/c0-create-t0") ))" >"$E/obs/c0-ready-ms"
  echo "$(ems)" >"$E/obs/c0-create-done"
  log "C0 created id=$id cr=$(cat "$E/sbx_cr") ready_ms=$(cat "$E/obs/c0-ready-ms")"
  ;;
c0-baseline)
  guard_full; need c0-create; once c0-baseline
  wpod_ok || stop "C0: workload pod identity changed"
  # 1. the agent is running with a placeholder, the launcher record agrees with the live process
  waitfor $(( $(ems) + 60000 )) ident c0-base || stop "C0: identity not readable (see obs/c0-base-P.txt)"
  grep -q '^key_form=placeholder$' "$E/obs/c0-base-P.txt" || stop "C0: launcher saw no OpenShell placeholder ($(grep -o 'key_form=[a-zA-Z-]*' "$E/obs/c0-base-P.txt" | tr '\n' ' '))"
  grep '^proc=' "$E/obs/c0-base-P.txt" | grep -q -E 'keyref_form=placeholder key_form=absent$|nonce=unreadable' || stop "C0: live agent environment: expected keyref=placeholder and ANTHROPIC_API_KEY absent"
  grep -q 'nonce=unreadable' "$E/obs/c0-base-P.txt" && log "C0: live /proc environ unreadable from kubectl exec; nonce source = launcher record"
  nz "$(pkeys c0-base)" || stop "C0: launcher record and live process disagree, or nonce unreadable"
  clock c0 || stop "C0: clock read failed"
  # 2. credential boundary: no real-key-shaped value in any env or file in the workload
  kx X4 "$E/obs/c0-X4.txt" 60 || stop "C0: credential scan failed"
  grep -q '^env_real_key_shape=0$' "$E/obs/c0-X4.txt" && grep -q '^fs_real_key_shape_files=0$' "$E/obs/c0-X4.txt" || stop "C0: real-key-shaped value found in the workload ($(tr '\n' ' ' <"$E/obs/c0-X4.txt"))"
  # 3. egress probes (X5): disallowed host fails; allowed host from a non-bound binary is not credentialed
  egress_probes c0 || stop "C0: egress/credential probe failed (see obs/c0-X5.txt)"
  # 4. model requests work through the proxy: transcript exists and has assistant entries (H4)
  waitfor $(( $(ems) + 180000 )) sh -c '"$0" "$1" "$2" X2probe' "$(readlink -f "$0")" "$RUN" _tr_probe || stop "C0: no transcript with assistant entries within 180 s (H4?)"
  # 5. first attach: replay/redraw captures, deliver the codeword (input path baseline)
  od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^/heron/' >"$L/codeword"
  client_start main || stop "C0: first connect failed"
  for _ in $(seq 1 30); do [ -s "$L/term/main.raw" ] && break; sleep 1; done
  sleep 5; cap main replay; redraw main; cap main redraw
  python3 -I "$HERE/metrics.py" rawmode "$L/term/main.raw" >"$E/term/main-rawmode.json"
  grep -q -a 'attached read-only' "$L/term/main.raw" && stop "C0: first attach is read-only (another client owns input?)"
  tok=ACK-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'); echo "$tok" >"$L/c0-probe"
  type_line main "Remember this codeword for later: $(cat "$L/codeword"). Reply $tok and continue the task" codeword-line || stop "C0: codeword line refused"
  # 6. M: median attempt interval over the first 5 steps; also wait for the codeword ACK
  d=$(( $(ems) + 600000 ))
  while [ "$(ems)" -lt "$d" ]; do
    sleep 15; snap c0-ref || continue
    m=$(python3 -I "$HERE/metrics.py" m "$L/task/c0-ref" | jq -r .M_s)
    python3 -I "$HERE/metrics.py" probe "$L/tr/c0-ref.jsonl" "$tok" - 0 >"$E/metrics/c0-probe.json"
    [ "$m" != null ] && [ "$(jq -r .reply "$E/metrics/c0-probe.json")" = true ] && break
  done
  [ "${m:-null}" != null ] || stop "C0: fewer than 6 first attempts (steps 1-6) within 10 min (agent not following the task?)"
  [ "$(jq -r .reply "$E/metrics/c0-probe.json")" = true ] || stop "C0: codeword line not acknowledged in the transcript within 10 min"
  echo "$m" >"$E/obs/M_s"
  wc -c <"$L/tr/c0-ref.jsonl" >"$E/obs/prefix_n"; snap c0-ref
  python3 -I "$HERE/metrics.py" usage "$L/tr/c0-ref.jsonl" $PRICES >"$E/metrics/c0-usage.json"
  r=$(cat "$L/task/c0-ref/refusals.log" 2>/dev/null | grep -c .)
  [ -s "$L/task/c0-ref/attempts.log" ] || stop "C0: attempts.log missing from the C0 snapshot"
  grep -v -q 'kf=placeholder ak=absent' "$L/task/c0-ref/attempts.log" && stop "C0: a step.sh run (agent descendant) saw unexpected key forms"
  log "C0 baseline: P=$(pkeys c0-base) W=$(wkeys c0-base) M=${m}s refusals=$r usage=$(jq -c . "$E/metrics/c0-usage.json") probe=$(jq -c . "$E/metrics/c0-probe.json")"
  echo "$(ems)" >"$E/obs/c0-baseline-done"
  ;;
_tr_probe) # helper for c0-baseline: rc 0 once a transcript with >= 1 assistant entry exists (records its relative path)
  kx X2 "$E/obs/c0-trprobe.txt" 15 || exit 1
  t=$(sed -n 's/^tr=\([^ ]*\) .*/\1/p' "$E/obs/c0-trprobe.txt"); [ "$(grep -c '^tr=' "$E/obs/c0-trprobe.txt")" = 1 ] || exit 1
  kx X7 "$E/obs/c0-trdir.txt" 15 || exit 1; sed 's#^/sandbox/c/claude/projects/##' "$E/obs/c0-trdir.txt" | tr -d '\n' >"$E/tr_dir"
  printf '%s%s' "$(cat "$E/tr_dir")" "$t" >"$E/tr_rel"
  kx X3T "$L/tr/c0-first.jsonl" 30 && grep -q '"type":"assistant"' "$L/tr/c0-first.jsonl"
  ;;
c1)
  guard_full; need c0-baseline; once c1
  [ "$(client_tree main | grep -c .)" -ge 1 ] || stop "C1: the C0 client is not running"
  gate c1 600 || stop "C1: progress gate not met within 10 min"
  ident c1-before || stop "C1: identity not readable"
  snap c1-before; clock c1 || stop "C1: clock read failed"
  m=$(cat "$E/obs/M_s"); hold=$(awk -v m="$m" 'BEGIN {h = 4 * m; if (h < 120) h = 120; printf "%d", h}')
  gate c1 120 inflight || stop "C1: no step in flight within 120 s"
  client_kill main
  t_open=$(cat "$E/obs/term-main-kill-t")
  put1 "$E/obs/c1-t-open" "$t_open"
  while [ "$(ems)" -lt $((t_open + hold * 1000)) ]; do sleep 5; [ -z "$(client_scan)" ] || stop "C1: a client reappeared during the hold"; done
  t_close=$(ems); put1 "$E/obs/c1-t-close" "$t_close"
  ident c1-after || unavailable c1 "identity not readable after the hold"
  snap c1-after || stop "C1: snapshot failed"
  window_metrics c1 "$t_open" "$t_close" c1-after c1
  proc=$(classify_process c1-before c1-after "$E/metrics/c1-window.json")
  { echo "step=c1 hold_s=$hold process=$proc work=$(jq -r .work "$E/metrics/c1-window.json") P_same=$(same_p c1-before c1-after) W_same=$(same_w c1-before c1-after) prefix_preserved=$(prefix_ok c0-ref c1-after)"
    jq -c . "$E/metrics/c1-window.json"; } | tee "$E/obs/c1-result.txt"
  grab_logs c1; echo "$(ems)" >"$E/obs/c1-done"
  [ "$proc" = restarted ] && log "C1: process restarted (recorded; re-baseline before C2 needs the lead's decision)"
  log "C1 done"
  ;;
c1-reattach) guard_full; need c1; once c1-reattach; reattach c1-reattach r1 main; echo "$(ems)" >"$E/obs/c1-reattach-done"; log "C3a done" ;;
c2)
  guard_full; need c1-reattach; once c2
  [ -z "$(client_scan)" ] || stop "C2: a client is attached (must be detached)"
  gate c2 600 || stop "C2: progress gate not met within 10 min"
  ident c2-before || stop "C2: identity not readable"
  token_expiry_ok c2-before || stop "C2: supervisor token expires within ${JWT_MARGIN}s (credential-expiry confounder)"
  snap c2-before; clock c2 || stop "C2: clock read failed"
  old=$(gw_field '{.metadata.uid}'); nz "$old" || stop "C2: gateway pod UID unreadable"
  echo "old_gw_uid=$old" >"$E/obs/c2-times.txt"
  gate c2 120 inflight || stop "C2: no step in flight within 120 s"
  rollback() { [ "$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.spec.replicas}')" = "$(ref gw_replicas)" ] || { log "ROLLBACK: restoring replicas=$(ref gw_replicas)"; kw scale "statefulset/$GW_STS" --replicas="$(ref gw_replicas)"; }; }
  trap rollback EXIT; trap 'rollback; exit 130' INT TERM HUP
  t0=$(ems); put1 "$E/obs/c2-t0" "$t0"
  kw scale "statefulset/$GW_STS" --replicas=0 || stop "C2 scale 0 refused/failed"
  if waitfor $((t0 + 60000)) sh -c '! "$@"' _ "${KC[@]}" --request-timeout=5s -n "$NS" get pod "$GW_POD"; then
    echo "gw_gone_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/c2-times.txt"
  else stop "C2: gateway pod still present 60 s after scale 0 (rollback runs)"; fi
  while [ "$(ems)" -lt $((t0 + 90000)) ]; do sleep 1; done
  kw scale "statefulset/$GW_STS" --replicas="$(ref gw_replicas)" || stop "C2 scale up failed (rollback retries once on exit)"
  echo "scale_up_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/c2-times.txt"
  waitfor $((t0 + OUTAGE_MAX * 1000)) gw_new_ready "$old" || stop "C2: new gateway pod not Ready within ${OUTAGE_MAX}s of scale-down"
  t_gw=$(ems); put1 "$E/obs/c2-t-gw-ready" "$t_gw"
  echo "gw_ready_ms=$((t_gw - t0)) new_gw_uid=$(gw_field '{.metadata.uid}')" | tee -a "$E/obs/c2-times.txt"
  trap - EXIT INT TERM HUP
  waitfor $(($(ems) + 300000)) sbx_ready || unavailable c2 "sandbox not Ready within 300 s of gateway Ready"
  t_sbx=$(ems); put1 "$E/obs/c2-t-sbx-ready" "$t_sbx"; echo "sbx_ready_ms=$((t_sbx - t0))" | tee -a "$E/obs/c2-times.txt"
  ident c2-after || unavailable c2 "identity not readable after the restart"
  snap c2-after || stop "C2: snapshot failed"
  window_metrics c2-gwdown "$t0" "$t_gw" c2-after c2   # primary Q1 window: gateway absent or not Ready
  window_metrics c2-full "$t0" "$t_sbx" c2-after c2    # until the sandbox reads Ready again
  proc=$(classify_process c2-before c2-after "$E/metrics/c2-full-window.json")
  { echo "step=c2 process=$proc work_gwdown=$(jq -r .work "$E/metrics/c2-gwdown-window.json") work_full=$(jq -r .work "$E/metrics/c2-full-window.json") P_same=$(same_p c2-before c2-after) W_same=$(same_w c2-before c2-after) prefix_preserved=$(prefix_ok c0-ref c2-after)"
    cat "$E/obs/c2-times.txt"; jq -c . "$E/metrics/c2-gwdown-window.json"; } | tee "$E/obs/c2-result.txt"
  grab_logs c2; echo "$(ems)" >"$E/obs/c2-done"
  log "C2 done"
  ;;
c2-reattach) guard_full; need c2; once c2-reattach; reattach c2-reattach r2 r1; echo "$(ems)" >"$E/obs/c2-reattach-done"; log "C3b done" ;;
cleanup)
  # cleanup is the stop path: it runs once even after a STOP (its own marker), and also when create failed
  [ ! -e "$E/done-cleanup" ] || fail "cleanup already ran (single attempt)"; echo "$(now)" >"$E/done-cleanup"
  [ -e "$E/STOPPED" ] && log "cleanup after STOP: $(tail -n 1 "$E/STOPPED")"
  guard_ctx || stop "guard failed before cleanup"
  [ "$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.spec.replicas}')" = "$(ref gw_replicas)" ] || { log "cleanup: gateway replicas differ from pre; restoring first"; kw scale "statefulset/$GW_STS" --replicas="$(ref gw_replicas)"; waitfor $(($(ems) + OUTAGE_MAX * 1000)) gw_ready || log "cleanup: gateway not Ready after restore"; }
  if [ ! -s "$E/sbx_id" ]; then
    if [ -e "$E/done-c0-create" ] && sbx_json "$E/obs/cleanup-sbx.json"; then
      jq -r '[.id, .sandbox.id, .metadata.id, .sandbox.metadata.id] | map(select(. != null)) | .[0] // empty' "$E/obs/cleanup-sbx.json" >"$E/sbx_id"
    fi
    [ -s "$E/sbx_id" ] || { echo none >"$E/sbx_id"; log "cleanup: no sandbox id recorded or resolvable; checking residue by name only"; }
  fi
  "${TM[@]}" kill-server 2>/dev/null; sleep 1
  [ -z "$(client_scan)" ] || { client_scan >"$E/obs/cleanup-clients.txt"; log "cleanup: client processes remain (see obs)"; }
  snap cleanup-final || log "cleanup: final snapshot failed"
  python3 -I "$HERE/metrics.py" usage "$L/tr/cleanup-final.jsonl" $PRICES >"$E/metrics/final-usage.json" 2>/dev/null
  grab_logs cleanup-pre
  K -n "$NS" get pvc -o json | jq -r --arg s "$(cat "$E/sbx_id")" '.items[] | select(.metadata.labels["openshell.ai/sandbox-id"] == $s or .metadata.labels["openshell.ai/boundary-pair"] == $s or (.metadata.name | contains("'"$SBX"'"))) | "\(.metadata.name) \(.spec.volumeName)"' >"$E/obs/cleanup-pvcs.txt"
  if [ -e "$E/done-c0-create" ]; then OT=180 O sandbox delete "$SBX" >"$E/obs/cleanup-delete.out" 2>"$E/obs/cleanup-delete.err"; rc=$?; log "sandbox delete rc=$rc"
  else log "cleanup: c0-create never ran; no delete issued"; fi
  id=$(cat "$E/sbx_id")
  KINDS=pods,pvc,secret,service,networkpolicy,configmap,serviceaccount,role,rolebinding
  objs() { local o o2 o3 c pv pv2; o=$(K -n "$NS" get "$KINDS" -l "openshell.ai/sandbox-id=$id" -o name 2>/dev/null) || return 1; o2=$(K -n "$NS" get "$KINDS" -l "openshell.ai/boundary-pair=$id" -o name 2>/dev/null) || return 1
    local pat=(-e "$SBX"); [ "$id" != none ] && pat+=(-e "$id")
    o3=$(K -n "$NS" get "$KINDS" -o name 2>/dev/null | grep -F "${pat[@]}"); c=$(sandboxes_all 2>/dev/null) || return 1
    pv=""; while read -r _ v; do nz "$v" && K get pv "$v" -o name >/dev/null 2>&1 && pv="$pv pv/$v"; done <"$E/obs/cleanup-pvcs.txt"
    pv2=$(K get pv -o jsonpath='{range .items[*]}{.metadata.name} {.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}{end}' 2>/dev/null | grep -F "${pat[@]}" | grep "^[^ ]* $NS/" || true)
    printf '%s%s%s%s%s%s' "$o" "$o2" "$o3" "$c" "$pv" "$pv2"; }
  gone() { local x; x=$(objs) || return 1; [ -z "$x" ]; }
  waitfor $(($(ems) + 300000)) gone || { objs >"$E/obs/cleanup-residue.txt"; stop "cleanup: experiment objects remain (no manual finalizer/controller action; owner approval required)"; }
  [ "$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.spec.replicas}')" = "$(ref gw_replicas)" ] || stop "cleanup: gateway replicas differ from pre"
  { K -n "$NS" get ciliumnetworkpolicies -o name 2>/dev/null | grep -F -e "$SBX" $([ "$id" != none ] && printf -- '-e %s' "$id") || true; } >"$E/obs/cleanup-cilium-residue.txt"
  [ -s "$E/obs/cleanup-cilium-residue.txt" ] && stop "cleanup: Cilium policy residue (see obs/cleanup-cilium-residue.txt)"
  log "experiment objects gone ($KINDS by labels and names, Sandbox CRs, PVs by recorded PVC and by claim, Cilium policies); gateway replicas=$(ref gw_replicas)"
  ;;
post)
  inventory "$E/inv/post"
  (cd "$E/inv" && for f in pre/*; do b=${f#pre/}; diff -u "pre/$b" "post/$b" >"diff-$b.txt" 2>&1 && rm -f "diff-$b.txt"; done; ls diff-* 2>/dev/null) | tee "$E/inv/diff-files.txt"
  # Pre-declared expected differences: gw-sts-generation (+2 from C2's two scale operations), gateway pod UID
  # (openshell-pod-images and pod names are name/image only), sandbox-list (the experiment sandbox is gone).
  # providers.txt MUST differ only if the owner has already deleted $PROV.
  grep -v -x -E 'diff-(gw-sts-generation|providers)\.txt' "$E/inv/diff-files.txt" >"$E/inv/unexpected-diffs.txt" || true
  if [ -s "$E/inv/unexpected-diffs.txt" ]; then echo "restoration=NOT-CLEAN unexpected=$(tr '\n' ' ' <"$E/inv/unexpected-diffs.txt")" | tee "$E/inv/restoration.txt"
  else echo "restoration=matches-pre (declared differences only)" | tee "$E/inv/restoration.txt"; fi
  [ -e "$E/done-cleanup" ] || echo "note: cleanup step has not run" | tee -a "$E/inv/restoration.txt"
  log "post: $(head -n 1 "$E/inv/restoration.txt")"
  ;;
logout) O gateway logout "$GWNAME" >"$E/obs/logout.out" 2>&1; log "gateway logout rc=$?" ;;
*) echo "unknown step $STEP" >&2; exit 2 ;;
esac
