# shellcheck shell=bash
# EXP-002 harness: drive the in-cluster Herdr pod from a workstation with
# kubectl exec. The controller never runs inside the pod it disrupts.
#
# Required: CTX (kubectl context). Optional: NS (herdrnetes-exp), POD (herdr-0),
# EXP_EVIDENCE (private raw evidence root, default $XDG_DATA_HOME/exp002; must
# be outside this repository). Every pod-contacting entry point calls
# check_target first, so a wrong context/namespace/pod fails closed.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPARE="$HERE/../../exp-001/compare.py"
# shellcheck disable=SC2034 # used by scenario.sh
RECOVERY="$HERE/recovery.py"
: "${CTX:?set CTX to the kubectl context}"
NS=${NS:-herdrnetes-exp}
POD=${POD:-herdr-0}
EXP_EVIDENCE=${EXP_EVIDENCE:-${XDG_DATA_HOME:-$HOME/.local/share}/exp002}
# Raw evidence and backups hold transcripts and credentials: owner-only from creation.
umask 077

die() { echo "$*" >&2; exit 3; }
# Run ids and labels become pod and local paths: one lowercase path segment only.
safe_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "unsafe name '$1' (want [a-z0-9][a-z0-9-]*)"; }

repo_root=$(git -C "$HERE" rev-parse --show-toplevel)
case "$(realpath -m "$EXP_EVIDENCE")/" in
"$repo_root"/*) die "EXP_EVIDENCE=$EXP_EVIDENCE is inside the public repository; use a private path" ;;
esac

k() { kubectl --context "$CTX" -n "$NS" "$@"; }
# Run a command in the Herdr container (container env: HOME, XDG_*, HERDR_CONFIG_PATH).
kx() { k exec "$POD" -c herdr -- "$@"; }
h() { kx herdr "$@"; }
now() { date -u +%FT%T.%3NZ; }
epoch() { date +%s.%N; }

run_use() {
  safe_name "$1"
  RUN=$1
  RUN_DIR="$EXP_EVIDENCE/$RUN"
  WS_ROOT="/workspace/exp/$RUN"
  mkdir -p "$RUN_DIR"
  export RUN RUN_DIR WS_ROOT
}

log() { printf '%s %s\n' "$(now)" "$*" | tee -a "$RUN_DIR/timeline.log" >&2; }

# The intended workload: the experiment namespace and the StatefulSet's only pod
# with the experiment labels and a `herdr` container. Anything else is refused.
check_target() {
  local ns pod
  ns=$(kubectl --context "$CTX" get namespace "$NS" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}') ||
    die "namespace $NS not found in context $CTX"
  [ "$ns" = herdrnetes-exp ] || die "namespace $NS is not the herdrnetes-exp experiment namespace"
  pod=$(k get pod "$POD" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}/{.metadata.labels.app\.kubernetes\.io/part-of}/{.metadata.ownerReferences[0].kind}/{.spec.containers[*].name}') ||
    die "pod $NS/$POD not found"
  [ "$pod" = herdr/herdrnetes-exp/StatefulSet/herdr ] || die "pod $NS/$POD is not the experiment Herdr pod ($pod)"
}

# Disruptive or destructive actions need an explicit, target-specific opt-in:
# EXP_ACK="<action> <ns>/<pod>" or the same text typed at a terminal prompt.
require_ack() {
  local want="$1 $NS/$POD" got=""
  [ "${EXP_ACK:-}" = "$want" ] && return 0
  if [ -t 0 ]; then
    printf '%s is test-only and interrupts every agent in %s/%s. Type "%s" to proceed: ' "$1" "$NS" "$POD" "$want" >&2
    read -r got
    [ "$got" = "$want" ] && return 0
  fi
  die "refusing $1: set EXP_ACK=\"$want\" to confirm"
}

pane_id() { # pane_id <workspace-label> <tab-index> <pane-index>
  h api snapshot | uv run --script "$COMPARE" pane-id "$1" "$2" "$3"
}

pod_uid() { k get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null; }

# Pod/Kubernetes-level facts: identity, node, image digest, restarts, timings.
pod_facts() {
  k get pod "$POD" -o json | uv run --no-project python -c '
import json, sys
p = json.load(sys.stdin)
cs = (p["status"].get("containerStatuses") or [{}])[0]
cond = {c["type"]: c.get("lastTransitionTime") for c in p["status"].get("conditions", [])}
st = cs.get("state", {})
last = cs.get("lastState", {}).get("terminated") or {}
print(json.dumps({
  "uid": p["metadata"]["uid"],
  "node": p["spec"].get("nodeName"),
  "image": cs.get("image"),
  "imageID": cs.get("imageID"),
  "restartCount": cs.get("restartCount"),
  "pod_created": p["metadata"]["creationTimestamp"],
  "pod_scheduled": cond.get("PodScheduled"),
  "initialized": cond.get("Initialized"),
  "container_started": (st.get("running") or {}).get("startedAt"),
  "ready": cond.get("Ready") if cs.get("ready") else None,
  "last_terminated": {k: last.get(k) for k in ("reason", "exitCode", "signal", "startedAt", "finishedAt")} if last else None,
}, indent=1))'
}

server_pid() { kx pgrep -xf '/usr/local/bin/herdr server'; }

wait_ready() { # wait until the pod (with a new uid if given) is Ready
  local old_uid=${1:-}
  for _ in $(seq 1 600); do
    if [ "$(pod_uid)" != "$old_uid" ] &&
      [ "$(k get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = true ]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}
