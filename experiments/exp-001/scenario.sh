#!/usr/bin/env bash
# EXP-001 scenario driver. Every subcommand operates on one isolated run.
#
#   scenario.sh init     <run> [osc7=0|1] [pane_history=0|1]
#   scenario.sh setup    <run>            # scenario A layout, repos, shell state
#   scenario.sh agent    <run> [model]    # start Claude Code in beta and seed a codeword
#   scenario.sh cd-only  <run>            # cd in a pane with no structural change
#   scenario.sh split-now <run>           # structural change, no wait for autosave
#   scenario.sh restart  <run> clean|term|kill|kill-noclient|clean-noclient [herdr-bin]
#   scenario.sh start    <run> [herdr-bin] [client|headless]
#   scenario.sh probe    <run> <label>    # capture + per-pane probes
#   scenario.sh ask      <run>            # ask the restored agent for the codeword
#   scenario.sh stop     <run>
#
# Herdr binary for each start is HERDR_BIN (default: herdr on PATH).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$HERE/lib.sh"

cmd=$1 run=$2
shift 2

log() { printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$*" | tee -a "$EXP_ROOT/evidence/timeline.log"; }

pane_id() { # pane_id <workspace-label> <tab-index> <pane-index>
  h api snapshot | uv run --script "$HERE/compare.py" pane-id "$1" "$2" "$3"
}

# Disposable repos must not inherit the operator's global git config
# (commit signing would prompt for a hardware key).
g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }

make_repo() {
  local d=$EXP_ROOT/repos/$1
  mkdir -p "$d/sub"
  g -C "$d" init -q -b main
  echo "committed $1" >"$d/README.md"
  echo "sub $1" >"$d/sub/file.txt"
  g -C "$d" add -A
  g -C "$d" -c commit.gpgsign=false -c user.name=exp -c user.email=exp@example.invalid commit -qm init
  echo "UNCOMMITTED-$1" >>"$d/README.md"
  echo "UNTRACKED-$1" >"$d/untracked.txt"
}

# Kill leftover processes whose cwd is inside this run (never matched by name).
kill_run_orphans() {
  local p
  for p in /proc/[0-9]*; do
    case "$(readlink "$p/cwd" 2>/dev/null)" in
    "$EXP_ROOT"/*) kill "${p#/proc/}" 2>/dev/null || true ;;
    esac
  done
}

start_server() { # start_server [client|headless]
  local mode=${1:-client}
  if [ "$mode" = headless ]; then
    # Headless server only (no TUI client), as a pod entrypoint would run it.
    local -a e
    mapfile -t e < <(exp_env)
    setsid "${e[@]}" "$HERDR_BIN" server >>"$EXP_ROOT/evidence/headless-stdout.log" 2>&1 </dev/null &
    for _ in $(seq 1 100); do h status server >/dev/null 2>&1 && break; sleep 0.1; done
  else
    exp_client_start
  fi
  exp_guard
  local spid
  spid=$(exp_server_pid)
  tr '\0' '\n' <"/proc/$spid/environ" | cut -d= -f1 | sort >"$EXP_ROOT/evidence/server-env-keys.txt"
  if grep -qE '^(CLAUDE|HERDR_(SOCKET_PATH|SESSION|PANE_ID|ENV)$|SSH_AUTH_SOCK)' "$EXP_ROOT/evidence/server-env-keys.txt"; then
    echo "server environment leaked controller variables" >&2
    exit 1
  fi
  log "server started pid=$spid bin=$("$HERDR_BIN" --version) mode=$mode"
}

case "$cmd" in
init)
  exp_init "$run" "${1:-0}" "${2:-0}"
  ;;

setup)
  exp_use "$run"
  make_repo alpha
  make_repo beta
  start_server client
  A=$(h workspace create --cwd "$EXP_ROOT/repos/alpha" --label alpha --no-focus |
    uv run --script "$HERE/compare.py" field workspace.workspace_id)
  a1=$(pane_id alpha 0 0)
  h pane rename "$a1" editor >/dev/null
  h pane run "$a1" 'cd sub && export EXP_VAR=alpha-editor && echo MARK-A1' >/dev/null
  a2=$(h pane split "$a1" --direction right --cwd "$EXP_ROOT/repos/alpha" --no-focus |
    uv run --script "$HERE/compare.py" field pane.pane_id)
  h pane run "$a2" 'echo MARK-A2; sleep 86400' >/dev/null
  h tab create --workspace "$A" --cwd "$EXP_ROOT/repos/alpha/sub" --label build --no-focus >/dev/null
  a3=$(pane_id alpha 1 0)
  h pane run "$a3" 'echo MARK-A3 && git status --short' >/dev/null
  h workspace create --cwd "$EXP_ROOT/repos/beta" --label beta --no-focus >/dev/null
  b1=$(pane_id beta 0 0)
  h pane run "$b1" 'echo MARK-B1 && uv run --no-project python -m http.server 0 >/dev/null 2>&1 &' >/dev/null
  h pane split "$b1" --direction down --cwd "$EXP_ROOT/repos/beta" --no-focus >/dev/null
  sleep 7 # > 5 s autosave debounce
  log "setup complete"
  bash "$0" probe "$run" baseline
  ;;

agent)
  exec bash "$HERE/agent-seed.sh" "$run" "${1:-haiku}"
  ;;

cd-only)
  exp_use "$run"
  a3=$(pane_id alpha 1 0)
  h pane run "$a3" "cd $EXP_ROOT/repos/beta" >/dev/null
  log "cd-only issued in alpha/build -> repos/beta"
  ;;

split-now)
  exp_use "$run"
  b1=$(pane_id beta 0 0)
  h pane split "$b1" --direction right --cwd "$EXP_ROOT/repos/beta/sub" --no-focus >/dev/null
  log "split-now issued in beta (no autosave wait)"
  ;;

start)
  exp_use "$run"
  export HERDR_BIN=${1:-$HERDR_BIN}
  start_server "${2:-client}"
  ;;

restart)
  exp_use "$run"
  mode=$1
  export HERDR_BIN=${2:-$HERDR_BIN}
  log "restart mode=$mode"
  case "$mode" in
  clean | clean-noclient) exp_stop_clean ;;
  term) exp_kill TERM ;;
  kill | kill-noclient) exp_kill KILL ;;
  *) echo "unknown restart mode $mode" >&2; exit 2 ;;
  esac
  exp_client_detach
  log "server gone"
  cp -a "$EXP_ROOT/config/herdr/session.json" "$EXP_ROOT/evidence/session-after-stop-$mode.json" 2>/dev/null || true
  # Shell children outlive SIGKILL only until the PTY hangs up; record survivors.
  for p in /proc/[0-9]*; do
    case "$(readlink "$p/cwd" 2>/dev/null)" in
    "$EXP_ROOT"/*) echo "${p#/proc/} $(tr '\0' ' ' <"$p/cmdline")" ;;
    esac
  done >"$EXP_ROOT/evidence/survivors-$mode.txt"
  case "$mode" in
  *-noclient) start_server headless ;;
  *) start_server client ;;
  esac
  sleep 8 # agent resume runs ~750 ms after geometry; give restored shells time
  bash "$0" probe "$run" "after-$mode"
  # Exported shell variables live only in the dead shell process.
  a1=$(pane_id alpha 0 0)
  h pane run "$a1" 'echo "ENVCHECK EXP_VAR=[$EXP_VAR] cwd=$PWD"' >/dev/null
  sleep 1
  h pane read "$a1" --lines 5 --source recent | grep '^ENVCHECK' |
    tee "$EXP_ROOT/evidence/after-$mode/envcheck.txt" || true
  ;;

probe)
  exp_use "$run"
  label=$1
  exp_capture "$label"
  out=$EXP_ROOT/evidence/$label
  h api snapshot | uv run --script "$HERE/compare.py" panes >"$out/panes.tsv"
  while IFS=$'\t' read -r pid _rest; do
    [ "$pid" = pane_id ] && continue
    {
      echo "### $pid"
      h pane process-info --pane "$pid" | uv run --script "$HERE/compare.py" procs
      echo "--- screen (last 15 lines)"
      h pane read "$pid" --lines 15 --source recent 2>&1 | sed 's/[[:space:]]*$//' | grep -v '^$' || true
    } >>"$out/pane-probes.txt"
  done <"$out/panes.tsv"
  for r in alpha beta; do
    [ -d "$EXP_ROOT/repos/$r" ] && g -C "$EXP_ROOT/repos/$r" status --short | sed "s/^/$r: /"
  done >"$out/git-status.txt"
  grep -c MARK "$EXP_ROOT/shellhist/bash_history" >"$out/history-mark-count.txt" 2>/dev/null || echo 0 >"$out/history-mark-count.txt"
  log "probe $label"
  cat "$out/panes.tsv"
  ;;

ask)
  exp_use "$run"
  b2=$(pane_id beta 0 1)
  h agent get "$b2" >"$EXP_ROOT/evidence/agent-after.json" 2>&1 || true
  h agent prompt "$b2" "What codeword did I ask you to remember earlier? Reply with only the codeword, or NONE." \
    --wait --timeout 120000 >/dev/null || true
  sleep 2
  h pane read "$b2" --lines 40 --source recent >"$EXP_ROOT/evidence/agent-answer.txt" 2>&1 || true
  if grep -q 'HERDR-ZEBRA-42' <(grep -v 'remember' "$EXP_ROOT/evidence/agent-answer.txt"); then
    log "agent recalled codeword: YES"
  else
    log "agent recalled codeword: NO"
  fi
  ;;

stop)
  exp_use "$run"
  exp_stop_clean || true
  exp_client_detach
  kill_run_orphans
  log "stopped"
  ;;

*)
  echo "unknown command $cmd" >&2
  exit 2
  ;;
esac
