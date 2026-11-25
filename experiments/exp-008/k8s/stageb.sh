#!/usr/bin/env bash
# EXP-008 stage B harness: OpenShell 0.1.9 Kubernetes driver, gateway-restart continuity,
# on the EXISTING installation (STAGE-B-PROPOSAL.md revision 4; owner approval 2026-11-24).
#
#   stageb.sh <RUN> <step> [arg]
#   steps: pre | sampler-start | b1 | b1-soak | b2 | b3 | b5 | cleanup | post | sampler-stop | logout | ident <label>
#
# The lead agent runs each step by hand, in order, and decides between steps.
# Nothing retries: b1/b2/b3/b5/cleanup each run at most once (done-<step> marker written
# before the first mutation), and no step runs after a STOP.
#
# Site-specific names (kube context, Argo app names, GitOps repo) come from $HX/site.env,
# which is NOT committed (public-repo rule).
#
# MUTATION ALLOWLIST (the complete list; nothing else may change cluster state):
#   M1 openshell sandbox create --name <SBX> (fixed image digest and args)    b1
#   M2 openshell sandbox connect <SBX> + one typed "mark <word>" (ACK)        b1-soak b2 b3
#   M3 kubectl -n openshell scale statefulset/openshell --replicas=0|1        b2 (and its rollback to 1)
#   M4 kubectl -n openshell delete pod openshell-0 --grace-period=1           b3
#   M5 kubectl -n openshell delete pod <THIS sandbox's workload pod>          b5
#   M6 openshell sandbox delete <SBX>                                         cleanup
#   M7 openshell gateway logout exp008b (isolated local CLI config only)      logout
# kubectl exec: only into this sandbox's workload pod, only READ_SCRIPT or `cat counter.log`.
set -uo pipefail
[ "$#" -ge 2 ] || { echo "usage: stageb.sh <RUN> <step> [arg]" >&2; exit 2; }
RUN=$1 STEP=$2 ARG=${3:-}
[[ $RUN =~ ^[0-9]{4}-[0-9]{4}$ ]] || { echo "bad RUN (MMDD-HHMM)" >&2; exit 2; }
[[ $ARG =~ ^[A-Za-z0-9_-]{0,32}$ ]] || { echo "bad arg" >&2; exit 2; }

HX=$HOME/.cache/hxb
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
# shellcheck source=/dev/null
. "$HX/site.env" || { echo "missing $HX/site.env" >&2; exit 2; } # CTX, ARGO_APP_GW, ARGO_APP_AS, GITOPS_REPO
[ -n "${CTX:-}" ] && [ -n "${ARGO_APP_GW:-}" ] && [ -n "${ARGO_APP_AS:-}" ] && [ -n "${GITOPS_REPO:-}" ] || { echo "site.env incomplete" >&2; exit 2; }
NS=openshell
GW_STS=openshell
GW_POD=openshell-0
GW_PVC=openshell-data-openshell-0
GWNAME=exp008b # isolated CLI registration name
SBX=exp008b-${RUN} # the ONLY sandbox this harness may create/delete
IMG=ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16
GW_DIGEST=sha256:1fd9e1e807990e66c9486a28d3ce9d649fd7528df48d0e830d2de2148b52dfe5
CTRL_DIGEST=sha256:b0ee91a42129919179baf5f429979fee3ab1a3dac6855110b4648a6ff4b44103
CLI_SHA=2db8e54f63feebe9f994efaf6004bbd45c55bc70ea455eda42fe82a0ea7c7e69
CLI=$HX/bin/openshell
R=$HX/run/$RUN
E=$R/e
TL=$E/timeline.log
OUTAGE_MAX=240
FREEZE_END_LOCAL=30 # 00:30 America/New_York; Renovate's automerge window opens at 01:00
export TZ=America/New_York
KUBECTL_DIR=$HOME/.local/share/mise/installs/kubectl/1.36.5 # kubectl v1.36.5 (as in B0)
GH=$(ls -d "$HOME"/.local/share/mise/installs/gh/*/gh_*/bin/gh 2>/dev/null | sort -V | tail -n 1)
PATH=$KUBECTL_DIR:/usr/bin:/bin
export PATH
[ -x "$KUBECTL_DIR/kubectl" ] && [ -x "$GH" ] && [ -x /usr/bin/jq ] && [ -x /usr/bin/python3 ] || { echo "missing kubectl/gh/jq/python3" >&2; exit 2; }
KC=("$KUBECTL_DIR/kubectl" --context "$CTX")

mkdir -p -m 700 "$R" "$E" "$E/obs" "$E/logs" "$E/inv" "$E/ack"
[ "$(stat -c %a "$R")" = 700 ] || { echo "$R must be 0700" >&2; exit 2; }
[ "$(sha256sum "$CLI" | cut -d' ' -f1)" = "$CLI_SHA" ] || { echo "CLI sha256 mismatch" >&2; exit 2; }

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
# kubectl, mutating: exact allowlist only; every call logged before it runs
kw() {
  local f="$*" wpod sid role
  case $f in
  "scale statefulset/$GW_STS --replicas=0" | "delete pod $GW_POD --grace-period=1 --wait=false") ;; # M3 down, M4
  "scale statefulset/$GW_STS --replicas=1") ;;                                                     # M3 up (also rollback)
  "delete pod "*" --wait=false")                                                                   # M5
    wpod=${f#delete pod }; wpod=${wpod% --wait=false}; sid=$(cat "$E/sbx_id" 2>/dev/null)
    nz "$wpod" && nz "$sid" && [ "$wpod" = "$(cat "$E/wpod" 2>/dev/null)" ] && [ "$wpod" != "$GW_POD" ] || { log "REFUSED kw $f"; return 97; }
    role=$(K -n "$NS" get pod "$wpod" -o jsonpath='{.metadata.labels.openshell\.ai/boundary-pair} {.metadata.labels.openshell\.ai/boundary-role}') || { log "REFUSED kw (lookup) $f"; return 97; }
    [ "$role" = "$sid workload" ] || { log "REFUSED kw (labels '$role') $f"; return 97; }
    ;;
  *) log "REFUSED kw $f"; return 97 ;;
  esac
  if [ "$f" != "scale statefulset/$GW_STS --replicas=1" ]; then # scale-up/rollback must never be blocked by a guard
    guard_ctx || stop "kube identity guard failed before mutation: $f"
  fi
  log "MUTATE kubectl -n $NS $f"
  "${KC[@]}" --request-timeout=20s -n "$NS" "$@"
}
# exec: only this sandbox's workload pod. The case pattern is split with '' so this script's own
# `sh -c` command line (which contains the pattern text) cannot match it; $$ is excluded too.
READ_SCRIPT='cat /sandbox/out/identity 2>/dev/null; echo boot_id=$(cat /proc/sys/kernel/random/boot_id); for p in /proc/[0-9]*; do [ "${p#/proc/}" = "$$" ] && continue; c=$(tr "\0" " " <$p/cmdline 2>/dev/null); case "$c" in */usr/local/bin/count''er.sh*) echo "proc=${p#/proc/} start=$(sed "s/.*) //" $p/stat | awk "{print \$20}") nspid=$(grep NSpid $p/status | cut -f2- | tr "\t" ,) cmd=$c";; esac; done; echo last=$(tail -n 1 /sandbox/out/counter.log 2>/dev/null)'
kx() { # kx <outfile> [full]
  local wpod c
  wpod=$(cat "$E/wpod" 2>/dev/null) c=$(cat "$E/wctr" 2>/dev/null)
  nz "$wpod" && nz "$c" || return 1
  if [ "${2:-}" = full ]; then
    "${KC[@]}" --request-timeout=30s -n "$NS" exec "$wpod" -c "$c" -- cat /sandbox/out/counter.log >"$1" 2>"$1.err"
  else
    "${KC[@]}" --request-timeout=15s -n "$NS" exec "$wpod" -c "$c" -- sh -c "$READ_SCRIPT" >"$1" 2>"$1.err"
  fi
}

# ---------------------------------------------------------------- CLI (isolated HOME; explicit -g)
OENV=(env -i HOME="$HX/home" XDG_CONFIG_HOME="$HX/home/.config" XDG_DATA_HOME="$HX/home/.local/share"
  XDG_STATE_HOME="$HX/home/.local/state" XDG_CACHE_HOME="$HX/home/.cache" PATH=/usr/bin:/bin TERM=xterm-256color)
O() {
  local sub="$1 ${2:-}"
  case $sub in
  "sandbox get" | "sandbox list" | "gateway list") ;;
  "sandbox create") [ "${3:-}" = --name ] && [ "${4:-}" = "$SBX" ] || { log "REFUSED O $*"; return 97; } ;;
  "sandbox delete") [ "${3:-}" = "$SBX" ] && [ "$#" -eq 3 ] || { log "REFUSED O $*"; return 97; } ;;
  "gateway logout") [ "${3:-}" = "$GWNAME" ] && [ "$#" -eq 3 ] || { log "REFUSED O $*"; return 97; } ;;
  *) log "REFUSED O $*"; return 97 ;;
  esac
  case $sub in "sandbox create" | "sandbox delete" | "gateway logout") log "MUTATE openshell $*" ;; esac
  "${OENV[@]}" timeout -k 5 "${OT:-60}" "$CLI" -g "$GWNAME" "$@"
}
gw_registered() { O gateway list 2>/dev/null | grep -q -w "$GWNAME"; } # never let the CLI pick/bootstrap another gateway
sbx_json() { OT=${OT:-20} O sandbox get "$SBX" -o json >"$1" 2>"$1.err"; }
sbx_phase() { jq -r '[.phase, .status.phase, .sandbox.phase, .sandbox.status.phase] | map(select(. != null)) | .[0] // empty' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- guards
ref() { sed -n "s/^$1=//p" "$E/refs.txt" 2>/dev/null; }
guard_ctx() { # same cluster, same gateway objects as recorded at pre; empty never matches
  local v
  v=$(K get namespace kube-system -o jsonpath='{.metadata.uid}') && nz "$v" && [ "$v" = "$(ref kube_system_uid)" ] || return 1
  v=$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.metadata.uid}') && nz "$v" && [ "$v" = "$(ref gw_sts_uid)" ] || return 1
  v=$(K -n "$NS" get pvc "$GW_PVC" -o jsonpath='{.metadata.uid}') && nz "$v" && [ "$v" = "$(ref gw_pvc_uid)" ] || return 1
}
argo_state() { local a; for a in "$ARGO_APP_GW" "$ARGO_APP_AS"; do K -n argo-system get applications.argoproj.io "$a" -o jsonpath='{.metadata.name} {.status.sync.status} {.status.health.status} {.status.sync.revision} {.status.operationState.phase} {.status.operationState.startedAt}{"\n"}' || return 1; done; }
gitops_sha() { env -u SSH_AUTH_SOCK "$GH" api "repos/$GITOPS_REPO/commits/main" --jq .sha 2>/dev/null; }
sandboxes_all() { K get sandboxes.agents.x-k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'; }
guard_full() { # stop conditions checked at every step boundary
  guard_ctx || stop "cluster/gateway identity guard mismatch"
  local t a s o
  t=$((10#$(date +%H%M)))
  [ "$t" -ge "$FREEZE_END_LOCAL" ] && [ "$t" -lt 700 ] && stop "freeze window: too close to/inside the Renovate automerge window (local $t)"
  a=$(argo_state) && nz "$a" || stop "Argo state unreadable"
  [ "$a" = "$(cat "$E/argo-ref.txt")" ] || { echo "$a" >"$E/obs/argo-changed-$(ems).txt"; stop "Argo state changed during the run"; }
  s=$(gitops_sha) && nz "$s" || stop "GitOps main unreadable"
  [ "$s" = "$(cat "$E/gitops-ref.txt")" ] || stop "GitOps main moved during the run (freeze broken)"
  s=$(sandboxes_all) || stop "Sandbox CR list unreadable"
  o=$(grep -v -x -F "$(cat "$E/sbx_cr" 2>/dev/null || echo __none__)" <<<"$s" | grep . || true)
  nz "$o" && stop "competing Sandbox CR(s): $o"
  gw_registered || stop "CLI gateway registration $GWNAME missing"
  return 0
}

# ---------------------------------------------------------------- inventory (B0 form; names/UIDs only for Secrets)
inventory() { # inventory <dir>
  local d=$1; mkdir -p "$d"
  K version -o yaml >"$d/version.yaml" 2>&1
  K get crd sandboxes.agents.x-k8s.io -o jsonpath='{.metadata.uid}{"\n"}{range .spec.versions[*]}{.name} served={.served} storage={.storage}{"\n"}{end}{.spec.conversion.strategy} {.status.storedVersions}{"\n"}' >"$d/crd.txt" 2>&1
  K get crd -o name 2>&1 | grep -i 'agents.x-k8s.io' >"$d/crds.txt"
  K get sandboxes.agents.x-k8s.io -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid' >"$d/sandboxes.txt" 2>&1
  K -n "$NS" get statefulset,deployment,service,pvc,networkpolicy,serviceaccount,role,rolebinding,configmap,resourcequota,limitrange,secret \
    -o 'custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid' >"$d/openshell-objects.txt" 2>&1
  K -n "$NS" get pods -o 'custom-columns=NAME:.metadata.name' >"$d/openshell-pod-names.txt" 2>&1
  K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.metadata.uid} replicas={.spec.replicas} gen={.metadata.generation}{"\n"}' >"$d/gw-sts.txt" 2>&1
  K -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{" "}{end}{"\n"}{end}' >"$d/openshell-pod-images.txt" 2>&1
  K -n "$NS" get pvc -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,SC:.spec.storageClassName,VOL:.spec.volumeName,STATUS:.status.phase' >"$d/pvc.txt" 2>&1
  K -n "$NS" get configmap openshell-config -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}' >"$d/gw-config.txt" 2>&1
  K -n agent-sandbox-system get deployment,pod,service,lease,role,rolebinding,secret -o 'custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid' >"$d/as-objects.txt" 2>&1
  K -n agent-sandbox-system get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{" rc="}{.restartCount}{end}{"\n"}{end}' >"$d/as-pods.txt" 2>&1
  K get clusterrole agent-sandbox-controller -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}{.rules}{"\n"}' >"$d/as-clusterrole.txt" 2>&1
  K get clusterrolebinding agent-sandbox-controller -o jsonpath='{.metadata.uid} rv={.metadata.resourceVersion}{"\n"}' >"$d/as-clusterrolebinding.txt" 2>&1
  K get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>&1 | grep -i -E 'sandbox|openshell' >"$d/webhooks.txt"
  K get namespace "$NS" agent-sandbox-system -o 'custom-columns=NAME:.metadata.name,UID:.metadata.uid,LABELS:.metadata.labels' >"$d/namespaces.txt" 2>&1
  { K -n "$NS" get ciliumnetworkpolicies; K get ciliumclusterwidenetworkpolicies; } >"$d/cilium.txt" 2>&1
  argo_state 2>&1 | awk '{print $1, $2, $3, $4}' >"$d/argo.txt"
}

# ---------------------------------------------------------------- identity
ident() { # ident <label>: P (exec), C (pods/CR), G (sandbox get) -> obs/<label>-*; rc 0 only if P read with >=1 counter proc
  local l=$1 rc=0 sid
  sid=$(cat "$E/sbx_id")
  kx "$E/obs/$l-P.txt" || rc=1
  spods "$sid" 2>"$E/obs/$l-C-pods.err" | jq "$PODF" >"$E/obs/$l-C-pods.json"
  K -n "$NS" get sandboxes.agents.x-k8s.io "$(cat "$E/sbx_cr_name")" -o json 2>"$E/obs/$l-C-cr.err" | jq "$CRF" >"$E/obs/$l-C-cr.json"
  K -n "$NS" get pod "$GW_POD" -o jsonpath='{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].imageID} ready={.status.containerStatuses[0].ready}{"\n"}' >"$E/obs/$l-G-gwpod.txt" 2>&1
  sbx_json "$E/obs/$l-G-sandbox.json"
  psum "$l" >"$E/obs/$l-summary.txt"
  [ "$(grep -c '^proc=' "$E/obs/$l-P.txt" 2>/dev/null)" -ge 1 ] || rc=1
  return $rc
}
# filters: keep identity-relevant fields only (no env, no volumes' secret refs)
# pods of one sandbox: supervisor carries sandbox-id, workload carries boundary-pair (v0.1.9 as observed)
spods() { K -n "$NS" get pods -o json | jq --arg s "$1" --arg r "${2:-}" '{items: [.items[] | select((.metadata.labels["openshell.ai/sandbox-id"] == $s or .metadata.labels["openshell.ai/boundary-pair"] == $s) and ($r == "" or .metadata.labels["openshell.ai/boundary-role"] == $r))]}'; }
PODF='{items: [.items[] | {name: .metadata.name, uid: .metadata.uid, labels: .metadata.labels, annotations: (.metadata.annotations // {} | with_entries(select(.key | test("expires|generation|uid|readiness|topology|session|bootstrap")))), ownerReferences: [.metadata.ownerReferences[]? | {kind, name, uid}], deletionTimestamp: .metadata.deletionTimestamp, creationTimestamp: .metadata.creationTimestamp, node: .spec.nodeName, schedulingGates: .spec.schedulingGates, restartPolicy: .spec.restartPolicy, phase: .status.phase, conditions: .status.conditions, containerStatuses: [.status.containerStatuses[]? | {name, containerID, imageID, restartCount, ready, started, state, lastState}]}]}'
CRF='{name: .metadata.name, uid: .metadata.uid, generation: .metadata.generation, labels: .metadata.labels, annotations: (.metadata.annotations // {} | with_entries(select(.key | test("pod-name|generation")))), deletionTimestamp: .metadata.deletionTimestamp, operatingMode: .spec.operatingMode, failedPodPolicy: .spec.failedPodPolicy, conditions: .status.conditions}'
psum() {
  local l=$1 p=$E/obs/$1-P.txt
  echo "pid=$(sed -n 's/^pid=//p' "$p")"; echo "start=$(sed -n 's/^start=//p' "$p")"; echo "nonce=$(sed -n 's/^nonce=//p' "$p")"
  echo "boot_id=$(sed -n 's/^boot_id=//p' "$p")"; echo "procs=$(grep -c '^proc=' "$p" 2>/dev/null)"; grep '^proc=' "$p" | sed 's/ cmd=.*//' | head -3
  jq -r '.items[] | "pod \(.labels["openshell.ai/boundary-role"] // "?") name=\(.name) uid=\(.uid) phase=\(.phase) node=\(.node) del=\(.deletionTimestamp // "-") gates=\([.schedulingGates[]?.name]|join(",")) \([.containerStatuses[] | "\(.name):cid=\(.containerID // "-"|.[-12:]) started=\(.state.running.startedAt // "-") rc=\(.restartCount) ready=\(.ready)"]|join(" "))"' "$E/obs/$l-C-pods.json" 2>/dev/null
  jq -r '"cr name=\(.name) uid=\(.uid) gen=\(.generation) mode=\(.operatingMode // "-") \([.conditions[]? | "\(.type)=\(.status)/\(.reason)/og=\(.observedGeneration // "-")"]|join(" "))"' "$E/obs/$l-C-cr.json" 2>/dev/null
  echo "gwpod=$(cat "$E/obs/$l-G-gwpod.txt" 2>/dev/null)"
  echo "G phase=$(sbx_phase "$E/obs/$l-G-sandbox.json") instance=$(jq -r '[.. | .main_process_instance_id? // empty][0] // "-"' "$E/obs/$l-G-sandbox.json" 2>/dev/null) started_ms=$(jq -r '[.. | .main_process_started_at_ms? // empty][0] // "-"' "$E/obs/$l-G-sandbox.json" 2>/dev/null)"
}
pkeys() { local p=$E/obs/$1-P.txt; nz "$(sed -n 's/^nonce=//p' "$p")" || return 0; sed -n -e 's/^pid=//p' -e 's/^start=//p' -e 's/^nonce=//p' -e 's/^boot_id=//p' "$p" | tr '\n' ' '; }
wkeys() { jq -r '.items[] | select(.labels["openshell.ai/boundary-role"]=="workload") | "\(.uid) \([.containerStatuses[].containerID]|join(","))"' "$E/obs/$1-C-pods.json" 2>/dev/null; }

# ---------------------------------------------------------------- ACK (M2)
ack() { # ack <word>: fresh `sandbox connect` under a pty, type "mark <word>" once, wait for the complete ACK line
  local w=$1 rc
  [[ $w =~ ^[a-z0-9]{1,12}$ ]] || return 2
  guard_ctx || stop "guard failed before ACK"
  log "MUTATE openshell sandbox connect $SBX (ACK $w)"
  python3 -I "$HERE/ackpty.py" "$w" 90 "$E/ack/$w.raw" -- "${OENV[@]}" "$CLI" -g "$GWNAME" sandbox connect "$SBX" >"$E/ack/$w.result" 2>"$E/ack/$w.err"
  rc=$?
  log "ACK $w rc=$rc $(cat "$E/ack/$w.result" 2>/dev/null)"
  return $rc
}
ack_matches() { # ack_matches <word> <ident-label>: ACK pid/start/nonce equal the identity file
  local a; a=$(sed -n 's/.*ack=\(ACK [^ ]* pid=[0-9]* start=[0-9]* nonce=[0-9a-f]*\).*/\1/p' "$E/ack/$1.result")
  [ "$a" = "ACK $1 pid=$(sed -n 's/^pid=//p' "$E/obs/$2-P.txt") start=$(sed -n 's/^start=//p' "$E/obs/$2-P.txt") nonce=$(sed -n 's/^nonce=//p' "$E/obs/$2-P.txt")" ]
}

# ---------------------------------------------------------------- sampler (read-only, background, own session)
sampler() {
  local s=$E/samples n=0 t
  mkdir -p "$s"
  trap 'kill 0' EXIT
  KWATCH() { while [ ! -e "$E/sampler.stop" ]; do echo "## watch (re)start $(now)" >>"$1.err"; "${KC[@]}" -n "$NS" get "${@:2}" --watch --output-watch-events -o json 2>>"$1.err" | jq -c '{type, k: .object.kind, name: .object.metadata.name, uid: .object.metadata.uid, rv: .object.metadata.resourceVersion, del: .object.metadata.deletionTimestamp, phase: .object.status.phase, gates: .object.spec.schedulingGates, cs: [.object.status.containerStatuses[]? | {name, containerID, ready, restartCount}], cond: .object.status.conditions, reason: .object.reason, msg: .object.message, ts: (.object.lastTimestamp // .object.eventTime)}' >>"$1"; sleep 1; done; }
  KWATCH "$s/pods-watch.jsonl" pods &
  KWATCH "$s/cr-watch.jsonl" sandboxes.agents.x-k8s.io &
  KWATCH "$s/events-watch.jsonl" events &
  while [ ! -e "$E/sampler.stop" ]; do
    t=$(now)
    { echo "## $t"; K -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.status.phase} del={.metadata.deletionTimestamp} {range .status.containerStatuses[*]}{.name}:{.ready}:{.restartCount}:{.containerID} {end}{"\n"}{end}' 2>&1; } >>"$s/pods-1hz.txt"
    if [ -s "$E/sbx_id" ]; then
      if OT=5 sbx_json "$s/g.json"; then echo "$t $(sbx_phase "$s/g.json") $(jq -c '[.. | .main_process_instance_id? // empty][0]' "$s/g.json" 2>/dev/null)" >>"$s/sandbox-get-1hz.txt"
      else echo "$t ERR $(head -c 160 "$s/g.json.err" | tr '\n' ' ')" >>"$s/sandbox-get-1hz.txt"; fi
      if [ $((n % 5)) -eq 0 ] && [ -s "$E/wctr" ]; then
        if kx "$s/p.txt"; then echo "$t $(grep -v '^proc=' "$s/p.txt" | tr '\n' ' ') $(grep '^proc=' "$s/p.txt" | sed 's/ cmd=.*//' | tr '\n' ' ')" >>"$s/P-5s.txt"
        else echo "$t ERR $(head -c 160 "$s/p.txt.err" | tr '\n' ' ')" >>"$s/P-5s.txt"; fi
      fi
    fi
    if [ ! -e "$s/fail-captured" ] && K -n "$NS" get pod "default--$SBX" -o json >"$s/fp.json" 2>/dev/null \
       && jq -e '([.status.containerStatuses[]? | .state.terminated // empty] + [.status.initContainerStatuses[]? | .state.terminated // empty | select(.exitCode != 0)]) | length > 0' "$s/fp.json" >/dev/null 2>&1; then
      jq -c '{phase: .status.phase, st: [.status.initContainerStatuses[]?, .status.containerStatuses[]? | {name, state, lastState, restartCount}]}' "$s/fp.json" >"$s/fail-state-$t.json"
      K -n "$NS" logs "default--$SBX" --all-containers --timestamps >"$s/fail-logs-$t.log" 2>&1
      touch "$s/fail-captured"
    fi
    rm -f "$s/fp.json"
    n=$((n + 1)); sleep 1
  done
}

# ---------------------------------------------------------------- logs (read-only; kept local, redacted before commit)
grab_logs() {
  local l=$1 p
  K -n "$NS" logs "$GW_POD" --timestamps --since=2h >"$E/logs/$l-gateway.log" 2>&1
  K -n "$NS" logs "$GW_POD" --timestamps --previous >"$E/logs/$l-gateway-previous.log" 2>&1
  for p in $(spods "$(cat "$E/sbx_id")" 2>/dev/null | jq -r '.items[] | "pod/" + .metadata.name'); do
    K -n "$NS" logs "$p" --all-containers --timestamps >"$E/logs/$l-${p#pod/}.log" 2>&1
  done
  K -n agent-sandbox-system logs deploy/agent-sandbox-controller --timestamps --since=2h >"$E/logs/$l-controller.log" 2>&1
}

# ---------------------------------------------------------------- waits
gw_field() { K -n "$NS" get pod "$GW_POD" -o jsonpath="$1" 2>/dev/null; }
gw_present() { nz "$(gw_field '{.metadata.uid}')"; }
gw_new_ready() { local u r; u=$(gw_field '{.metadata.uid}') r=$(gw_field '{.status.containerStatuses[0].ready}'); nz "$u" && [ "$u" != "$1" ] && [ "$r" = true ]; }
sbx_ready() { OT=10 sbx_json "$E/obs/poll.json" && [ "$(sbx_phase "$E/obs/poll.json")" = "${READY_PHASE:-Ready}" ]; }
waitfor() { local d=$1; shift; while [ "$(ems)" -lt "$d" ]; do "$@" && return 0; sleep 1; done; return 1; }

classify() { # classify <step> <before-label> <after-label>
  local st=$1 a=$2 b=$3 pa pb wa wb
  pa=$(pkeys "$a") pb=$(pkeys "$b") wa=$(wkeys "$a") wb=$(wkeys "$b")
  kx "$E/obs/$st-counter.log" full
  python3 -I "$HERE/gaps.py" "$E/obs/$st-counter.log" "$(cat "$E/obs/$st-t0" 2>/dev/null || echo 0)" >"$E/obs/$st-gaps.txt" 2>&1
  {
    echo "step=$st before=$a after=$b"
    echo "P_before=$pa"; echo "P_after=$pb"; echo "W_before=$wa"; echo "W_after=$wb"
    if nz "$pa" && [ "$pa" = "$pb" ]; then echo "P_same=yes"; elif nz "$pa" && nz "$pb"; then echo "P_same=no"; else echo "P_same=unknown"; fi
    if nz "$wa" && [ "$wa" = "$wb" ]; then echo "W_same=yes"; elif nz "$wa" && nz "$wb"; then echo "W_same=no"; else echo "W_same=unknown"; fi
    cat "$E/obs/$st-gaps.txt"
  } | tee "$E/obs/$st-compare.txt"
}

# ================================================================ steps
case $STEP in
pre)
  [ ! -e "$E/STOPPED" ] || fail "stopped earlier"
  if [ ! -s "$E/refs.txt" ]; then
    v1=$(K get namespace kube-system -o jsonpath='{.metadata.uid}'); v2=$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.metadata.uid}')
    v3=$(K -n "$NS" get pvc "$GW_PVC" -o jsonpath='{.metadata.uid}'); v4=$(K -n "$NS" get pod "$GW_POD" -o jsonpath='{.status.containerStatuses[0].imageID}')
    v5=$(K -n agent-sandbox-system get pods -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'); v6=$(argo_state); v7=$(gitops_sha)
    for v in "$v1" "$v2" "$v3" "$v4" "$v5" "$v6" "$v7"; do nz "$v" || fail "pre: a reference value is empty; refusing to record refs"; done
    printf 'kube_system_uid=%s\ngw_sts_uid=%s\ngw_pvc_uid=%s\ngw_image=%s\nctrl_image=%s\n' "$v1" "$v2" "$v3" "$v4" "$v5" >"$E/refs.txt"
    echo "$v6" >"$E/argo-ref.txt"; echo "$v7" >"$E/gitops-ref.txt"
  fi
  guard_ctx || stop "pre: identity guard failed"
  inventory "$E/inv/b0-pre"
  [ "$(ref gw_image)" = "ghcr.io/nvidia/openshell/gateway@$GW_DIGEST" ] || stop "gateway digest differs from B0: $(ref gw_image)"
  [ "$(ref ctrl_image)" = "registry.k8s.io/agent-sandbox/agent-sandbox-controller@$CTRL_DIGEST" ] || stop "controller digest differs from B0: $(ref ctrl_image)"
  [ "$(gw_field '{.status.containerStatuses[0].ready}')" = true ] || stop "gateway not Ready"
  s=$(sandboxes_all) || stop "Sandbox list unreadable"; nz "$s" && stop "competing Sandbox CRs: $s"
  gw_registered || stop "CLI registration $GWNAME missing (owner login first)"
  OT=30 O sandbox list >"$E/inv/sandbox-list-pre.txt" 2>&1 || stop "sandbox list failed (not logged in?)"
  log "pre OK: refs recorded; digests match B0; gateway Ready; no Sandbox CRs; argo=$(tr '\n' ';' <"$E/argo-ref.txt") gitops=$(cat "$E/gitops-ref.txt")"
  ;;
sampler-start) [ ! -e "$E/sampler.pid" ] || fail "sampler already started"; rm -f "$E/sampler.stop"; setsid bash "$(readlink -f "$0")" "$RUN" _sampler </dev/null >>"$E/sampler.log" 2>&1 & echo $! >"$E/sampler.pid"; log "sampler started pid=$(cat "$E/sampler.pid")" ;;
_sampler) sampler ;;
sampler-stop) touch "$E/sampler.stop"; sleep 3; log "sampler stop requested" ;;
ident) nz "$ARG" || fail "ident needs a label"; ident "$ARG"; cat "$E/obs/$ARG-summary.txt" ;;
b1)
  guard_full; once b1
  echo "$(ems)" >"$E/obs/b1-t0"
  OT=420 O sandbox create --name "$SBX" --from "$IMG" --detach --tty --restart-policy never --no-auto-providers \
    --label "exp008.run=$RUN" -- /usr/local/bin/counter.sh /sandbox/out >"$E/obs/b1-create.out" 2>"$E/obs/b1-create.err" </dev/null
  rc=$?; log "create rc=$rc"
  [ "$rc" = 0 ] || stop "B1 create failed rc=$rc: $(tr '\n' ' ' <"$E/obs/b1-create.err" | cut -c1-300)"
  sbx_json "$E/obs/b1-sandbox.json" || stop "B1 sandbox get failed"
  log "B1 sandbox get phase=$(sbx_phase "$E/obs/b1-sandbox.json") (Ready wait is in b1-soak)"
  id=$(jq -r '[.id, .sandbox.id, .metadata.id, .sandbox.metadata.id] | map(select(. != null)) | .[0] // empty' "$E/obs/b1-sandbox.json")
  nz "$id" || stop "B1: no sandbox id in sandbox get (see obs/b1-sandbox.json)"
  echo "$id" >"$E/sbx_id"
  K get sandboxes.agents.x-k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' >"$E/sbx_cr"
  [ "$(grep -c . "$E/sbx_cr")" = 1 ] && [ "$(cut -d/ -f1 "$E/sbx_cr")" = "$NS" ] || stop "expected exactly one Sandbox CR in $NS; got $(tr '\n' ' ' <"$E/sbx_cr")"
  cut -d/ -f2 "$E/sbx_cr" >"$E/sbx_cr_name"
  log "B1 created id=$id cr=$(cat "$E/sbx_cr")"
  ;;
b1-soak)
  guard_full; once b1-soak
  id=$(cat "$E/sbx_id"); t0=$(cat "$E/obs/b1-t0")
  waitfor $((t0 + 300000)) sbx_ready || stop "B1 sandbox not Ready within 300 s of create (phase=$(sbx_phase "$E/obs/poll.json"))"
  echo "ready_ms=$(( $(ems) - t0 ))" | tee "$E/obs/b1-times.txt"
  spods "$id" | jq "$PODF" >"$E/obs/b1-pods.json"
  jq -r '.items[] | select(.labels["openshell.ai/boundary-role"]=="workload") | .name' "$E/obs/b1-pods.json" >"$E/wpod"
  [ "$(grep -c . "$E/wpod")" = 1 ] || stop "expected exactly one workload pod; got: $(tr '\n' ' ' <"$E/wpod")"
  jq -r '.items[] | select(.labels["openshell.ai/boundary-role"]=="workload") | .containerStatuses[].name' "$E/obs/b1-pods.json" >"$E/obs/b1-wctrs.txt"
  nz "$ARG" && grep -q -x -F "$ARG" "$E/obs/b1-wctrs.txt" || stop "workload container '$ARG' not in: $(tr '\n' ' ' <"$E/obs/b1-wctrs.txt")"
  echo "$ARG" >"$E/wctr"
  ident b1-base || stop "B1: identity not readable (see obs/b1-base-P.txt)"
  log "B1 base: P=$(pkeys b1-base) W=$(wkeys b1-base)"
  while [ "$(ems)" -lt $((t0 + 300000)) ]; do sleep 5; done # 300 s bootstrap window from create
  sbx_json "$E/obs/b1-boot.json"; [ "$(sbx_phase "$E/obs/b1-boot.json")" = Ready ] || stop "B1: not Ready after the bootstrap window ($(sbx_phase "$E/obs/b1-boot.json"))"
  echo "$(ems)" >"$E/obs/b1-soak-t0"; end=$(($(ems) + 600000))
  while [ "$(ems)" -lt "$end" ]; do
    sleep 30
    ident b1-soak >/dev/null 2>&1 || stop "B1: identity read failed during soak (no retry)"
    [ "$(pkeys b1-soak)" = "$(pkeys b1-base)" ] && [ "$(wkeys b1-soak)" = "$(wkeys b1-base)" ] || { classify b1 b1-base b1-soak; stop "B1: identity changed during soak"; }
  done
  ack b1 || stop "B1: ACK failed"
  ident b1-end || stop "B1: end identity not readable"
  ack_matches b1 b1-end && log "B1 ACK identity matches" || stop "B1: ACK identity mismatch"
  cp "$E/obs/b1-soak-t0" "$E/obs/b1-t0.soak"; echo "$(cat "$E/obs/b1-soak-t0")" >"$E/obs/b1-t0"
  classify b1 b1-base b1-end; grab_logs b1
  echo "$(ems)" >"$E/obs/b1-done"
  log "B1 done"
  ;;
b2)
  guard_full; [ -e "$E/obs/b1-done" ] || fail "B1 not done"; once b2
  ident b2-before || stop "B2: identity not readable"
  old=$(gw_field '{.metadata.uid}'); nz "$old" || stop "B2: gateway pod UID unreadable"
  echo "old_gw_uid=$old" >"$E/obs/b2-times.txt"
  jq -r '.items[] | "\(.labels["openshell.ai/boundary-role"]) \(.annotations["openshell.ai/supervisor-token-expires-at"] // "-")"' "$E/obs/b2-before-C-pods.json" >"$E/obs/b2-token-expiry.txt"
  log "B2 token expiry annotations: $(tr '\n' ';' <"$E/obs/b2-token-expiry.txt")"
  rollback() { [ "$(K -n "$NS" get statefulset "$GW_STS" -o jsonpath='{.spec.replicas}')" = 1 ] || { log "ROLLBACK: restoring replicas=1"; kw scale "statefulset/$GW_STS" --replicas=1; }; }
  trap rollback EXIT INT TERM HUP
  echo "$(ems)" >"$E/obs/b2-t0"; t0=$(cat "$E/obs/b2-t0")
  kw scale "statefulset/$GW_STS" --replicas=0 || stop "B2 scale 0 refused/failed"
  if waitfor $((t0 + 60000)) sh -c '! "$@"' _ "${KC[@]}" --request-timeout=5s -n "$NS" get pod "$GW_POD"; then
    echo "gw_gone_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/b2-times.txt"
  else stop "B2: gateway pod still present 60 s after scale 0 (rollback runs)"; fi
  while [ "$(ems)" -lt $((t0 + 90000)) ]; do sleep 1; done
  kw scale "statefulset/$GW_STS" --replicas=1 || stop "B2 scale 1 failed (rollback retries once on exit)"
  echo "scale_up_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/b2-times.txt"
  waitfor $((t0 + OUTAGE_MAX * 1000)) gw_new_ready "$old" || stop "B2: new gateway pod not Ready within ${OUTAGE_MAX}s of scale-down"
  echo "gw_ready_ms=$(( $(ems) - t0 )) new_gw_uid=$(gw_field '{.metadata.uid}')" | tee -a "$E/obs/b2-times.txt"
  trap - EXIT INT TERM HUP
  waitfor $(($(ems) + 300000)) sbx_ready || { ident b2-unavail; classify b2 b2-before b2-unavail; grab_logs b2; stop "B2: sandbox not Ready within 300 s of gateway Ready (unavailable)"; }
  echo "sbx_ready_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/b2-times.txt"
  ack b2; arc=$?
  echo "ack_rc=$arc ack_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/b2-times.txt"
  ident b2-after; classify b2 b2-before b2-after; grab_logs b2
  ack_matches b2 b2-after && echo "ack_identity=matches_after" | tee -a "$E/obs/b2-times.txt"
  echo "$(ems)" >"$E/obs/b2-done"
  [ "$arc" = 0 ] || stop "B2: no valid ACK within 90 s"
  log "B2 done"
  ;;
b3)
  guard_full; [ -e "$E/obs/b2-done" ] || fail "B2 not done"; once b3
  r=$(cat "$E/obs/b2-done"); while [ "$(ems)" -lt $((r + 120000)) ]; do sleep 2; done
  ident b3-before || stop "B3: identity not readable"
  old=$(gw_field '{.metadata.uid}'); nz "$old" || stop "B3: gateway pod UID unreadable"
  echo "old_gw_uid=$old" >"$E/obs/b3-times.txt"
  jq -r '.items[] | "\(.labels["openshell.ai/boundary-role"]) \(.annotations["openshell.ai/supervisor-token-expires-at"] // "-")"' "$E/obs/b3-before-C-pods.json" >"$E/obs/b3-token-expiry.txt"
  echo "$(ems)" >"$E/obs/b3-t0"; t0=$(cat "$E/obs/b3-t0")
  kw delete pod "$GW_POD" --grace-period=1 --wait=false || stop "B3 delete refused/failed"
  waitfor $((t0 + OUTAGE_MAX * 1000)) gw_new_ready "$old" || stop "B3: new gateway pod not Ready within ${OUTAGE_MAX}s"
  echo "gw_ready_ms=$(( $(ems) - t0 )) new_gw_uid=$(gw_field '{.metadata.uid}')" | tee -a "$E/obs/b3-times.txt"
  waitfor $(($(ems) + 300000)) sbx_ready || { ident b3-unavail; classify b3 b3-before b3-unavail; grab_logs b3; stop "B3: sandbox not Ready within 300 s of gateway Ready (unavailable)"; }
  echo "sbx_ready_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/b3-times.txt"
  ack b3; arc=$?
  echo "ack_rc=$arc ack_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/b3-times.txt"
  ident b3-after; classify b3 b3-before b3-after; grab_logs b3
  ack_matches b3 b3-after && echo "ack_identity=matches_after" | tee -a "$E/obs/b3-times.txt"
  echo "$(ems)" >"$E/obs/b3-done"
  [ "$arc" = 0 ] || stop "B3: no valid ACK within 90 s"
  log "B3 done"
  ;;
b5)
  guard_full; [ -e "$E/obs/b3-done" ] || fail "B3 not done"; once b5
  ident b5-before || stop "B5: identity not readable"
  wpod=$(cat "$E/wpod"); sid=$(cat "$E/sbx_id")
  olduid=$(K -n "$NS" get pod "$wpod" -o jsonpath='{.metadata.uid}'); nz "$olduid" || stop "B5: workload pod UID unreadable"
  echo "old_wpod=$wpod old_wpod_uid=$olduid" >"$E/obs/b5-times.txt"
  echo "$(ems)" >"$E/obs/b5-t0"; t0=$(cat "$E/obs/b5-t0")
  kw delete pod "$wpod" --wait=false || stop "B5 delete refused/failed"
  oldgone() { local o; o=$(spods "$sid" 2>/dev/null | jq -r '.items[].metadata.uid') || return 1; ! grep -q -x -F "$olduid" <<<"$o"; }
  repl() { local o; o=$(spods "$sid" workload 2>/dev/null | jq -r '.items[] | "\(.metadata.name) \(.metadata.uid)"') || return 1; grep -v -F "$olduid" <<<"$o" | grep .; }
  waitfor $((t0 + 300000)) oldgone && echo "old_removed_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/b5-times.txt" || echo "old_removed=no within 300 s" | tee -a "$E/obs/b5-times.txt"
  if waitfor $((t0 + 300000)) repl; then echo "replacement=$(repl | head -1) at_ms=$(( $(ems) - t0 ))" | tee -a "$E/obs/b5-times.txt"; else echo "replacement=none within 300 s" | tee -a "$E/obs/b5-times.txt"; fi
  spods "$sid" | jq "$PODF" >"$E/obs/b5-replacement-pods.json"
  # process-level detection: does the replacement execute, and does its identity differ?
  if waitfor $((t0 + 300000)) kx "$E/obs/b5-Ptry.txt" && grep -q '^nonce=' "$E/obs/b5-Ptry.txt"; then
    echo "replacement_exec=yes" | tee -a "$E/obs/b5-times.txt"
  else echo "replacement_exec=no within 300 s ($(head -c 200 "$E/obs/b5-Ptry.txt.err" 2>/dev/null | tr '\n' ' '))" | tee -a "$E/obs/b5-times.txt"; fi
  ident b5-after; sbx_json "$E/obs/b5-final-sandbox.json"
  echo "final_phase=$(sbx_phase "$E/obs/b5-final-sandbox.json")" | tee -a "$E/obs/b5-times.txt"
  classify b5 b5-before b5-after; grab_logs b5
  log "B5 done"
  ;;
cleanup)
  [ -s "$E/sbx_id" ] || fail "no sandbox recorded"; once cleanup
  guard_ctx || stop "guard failed before cleanup"
  grab_logs cleanup-pre
  OT=180 O sandbox delete "$SBX" >"$E/obs/cleanup-delete.out" 2>"$E/obs/cleanup-delete.err"; rc=$?; log "sandbox delete rc=$rc"
  id=$(cat "$E/sbx_id")
  objs() { local o o2 o3 c; o=$(K -n "$NS" get pods,pvc,secret,service,networkpolicy -l "openshell.ai/sandbox-id=$id" -o name 2>/dev/null) || return 1; o2=$(K -n "$NS" get pods,pvc,secret,service,networkpolicy -l "openshell.ai/boundary-pair=$id" -o name 2>/dev/null) || return 1; o3=$(K -n "$NS" get pods,pvc -o name 2>/dev/null | grep -F "$SBX") ; o="$o$o2$o3"; c=$(sandboxes_all 2>/dev/null) || return 1; printf '%s%s' "$o" "$c"; }
  gone() { local x; x=$(objs) || return 1; [ -z "$x" ]; }
  waitfor $(($(ems) + 300000)) gone || { objs >"$E/obs/cleanup-residue.txt"; stop "cleanup: experiment objects remain (no manual finalizer/controller action; owner approval required)"; }
  log "experiment objects gone (by sandbox-id label, and no Sandbox CRs)"
  ;;
post)
  inventory "$E/inv/post"
  (cd "$E/inv" && for f in b0-pre/*; do b=${f#b0-pre/}; diff -u "b0-pre/$b" "post/$b" >"diff-$b.txt" 2>&1 && rm -f "diff-$b.txt"; done; ls diff-* 2>/dev/null) | tee "$E/inv/diff-files.txt"
  ;;
logout) O gateway logout "$GWNAME" >"$E/obs/logout.out" 2>&1; log "gateway logout rc=$?" ;;
*) echo "unknown step $STEP" >&2; exit 2 ;;
esac
