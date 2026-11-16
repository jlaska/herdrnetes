#!/usr/bin/env bash
# EXP-003 scenario driver: one disposable workspace for remote-client tests.
#
#   CTX=<context> scenario.sh setup    <run>              # workspace exp003-<run>, two sentinel panes
#   CTX=<context> scenario.sh identity <run> <label>      # record pod/server/pane identities
#   CTX=<context> scenario.sh identity-diff <run> <a> <b> # exit non-zero if server/pane shells changed
#   CTX=<context> scenario.sh cleanup  <run> [--yes]      # dry run; --yes (+ EXP_ACK) closes only that
#                                                         # workspace and removes /workspace/exp003/<run>
# Nothing here stops the server, deletes the pod, or touches other workspaces, panes or agents.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=experiments/exp-003/harness/lib.sh source-path=SCRIPTDIR
source "$HERE/lib.sh"

cmd=$1
run_use "$2"
shift 2
check_target

MARKER=.exp003-run
WS_LABEL=exp003-$RUN
# The run's workspace root must be a real directory carrying this run's marker.
check_ws_root() {
  [ "$(kx realpath -e "$WS_ROOT")" = "$WS_ROOT" ] || die "$WS_ROOT is missing or not a plain directory"
  [ "$(kx cat "$WS_ROOT/$MARKER" 2>/dev/null)" = "$RUN" ] || die "$WS_ROOT has no $MARKER for run $RUN; not touching it"
}

# Workspace ids whose label is exactly exp003-<run> (normally zero or one).
ws_ids() {
  h workspace list | uv run --no-project python -c '
import json, sys
for w in json.load(sys.stdin)["result"]["workspaces"]:
    if w["label"] == sys.argv[1]:
        print(w["workspace_id"])' "$WS_LABEL"
}

# Run a sentinel in a pane; print "<foreground pid> <shell pid>" once a process matching
# <needle> is in the pane's foreground (fails if it never appears).
sentinel() { # sentinel <pane> <command> <needle>
  local pane=$1 pid=""
  h pane run "$pane" "$2" >/dev/null
  for _ in $(seq 1 20); do
    pid=$(h pane process-info --pane "$pane" | uv run --no-project python -c '
import json, sys
i = json.load(sys.stdin)["result"]["process_info"]
for p in i.get("foreground_processes") or []:
    if sys.argv[1] in p.get("cmdline", ""):
        print(p["pid"], i["shell_pid"]); break' "$3")
    [ -n "$pid" ] && break
    sleep 0.5
  done
  [ -n "$pid" ] || die "sentinel '$2' not running in $pane"
  echo "$pid"
}

case "$cmd" in
setup)
  [ -z "$(ws_ids)" ] || die "workspace $WS_LABEL already exists"
  if kx test -e "$WS_ROOT"; then check_ws_root; else kx mkdir -p "$WS_ROOT"; fi
  kx sh -c "printf '%s\n' '$RUN' >'$WS_ROOT/$MARKER'"
  h status server >/dev/null
  W=$(h workspace create --cwd "$WS_ROOT" --label "$WS_LABEL" --no-focus |
    uv run --no-project python -c 'import json,sys;print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])')
  P2=$(h pane split "$W" --direction right --cwd "$WS_ROOT" --no-focus |
    uv run --no-project python -c 'import json,sys;print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
  sleep 2 # let both shells reach a prompt before typing into them
  s1=$(sentinel "$W" 'sleep 86400' 'sleep 86400')
  # shellcheck disable=SC2016 # runs in the pane shell
  s2=$(sentinel "$P2" 'while :; do date; sleep 5; done' 'sleep 5')
  # Columns: pane, sentinel, foreground pid, pane shell pid. The ticker's foreground pid is
  # a short-lived `sleep 5`; the shell running the loop is its stable identity.
  printf '%s sleep %s\n%s ticker %s\n' "$W" "$s1" "$P2" "$s2" >"$RUN_DIR/sentinels.txt"
  log "setup complete: $WS_LABEL panes $W (sleep: $s1) and $P2 (ticker: $s2)"
  sleep 7 # > 5 s autosave debounce
  identity baseline
  ;;

identity)
  identity "$1"
  ;;

identity-diff)
  identity_diff "$1" "$2"
  ;;

cleanup)
  check_ws_root
  ids=$(ws_ids)
  echo "workspace(s) labelled $WS_LABEL: ${ids:-none}" >&2
  kx find "$WS_ROOT" -maxdepth 2
  if [ "${1:-}" != --yes ]; then
    echo "dry run: the workspace above would be closed and $WS_ROOT removed; rerun with --yes" >&2
    exit 0
  fi
  require_ack "cleanup-$RUN"
  for w in $ids; do h workspace close "$w" >/dev/null; done
  kx rm -rf -- "$WS_ROOT"
  log "closed $WS_LABEL and removed $WS_ROOT"
  ;;

*)
  echo "unknown command $cmd" >&2
  exit 2
  ;;
esac
