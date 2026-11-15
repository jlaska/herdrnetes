#!/usr/bin/env bash
# Start Claude Code in pane beta/0:1/1 of an EXP-001 run and seed a codeword.
#   agent-seed.sh <run> [model]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=experiments/exp-001/lib.sh source-path=SCRIPTDIR
source "$HERE/lib.sh"
exp_use "$1"
model=${2:-haiku}
log() { printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$*" | tee -a "$EXP_ROOT/evidence/timeline.log"; }

b2=$(h api snapshot | uv run --script "$HERE/compare.py" pane-id beta 0 1)
h pane run "$b2" "claude --model $model" >/dev/null

# Disposable directories trigger Claude's folder-trust dialog. Its default
# highlighted choice is "No, exit", so pick the numbered option labelled "Yes",
# answer it once, and fail fast if Claude exits back to the shell.
answered=0
for _ in $(seq 1 60); do
  screen=$(h pane read "$b2" --lines 30 --source visible 2>/dev/null || true)
  if [ "$answered" = 0 ] && grep -qi 'trust' <<<"$screen"; then
    # Claude Code 2.1.311 shows unnumbered options: "❯ No, exit" then "Yes, I trust this folder".
    if ! grep -q 'Yes, I trust this folder' <<<"$screen"; then
      echo "unexpected trust dialog:" >&2
      echo "$screen" >&2
      exit 1
    fi
    h pane send-keys "$b2" down >/dev/null
    sleep 0.5
    if ! grep -q '❯ *Yes, I trust' <<<"$(h pane read "$b2" --lines 30 --source visible)"; then
      echo "could not highlight the Yes option:" >&2
      h pane read "$b2" --lines 30 --source visible >&2
      exit 1
    fi
    h pane send-keys "$b2" enter >/dev/null
    answered=1
    log "answered folder trust prompt (Yes, I trust this folder)"
    sleep 2
    continue
  fi
  if h agent get "$b2" >/dev/null 2>&1; then
    break
  fi
  if [ "$answered" = 1 ] && tail -2 <<<"$screen" | grep -q '^\[beta\]\$'; then
    echo "claude exited after trust prompt:" >&2
    echo "$screen" >&2
    exit 1
  fi
  sleep 1
done
h agent get "$b2" >/dev/null || { h pane read "$b2" --lines 30 --source visible; exit 1; }
log "claude detected in $b2"

h agent wait "$b2" --until idle --timeout 60000 >/dev/null
h agent prompt "$b2" "For a persistence test, remember the codeword HERDR-ZEBRA-42. Reply with only: OK" \
  --wait --timeout 120000 >/dev/null
sleep 7 # let the session-ref report settle into session.json
log "agent seeded in $b2 (model=$model)"
h agent get "$b2" >"$EXP_ROOT/evidence/agent-before.json" || true
