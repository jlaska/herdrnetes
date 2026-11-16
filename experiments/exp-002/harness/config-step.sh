#!/usr/bin/env bash
# EXP-002 scenario F: change the Herdr ConfigMap through GitOps and measure
# Git push -> Argo CD sync -> file visible in the pod -> Herdr picks it up.
#
#   CTX=<ctx> GITOPS_DIR=<checkout> GITOPS_CONFIG=<path/to/config.toml> APP=<argo app> \
#     config-step.sh prepare|apply <run> <true|false> <label>
#
# The change is `[experimental] pane_history = <value>`. The ConfigMap has no
# name hash and no reloader, so no pod restart is expected; that is measured.
# prepare: fetch/fast-forward, edit, stage, run the repo's pre-commit hooks.
# apply:   owner-signed commit (YubiKey touch), push, then observe. The only pod
#          contact after the push is read-only, plus one `herdr server
#          reload-config` once the new file is visible.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=experiments/exp-002/harness/lib.sh source-path=SCRIPTDIR
source "$HERE/lib.sh"
phase=$1
run_use "$2"
value=$3 label=$4
safe_name "$label"
: "${GITOPS_DIR:?}" "${GITOPS_CONFIG:?}" "${APP:?}"
ARGO_NS=${ARGO_NS:-argo-system}
out="$RUN_DIR/config-$label"
mkdir -p "$out"

gx() { git -C "$GITOPS_DIR" -c url.https://github.com/.insteadOf=git@github.com: \
  -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
argo() { kubectl --context "$CTX" -n "$ARGO_NS" get application "$APP" -o jsonpath="$1"; }
catch_up() { gx fetch -q origin && git -C "$GITOPS_DIR" merge -q --ff-only '@{upstream}'; }
server_log_since() { # server log lines at or after an ISO timestamp
  kx cat /home/herdr/.config/herdr/herdr-server.log | awk -v t="$1" '$1 >= t' | cut -c1-240
}

case "$phase" in
prepare)
  catch_up
  sed -i -E "s|^pane_history = .*$|pane_history = $value|" "$GITOPS_DIR/$GITOPS_CONFIG"
  git -C "$GITOPS_DIR" add "$GITOPS_CONFIG"
  if git -C "$GITOPS_DIR" diff --cached --quiet HEAD -- "$GITOPS_CONFIG"; then
    echo "no change: pane_history already $value" >&2
    exit 1
  fi
  git -C "$GITOPS_DIR" diff --cached -- "$GITOPS_CONFIG"
  (cd "$GITOPS_DIR" && pre-commit run --files "$GITOPS_CONFIG")
  log "config $label prepared (pane_history = $value staged, hooks passed)"
  ;;

apply)
  git -C "$GITOPS_DIR" diff --cached --quiet HEAD -- "$GITOPS_CONFIG" && { echo "nothing staged; run prepare" >&2; exit 1; }
  grep -q "^pane_history = $value$" "$GITOPS_DIR/$GITOPS_CONFIG" || { echo "staged value is not $value" >&2; exit 1; }
  catch_up
  check_target
  pod_facts >"$out/pod-before.json"
  pid_before=$(server_pid)
  kx cat /etc/herdr/config.toml >"$out/config-before.toml"
  log "config $label signing commit now (touch the key)"
  git -C "$GITOPS_DIR" commit -q -m "chore(herdrnetes-exp): EXP-002 $label pane_history=$value" \
    -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" \
    -m "Claude-Session: https://claude.ai/code/session_01BGokM9ERsUAB1M2ZURGbtx"
  sha=$(git -C "$GITOPS_DIR" rev-parse HEAD)
  gx push -q origin HEAD
  t_push=$(epoch) iso_push=$(now)
  log "config $label pushed $sha"

  # Argo CD sync (default polling) and kubelet projection of the ConfigMap volume.
  t_synced="" t_visible=""
  for _ in $(seq 1 900); do
    if [ -z "$t_synced" ] && [ "$(argo '{.status.sync.revision}')" = "$sha" ] &&
      [ "$(argo '{.status.sync.status}')" = Synced ]; then
      t_synced=$(epoch)
      log "argo synced $sha"
    fi
    if [ -n "$t_synced" ] && kx grep -qx "pane_history = $value" /etc/herdr/config.toml 2>/dev/null; then
      t_visible=$(epoch)
      log "config $label visible in pod"
      break
    fi
    sleep 1
  done
  kx ls -la --time-style=full-iso /etc/herdr/ >"$out/configmap-dir.txt"
  kx cat /etc/herdr/config.toml >"$out/config-after.toml"

  # Does the running server notice without being told? Give it 30 s.
  sleep 30
  server_log_since "$iso_push" >"$out/server-log-before-reload.txt"
  log "config $label server log lines since push before reload: $(wc -l <"$out/server-log-before-reload.txt")"

  iso_reload=$(now)
  h config check >"$out/config-check.txt" 2>&1 || true
  h server reload-config >"$out/reload-config.txt" 2>&1 || echo "exit=$?" >>"$out/reload-config.txt"
  sleep 2
  server_log_since "$iso_reload" >"$out/server-log-after-reload.txt"
  log "config $label reload-config: $(tr '\n' ' ' <"$out/reload-config.txt" | cut -c1-160)"

  pod_facts >"$out/pod-after.json"
  pid_after=$(server_pid)
  uv run --no-project python -c '
import json,sys
v,sha,tp,ts,tv,pb,pa,fb,fa=sys.argv[1:]
b,a=json.load(open(fb)),json.load(open(fa))
d=lambda x:round(float(x)-float(tp),1) if x else None
print(json.dumps({"pane_history":v,"commit":sha,"argo_sync_after_push_s":d(ts),"visible_in_pod_after_push_s":d(tv),
 "visible_after_sync_s":round(float(tv)-float(ts),1) if ts and tv else None,
 "same_pod":b["uid"]==a["uid"],"restart_count":[b["restartCount"],a["restartCount"]],"same_server_pid":pb==pa},indent=1))' \
    "$value" "$sha" "$t_push" "$t_synced" "$t_visible" "$pid_before" "$pid_after" "$out/pod-before.json" "$out/pod-after.json" |
    tee "$out/config.json"
  ;;

*)
  echo "usage: config-step.sh prepare|apply <run> <true|false> <label>" >&2
  exit 2
  ;;
esac
