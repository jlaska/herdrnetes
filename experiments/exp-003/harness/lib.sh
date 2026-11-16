# shellcheck shell=bash
# EXP-003 harness: remote-client tests against the EXP-002 Herdr pod. Reuses the EXP-002
# target checks and pod helpers; everything here is client-side or read-only in the pod.
#
# Required: CTX (kubectl context). Optional: NS, POD, EXP_EVIDENCE (private raw evidence
# root, default $XDG_DATA_HOME/exp003; must be outside this repository).
H3=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IDENTITY="$H3/identity.py"
EXP_EVIDENCE=${EXP_EVIDENCE:-${XDG_DATA_HOME:-$HOME/.local/share}/exp003}
# shellcheck source=experiments/exp-002/harness/lib.sh source-path=SCRIPTDIR
source "$H3/../../exp-002/harness/lib.sh"
# shellcheck disable=SC2034 # read by exp-002 helpers
HERE=$H3 # exp-002's lib.sh sets HERE to its own directory
HERDR_BIN=${HERDR_BIN:-herdr}

# Same run-id rules as exp-002, but the workspace root is /workspace/exp003/<run>.
run_use() {
  safe_name "$1"
  RUN=$1
  RUN_DIR="$EXP_EVIDENCE/$RUN"
  WS_ROOT="/workspace/exp003/$RUN"
  mkdir -p "$RUN_DIR"
  export RUN RUN_DIR WS_ROOT
}

# Record who is running, as identities rather than counts. Written to
# $RUN_DIR/<label>/identity.json; compare two with `identity-diff`. Read-only in the pod.
identity() {
  local label=$1 out="$RUN_DIR/$1" tmp pane f
  safe_name "$label"
  mkdir -p "$out"
  tmp=$(mktemp -d) # raw API output holds agent session refs: removed before returning
  pod_facts >"$tmp/pod.json"
  h status server --json >"$tmp/status.json"
  h api snapshot >"$tmp/snapshot.json"
  # Server PID, /proc stat (start time in ticks), boot time and tick rate, one per line.
  # shellcheck disable=SC2016 # expanded by the pod shell
  kx sh -c 'p=$(pgrep -xf "/usr/local/bin/herdr server") || exit 1
    echo "$p"; cat "/proc/$p/stat"; awk "/^btime/{print \$2}" /proc/stat; getconf CLK_TCK' >"$tmp/server.txt"
  "$HERDR_BIN" --version >"$tmp/client-version.txt"
  for pane in $(uv run --no-project python -c 'import json,sys;print(*[p["pane_id"] for p in json.load(open(sys.argv[1]))["result"]["snapshot"]["panes"]])' "$tmp/snapshot.json"); do
    f="$tmp/proc-${pane//:/_}.json"
    # A pane without a shell has no process info; identity.py records null.
    h pane process-info --pane "$pane" >"$f" 2>/dev/null || : >"$f"
  done
  if ! uv run --script "$IDENTITY" build "$tmp" >"$out/identity.json"; then rm -rf "$tmp"; die "identity $label failed"; fi
  rm -rf "$tmp"
  log "identity $label: server pid $(uv run --no-project python -c 'import json,sys;print(json.load(open(sys.argv[1]))["server"]["pid"])' "$out/identity.json")"
}

identity_diff() { # identity_diff <label-a> <label-b>; non-zero if the server or a pane shell was replaced
  uv run --script "$IDENTITY" diff "$RUN_DIR/$1/identity.json" "$RUN_DIR/$2/identity.json"
}
