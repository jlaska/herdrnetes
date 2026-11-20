#!/usr/bin/env bash
# EXP-005 workstation-side helpers. Source this file; do not execute it.
# Every mutating call goes through k() (context + namespace pinned) after guard().
set -euo pipefail

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST_DIR=$(cd "$HARNESS_DIR/../manifests" && pwd)

# The scratch namespace is hard-coded and compared EXACTLY. The live namespace is herdrnetes-exp.
NS=herdrnetes-exp005
EXP_LABEL=herdrnetes.io/experiment
RUN_LABEL=herdrnetes.io/run-id

die() { echo "FATAL: $*" >&2; exit 1; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

require_kctx() {
  [ -n "${KCTX:-}" ] || die "KCTX is not set (no default; pass the owner-designated kubeconfig context)"
  kubectl config get-contexts -o name | grep -Fxq -- "$KCTX" || die "context '$KCTX' does not exist in kubeconfig"
  [ "$NS" = "herdrnetes-exp005" ] || die "NS must be exactly herdrnetes-exp005 (got '$NS')"
}

valid_run_id() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid run-id '${1:-}' (lowercase alnum/dash, <=31 chars)"; }

# k: kubectl pinned to the context and scratch namespace.
k() { require_kctx; kubectl --context "$KCTX" -n "$NS" "$@"; }
# kc: cluster-scoped, read-only helper (never mutates).
kc_get() { require_kctx; kubectl --context "$KCTX" get "$@"; }

# guard <kind> <name> <run-id>: object must exist in $NS with experiment=exp-005 and run-id=<run-id>.
guard() {
  local kind=$1 name=$2 run=$3 exp rid
  require_kctx; valid_run_id "$run"
  exp=$(k get "$kind" "$name" -o go-template="{{index .metadata.labels \"$EXP_LABEL\"}}" 2>/dev/null) \
    || die "guard: $kind/$name not found in $NS"
  rid=$(k get "$kind" "$name" -o go-template="{{index .metadata.labels \"$RUN_LABEL\"}}" 2>/dev/null) || rid=""
  [ "$exp" = "exp-005" ] || die "guard: $kind/$name lacks $EXP_LABEL=exp-005 (got '$exp')"
  [ "$rid" = "$run" ] || die "guard: $kind/$name has run-id '$rid', expected '$run'"
}

# guard_ns: if the Namespace exists it must carry experiment=exp-005 (compared exactly).
guard_ns() {
  local exp
  require_kctx
  if exp=$(kubectl --context "$KCTX" get ns "$NS" -o go-template="{{index .metadata.labels \"$EXP_LABEL\"}}" 2>/dev/null); then
    [ "$exp" = "exp-005" ] || die "namespace $NS exists but lacks $EXP_LABEL=exp-005 (got '$exp'); refusing"
  fi
}

# render <manifest-basename> <run-id>: print a manifest with ${RUN_ID} substituted.
# The configmap is generated from harness/request-repo.
render() {
  local name=$1 run=$2 out
  valid_run_id "$run"
  if [ "$name" = request-repo-configmap ]; then
    out=$(python3 "$MANIFEST_DIR/gen-configmap.py" "$run")
  else
    out=$(RUN_ID="$run" envsubst "\${RUN_ID}" <"$MANIFEST_DIR/$name.yaml")
  fi
  # belt and braces: the rendered text must only name the scratch namespace
  if grep -E '^\s*namespace:' <<<"$out" | grep -vqE 'namespace: "?herdrnetes-exp005"?\s*$'; then
    die "rendered $name names a namespace other than $NS"
  fi
  printf '%s\n' "$out"
}
