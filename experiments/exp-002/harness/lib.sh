# shellcheck shell=bash
# EXP-002 harness: drive the in-cluster Herdr pod from a workstation with
# kubectl exec. The controller never runs inside the pod it disrupts.
#
# Required: CTX (kubectl context). Optional: NS (herdrnetes-exp), POD (herdr-0),
# EXP_EVIDENCE (local evidence root, default ./evidence-local; never commit raw).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPARE="$HERE/../../exp-001/compare.py"
: "${CTX:?set CTX to the kubectl context}"
NS=${NS:-herdrnetes-exp}
POD=${POD:-herdr-0}
EXP_EVIDENCE=${EXP_EVIDENCE:-$PWD/evidence-local}

k() { kubectl --context "$CTX" -n "$NS" "$@"; }
# Run a command in the Herdr container (container env: HOME, XDG_*, HERDR_CONFIG_PATH).
kx() { k exec "$POD" -c herdr -- "$@"; }
h() { kx herdr "$@"; }
now() { date -u +%FT%T.%3NZ; }
epoch() { date +%s.%N; }

run_use() {
  RUN=$1
  RUN_DIR="$EXP_EVIDENCE/$RUN"
  WS_ROOT="/workspace/exp/$RUN"
  mkdir -p "$RUN_DIR"
  export RUN RUN_DIR WS_ROOT
}

log() { printf '%s %s\n' "$(now)" "$*" | tee -a "$RUN_DIR/timeline.log" >&2; }

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
