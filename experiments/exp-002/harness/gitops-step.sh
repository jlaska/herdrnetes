#!/usr/bin/env bash
# EXP-002 scenarios D/E: change the pinned image through GitOps and measure
# Git push -> Argo CD sync -> pod replacement -> Herdr/agent recovery.
#
#   CTX=<ctx> GITOPS_DIR=<checkout> GITOPS_FILE=<path/to/statefulset.yaml> APP=<argo app> \
#     gitops-step.sh prepare|apply <run> <variant|node=NAME|node=-> <label>
#
# <variant> pins that image (D/E). node=NAME adds a pod nodeSelector for that
# node, and node=- removes it (G: relocation with Longhorn reattach, no drain).
#
# prepare: pull, edit the image line, stage it and run the repo's pre-commit
#          hooks. No commit, no pod contact.
# apply:   back up state, start the recovery watcher, make the owner-signed
#          commit (YubiKey touch within a few seconds of starting), push, and
#          measure. The operator is warned before each apply.
# The pod replacement is done by Argo CD + the StatefulSet controller only.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=experiments/exp-002/harness/lib.sh source-path=SCRIPTDIR
source "$HERE/lib.sh"
phase=$1
run_use "$2"
variant=$3 label=$4
safe_name "$label"
: "${GITOPS_DIR:?}" "${GITOPS_FILE:?}" "${APP:?}"
ARGO_NS=${ARGO_NS:-argo-system}
MARK="# EXP-002 G node relocation"
case "$variant" in
node=-) want="" ;;
node=*) want="kubernetes.io/hostname: ${variant#node=}" ;;
*)
  digest=$(cat "$HERE/../evidence/images/$variant.digest")
  want="image: ghcr.io/jlaska/herdrnetes-herdr:exp002-$variant@$digest"
  ;;
esac
out="$RUN_DIR/gitops-$label"
mkdir -p "$out"

# Fetch/push over HTTPS with the gh credential helper (per-command override) so
# only the commit signature needs a hardware-key touch, not the SSH transport.
gx() { git -C "$GITOPS_DIR" -c url.https://github.com/.insteadOf=git@github.com: \
  -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
argo() { kubectl --context "$CTX" -n "$ARGO_NS" get application "$APP" -o jsonpath="$1"; }

case "$phase" in
prepare)
  gx pull --ff-only -q
  f="$GITOPS_DIR/$GITOPS_FILE"
  case "$variant" in
  node=*)
    sed -i "/$MARK/,+1d" "$f"
    [ -n "$want" ] && sed -i "/^      automountServiceAccountToken:/a\\      nodeSelector: $MARK\n        $want" "$f"
    ;;
  *) sed -i -E "s|^( *)image: ghcr.io/jlaska/herdrnetes-herdr:[^ ]+$|\1$want|" "$f" ;;
  esac
  git -C "$GITOPS_DIR" add "$GITOPS_FILE"
  if git -C "$GITOPS_DIR" diff --cached --quiet HEAD -- "$GITOPS_FILE"; then
    echo "no change: already at $variant" >&2
    exit 1
  fi
  git -C "$GITOPS_DIR" diff --cached --stat
  (cd "$GITOPS_DIR" && pre-commit run --files "$GITOPS_FILE")
  log "gitops $label prepared ($variant staged, hooks passed)"
  ;;

apply)
  git -C "$GITOPS_DIR" diff --cached --quiet HEAD -- "$GITOPS_FILE" && { echo "nothing staged; run prepare" >&2; exit 1; }
  if [ -n "$want" ]; then
    grep -qF "$want" "$GITOPS_DIR/$GITOPS_FILE" || { echo "staged change is not $variant" >&2; exit 1; }
  else
    ! grep -qF "$MARK" "$GITOPS_DIR/$GITOPS_FILE" || { echo "nodeSelector still present" >&2; exit 1; }
  fi
  # Other automation (e.g. Renovate) pushes to the same branch; catch up first
  # so the signed commit fast-forwards instead of being rejected after the touch.
  # (fetch + merge: `pull` refuses a dirty index when pull.rebase is set).
  gx fetch -q origin
  git -C "$GITOPS_DIR" merge -q --ff-only '@{upstream}'
  check_target
  # A failed or incomplete backup exits non-zero and aborts here, before the commit.
  bash "$HERE/scenario.sh" backup "$RUN" "before-$label" || die "backup failed; not committing"
  pod_facts >"$out/pod-before.json"
  # Start the recovery measurement before the push; `external` waits for the
  # StatefulSet controller to replace the pod.
  bash "$HERE/scenario.sh" disrupt "$RUN" external "$label" >"$out/disrupt.log" 2>&1 &
  watcher=$!
  trap 'kill "$watcher" 2>/dev/null || true' ERR
  sleep 2
  log "gitops $label signing commit now (touch the key)"
  git -C "$GITOPS_DIR" commit -q -m "chore(herdrnetes-exp): EXP-002 $label -> ${variant/#node=/node }" \
    -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" \
    -m "Claude-Session: https://claude.ai/code/session_01BGokM9ERsUAB1M2ZURGbtx"
  sha=$(git -C "$GITOPS_DIR" rev-parse HEAD)
  gx push -q origin HEAD
  log "gitops $label pushed $sha -> $variant"
  t_push=$(epoch)

  # Argo CD: time until it has synced the new revision (default polling, no manual refresh).
  t_synced=""
  for _ in $(seq 1 600); do
    if [ "$(argo '{.status.sync.revision}')" = "$sha" ] && [ "$(argo '{.status.sync.status}')" = Synced ]; then
      t_synced=$(epoch)
      break
    fi
    sleep 1
  done
  log "argo synced $sha after $(echo "${t_synced:-0} - $t_push" | bc) s"
  argo '{.status.operationState.startedAt} {.status.operationState.finishedAt} {.status.operationState.phase}{"\n"}' >"$out/argo-operation.txt"

  wait "$watcher" || true
  log "pod replaced and recovery measured ($label)"
  pod_facts >"$out/pod-after.json"
  uv run --no-project python -c '
import json,sys
print(json.dumps({"variant":sys.argv[1],"commit":sys.argv[2],"argo_sync_after_push_s":round(float(sys.argv[4])-float(sys.argv[3]),1) if sys.argv[4] else None},indent=1))' \
    "$variant" "$sha" "$t_push" "$t_synced" | tee "$out/gitops.json"
  tail -20 "$out/disrupt.log"
  ;;

*)
  echo "usage: gitops-step.sh prepare|apply <run> <variant> <label>" >&2
  exit 2
  ;;
esac
