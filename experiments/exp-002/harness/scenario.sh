#!/usr/bin/env bash
# EXP-002 Kubernetes scenario driver (ported from experiments/exp-001/scenario.sh).
#
#   CTX=<context> scenario.sh setup   <run>        # repos + layout in the pod, baseline probe
#   CTX=<context> scenario.sh agent   <run> [model] # claude in beta/0:1/1, codeword seed
#   CTX=<context> scenario.sh probe   <run> <label>
#   CTX=<context> scenario.sh disrupt <run> <mode>  # then measure recovery and probe
#        modes: delete      kubectl delete pod (SIGTERM, default grace)
#               grace1      kubectl delete pod --grace-period=1
#               force       kubectl delete pod --grace-period=0 --force
#               kill        SIGKILL herdr inside the container (container restart, same pod)
#               oom         allocate past the memory limit from a pane (cgroup OOM)
#               external    no action; wait for a pod replacement done elsewhere
#                           (Argo CD sync, rollout); the old pod uid is recorded first
#   CTX=<context> scenario.sh ask     <run>        # codeword recall in the restored agent
#   CTX=<context> scenario.sh cd-only|split-now <run>
#   CTX=<context> scenario.sh backup  <run> <label> # tar of Herdr + agent state (local, private)
#   CTX=<context> scenario.sh cleanup <run>        # remove the run's repos from the workspace PVC
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=experiments/exp-002/harness/lib.sh source-path=SCRIPTDIR
source "$HERE/lib.sh"

cmd=$1
run_use "$2"
shift 2

g() { kx env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }

make_repo() {
  local d=$WS_ROOT/$1
  kx mkdir -p "$d/sub"
  g -C "$d" init -q -b main
  kx sh -c "echo 'committed $1' >'$d/README.md'; echo 'sub $1' >'$d/sub/file.txt'"
  g -C "$d" add -A
  g -C "$d" -c commit.gpgsign=false -c user.name=exp -c user.email=exp@example.invalid commit -qm init
  kx sh -c "echo 'UNCOMMITTED-$1' >>'$d/README.md'; echo 'UNTRACKED-$1' >'$d/untracked.txt'"
}

probe() {
  local label=$1 out="$RUN_DIR/$1"
  mkdir -p "$out"
  pod_facts >"$out/pod.json"
  h api snapshot >"$out/api-snapshot.json" 2>&1 || true
  uv run --script "$COMPARE" panes <"$out/api-snapshot.json" >"$out/panes.tsv" || true
  h agent list >"$out/agents.json" 2>&1 || true
  kx cat /home/herdr/.config/herdr/session.json >"$out/session.json" 2>/dev/null || true
  kx sh -c 'cd ~/.config/herdr && ls -la --time-style=full-iso . session-snapshots session-backups 2>&1' >"$out/herdr-dir.txt" || true
  kx sh -c 'tail -n 200 ~/.config/herdr/herdr-server.log' >"$out/herdr-server.log.tail" 2>/dev/null || true
  kx sh -c 'grep -h HERDR_INTEGRATION_VERSION ~/.claude/hooks/herdr-agent-state.sh ~/.codex/herdr-agent-state.sh; herdr integration status' >"$out/hooks.txt" 2>&1 || true
  : >"$out/pane-probes.txt"
  while IFS=$'\t' read -r pid _rest; do
    [ "$pid" = pane_id ] && continue
    {
      echo "### $pid"
      # A pane restored without a shell (restore_error) has no process info.
      h pane process-info --pane "$pid" | uv run --script "$COMPARE" procs || echo "fg: (no process)"
      echo "--- screen (last 15 lines)"
      h pane read "$pid" --lines 15 --source recent 2>&1 | sed 's/[[:space:]]*$//' | grep -v '^$' || true
    } >>"$out/pane-probes.txt"
  done <"$out/panes.tsv"
  for r in alpha beta; do
    g -C "$WS_ROOT/$r" status --short 2>/dev/null | sed "s/^/$r: /" || echo "$r: MISSING"
  done >"$out/git-status.txt"
  kx sh -c 'grep -c MARK ~/.bash_history 2>/dev/null || echo 0' >"$out/history-mark-count.txt" || true
  log "probe $label"
  cat "$out/panes.tsv"
}

# Poll recovery after a replacement, independently of pod readiness.
# Writes recovery.json with controller wall-clock times (UTC).
measure_recovery() {
  local mode=$1 t0=$2 base_ws base_panes want_agent=0
  local out="$RUN_DIR/after-$mode"
  mkdir -p "$out"
  base_ws=$(uv run --no-project python -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["result"]["snapshot"]["workspaces"]))' "$RUN_DIR/baseline/api-snapshot.json" 2>/dev/null || echo 0)
  base_panes=$(($(wc -l <"$RUN_DIR/baseline/panes.tsv") - 1))
  [ -s "$RUN_DIR/agent-before.json" ] && want_agent=1
  local t_ready="" t_layout="" t_agent="" snap ws panes agents
  for _ in $(seq 1 600); do
    if [ -z "$t_ready" ] && h status server >/dev/null 2>&1; then t_ready=$(epoch); fi
    if [ -n "$t_ready" ]; then
      snap=$(h api snapshot 2>/dev/null || true)
      read -r ws panes agents < <(uv run --no-project python -c '
import json,sys
try:
  s=json.loads(sys.stdin.read())["result"]["snapshot"]
  print(len(s["workspaces"]), len(s["panes"]), sum(1 for p in s["panes"] if p.get("agent")=="claude"))
except Exception: print(0,0,0)' <<<"$snap")
      if [ -z "$t_layout" ] && [ "$ws" -ge "$base_ws" ] && [ "$panes" -ge "$base_panes" ]; then t_layout=$(epoch); fi
      if [ "$want_agent" = 1 ] && [ -z "$t_agent" ] && [ "$agents" -ge 1 ]; then t_agent=$(epoch); fi
      if [ -n "$t_layout" ] && { [ "$want_agent" = 0 ] || [ -n "$t_agent" ]; }; then break; fi
    fi
    sleep 0.5
  done
  uv run --no-project python -c '
import json,sys
t0,r,l,a=(float(x) if x else None for x in sys.argv[1:5])
rel=lambda t: round(t-t0,2) if t else None
print(json.dumps({"disruption_start_epoch":t0,"server_answers_s":rel(r),"layout_restored_s":rel(l),"agent_detected_s":rel(a)},indent=1))' \
    "$t0" "$t_ready" "$t_layout" "$t_agent" | tee "$out/recovery.json"
}

case "$cmd" in
setup)
  make_repo alpha
  make_repo beta
  h status server >/dev/null
  A=$(h workspace create --cwd "$WS_ROOT/alpha" --label alpha --no-focus |
    uv run --script "$COMPARE" field workspace.workspace_id)
  a1=$(pane_id alpha 0 0)
  h pane rename "$a1" editor >/dev/null
  h pane run "$a1" 'cd sub && export EXP_VAR=alpha-editor && echo MARK-A1' >/dev/null
  a2=$(h pane split "$a1" --direction right --cwd "$WS_ROOT/alpha" --no-focus |
    uv run --script "$COMPARE" field pane.pane_id)
  h pane run "$a2" 'echo MARK-A2; sleep 86400' >/dev/null
  h tab create --workspace "$A" --cwd "$WS_ROOT/alpha/sub" --label build --no-focus >/dev/null
  a3=$(pane_id alpha 1 0)
  h pane run "$a3" 'echo MARK-A3 && git status --short' >/dev/null
  h workspace create --cwd "$WS_ROOT/beta" --label beta --no-focus >/dev/null
  b1=$(pane_id beta 0 0)
  h pane run "$b1" 'echo MARK-B1 && python3 -m http.server 0 >/dev/null 2>&1 &' >/dev/null
  h pane split "$b1" --direction down --cwd "$WS_ROOT/beta" --no-focus >/dev/null
  sleep 7 # > 5 s autosave debounce
  log "setup complete"
  probe baseline
  ;;

agent)
  model=${1:-haiku}
  b2=$(pane_id beta 0 1)
  h pane run "$b2" "claude --model $model" >/dev/null
  answered=0
  for _ in $(seq 1 90); do
    screen=$(h pane read "$b2" --lines 30 --source visible 2>/dev/null || true)
    if [ "$answered" = 0 ] && grep -qi 'trust' <<<"$screen"; then
      grep -q 'Yes, I trust this folder' <<<"$screen" || { echo "unexpected trust dialog:" >&2; echo "$screen" >&2; exit 1; }
      h pane send-keys "$b2" down >/dev/null
      sleep 0.5
      grep -q '❯ *Yes, I trust' <<<"$(h pane read "$b2" --lines 30 --source visible)" || { echo "could not select Yes" >&2; exit 1; }
      h pane send-keys "$b2" enter >/dev/null
      answered=1
      log "answered folder trust prompt"
      sleep 2
      continue
    fi
    if h agent get "$b2" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  h agent get "$b2" >/dev/null || { h pane read "$b2" --lines 30 --source visible >&2; exit 1; }
  log "claude detected in $b2"
  h agent wait "$b2" --until idle --timeout 90000 >/dev/null
  h agent prompt "$b2" "For a persistence test, remember the codeword HERDR-KITE-77. Reply with only: OK" \
    --wait --timeout 120000 >/dev/null
  sleep 7
  h agent get "$b2" >"$RUN_DIR/agent-before.json" || true
  log "agent seeded in $b2 (model=$model)"
  ;;

ask)
  b2=$(pane_id beta 0 1)
  label=${1:-ask}
  h agent get "$b2" >"$RUN_DIR/agent-$label.json" 2>&1 || true
  h agent wait "$b2" --until idle --timeout 60000 >/dev/null 2>&1 || true
  h agent prompt "$b2" "What codeword did I ask you to remember earlier? Reply with only the codeword, or NONE." \
    --wait --timeout 120000 >/dev/null || true
  sleep 2
  h pane read "$b2" --lines 40 --source recent >"$RUN_DIR/answer-$label.txt" 2>&1 || true
  if grep -v 'remember' "$RUN_DIR/answer-$label.txt" | grep -q 'HERDR-KITE-77'; then
    log "agent recalled codeword ($label): YES"
  else
    log "agent recalled codeword ($label): NO"
  fi
  ;;

cd-only)
  a3=$(pane_id alpha 1 0)
  h pane run "$a3" "cd $WS_ROOT/beta" >/dev/null
  log "cd-only issued in alpha/build -> beta"
  ;;

split-now)
  b1=$(pane_id beta 0 0)
  h pane split "$b1" --direction right --cwd "$WS_ROOT/beta/sub" --no-focus >/dev/null
  log "split-now issued in beta (no autosave wait)"
  ;;

probe)
  probe "$1"
  ;;

disrupt)
  mode=$1
  old_uid=$(pod_uid)
  old_restarts=$(k get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  pod_facts >"$RUN_DIR/pod-before-$mode.json"
  log "disrupt mode=$mode pod_uid=$old_uid"
  t0=$(epoch)
  case "$mode" in
  delete) k delete pod "$POD" --wait=false ;;
  grace1) k delete pod "$POD" --grace-period=1 --wait=false ;;
  force) k delete pod "$POD" --grace-period=0 --force --wait=false ;;
  kill) kx kill -KILL "$(server_pid)" ;;
  oom)
    b1=$(pane_id beta 0 0)
    h pane run "$b1" "python3 -c 'b=[]
while True: b.append(bytearray(256*1024*1024))'" >/dev/null
    ;;
  external) log "waiting for an external replacement (old uid $old_uid)" ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
  esac
  # Wait for the server to be gone, then for a replacement to be up.
  case "$mode" in
  kill | oom)
    for _ in $(seq 1 600); do
      r=$(k get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "$old_restarts")
      [ "$r" -gt "$old_restarts" ] && break
      sleep 0.5
    done
    log "container restarted (restartCount $old_restarts -> $r)"
    ;;
  *)
    for _ in $(seq 1 1200); do
      u=$(pod_uid)
      [ -n "$u" ] && [ "$u" != "$old_uid" ] && break
      sleep 0.5
    done
    log "replacement pod created uid=$(pod_uid)"
    for _ in $(seq 1 600); do
      [ "$(k get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && break
      sleep 0.5
    done
    ;;
  esac
  measure_recovery "$mode" "$t0"
  wait_ready || true
  log "pod ready"
  k get events --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,REASON:.reason,OBJ:.involvedObject.name,MSG:.message >"$RUN_DIR/events-$mode.txt" 2>&1 || true
  sleep 3
  probe "after-$mode"
  # Exported shell variables live only in the dead shell process.
  a1=$(pane_id alpha 0 0)
  # shellcheck disable=SC2016 # expanded by the pane shell
  h pane run "$a1" 'echo "ENVCHECK EXP_VAR=[$EXP_VAR] cwd=$PWD"' >/dev/null
  sleep 1
  h pane read "$a1" --lines 5 --source recent | grep '^ENVCHECK' | tee "$RUN_DIR/after-$mode/envcheck.txt" || true
  ;;

backup)
  label=$1
  mkdir -p "$RUN_DIR/backups"
  # Contains conversation transcripts and credentials: kept local only, mode 600.
  kx tar -C /home/herdr -czf - .config/herdr .claude .claude.json .codex .bash_history 2>/dev/null >"$RUN_DIR/backups/$label.tgz" || true
  chmod 600 "$RUN_DIR/backups/$label.tgz"
  kx sh -c 'cp -a ~/.config/herdr/session.json ~/.config/herdr/session.json.'"$label"'.bak'
  log "backup $label ($(du -h "$RUN_DIR/backups/$label.tgz" | cut -f1)) + in-PVC session.json.$label.bak"
  ;;

cleanup)
  kx rm -rf "$WS_ROOT"
  log "removed $WS_ROOT"
  ;;

*)
  echo "unknown command $cmd" >&2
  exit 2
  ;;
esac
