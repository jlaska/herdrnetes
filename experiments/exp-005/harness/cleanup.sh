#!/usr/bin/env bash
# EXP-005 cleanup. Usage: KCTX=<ctx> cleanup.sh <run-id> [--confirm <run-id>]
# Default is a dry-run plan. Only objects in namespace herdrnetes-exp005 labelled
# herdrnetes.io/experiment=exp-005 AND herdrnetes.io/run-id=<run-id> are deleted.
# Any unlabelled object in the namespace aborts the run (listed first). Other namespaces are never touched;
# the live Herdr pod (herdrnetes-exp/herdr-0) is only read, before and after.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

LIVE_NS=herdrnetes-exp
LIVE_POD=herdr-0
RUN=${1:-}; [ -n "$RUN" ] || die "usage: KCTX=<ctx> $0 <run-id> [--confirm <run-id>]"
shift
CONFIRM=""
if [ "${1:-}" = "--confirm" ]; then CONFIRM=${2:-}; [ "$CONFIRM" = "$RUN" ] || die "--confirm value must equal the run-id '$RUN'"; fi
require_kctx; valid_run_id "$RUN"
[ "$NS" != "$LIVE_NS" ] || die "refusing: target namespace equals live namespace"

# Namespaced kinds inventoried. kube-root-ca.crt and serviceaccount/default are system-created and skipped.
KINDS=pvc,pod,statefulset,deployment,job,cronjob,configmap,networkpolicy,service,secret,serviceaccount,role,rolebinding,ingress

live_facts() { kubectl --context "$KCTX" -n "$LIVE_NS" get pod "$LIVE_POD" \
  -o go-template='{{.metadata.uid}}{{range .status.containerStatuses}} {{.name}}={{.restartCount}}{{end}}' 2>/dev/null || echo absent; }
LIVE_BEFORE=$(live_facts)
echo "live $LIVE_NS/$LIVE_POD before: $LIVE_BEFORE (read-only)"

if ! kubectl --context "$KCTX" get ns "$NS" >/dev/null 2>&1; then echo "namespace $NS does not exist; nothing to do"; exit 0; fi
guard_ns

inventory() { # prints: kind/name <TAB> experiment <TAB> run-id
  k get "$KINDS" -o json | python3 -c '
import json, sys
for i in json.load(sys.stdin)["items"]:
    kind, name = i["kind"].lower(), i["metadata"]["name"]
    if (kind, name) in (("configmap", "kube-root-ca.crt"), ("serviceaccount", "default")): continue
    l = i["metadata"].get("labels") or {}
    print("%s/%s\t%s\t%s" % (kind, name, l.get("herdrnetes.io/experiment", ""), l.get("herdrnetes.io/run-id", "")))'
}
INV=$(inventory)
mine=() ; others=() ; bad=()
while IFS=$'\t' read -r obj exp rid; do
  [ -n "$obj" ] || continue
  if [ "$exp" != exp-005 ] || [ -z "$rid" ]; then bad+=("$obj"); 
  elif [ "$rid" = "$RUN" ]; then mine+=("$obj"); else others+=("$obj (run-id $rid)"); fi
done <<<"$INV"

if [ ${#bad[@]} -gt 0 ]; then
  echo "ABORT: objects in $NS lacking herdrnetes.io/experiment=exp-005 and a run-id label:" >&2
  printf '  %s\n' "${bad[@]}" >&2; exit 3
fi
echo "plan for run-id $RUN in namespace $NS:"
printf '  delete %s\n' "${mine[@]:-}" | grep -v '^  delete $' || echo "  (no labelled objects of this run)"
[ ${#others[@]} -eq 0 ] || { echo "  NOT touching other runs' objects:"; printf '    %s\n' "${others[@]}"; }
if [ ${#others[@]} -eq 0 ]; then echo "  then delete Namespace/$NS (if empty and labelled experiment=exp-005)"; else echo "  Namespace/$NS will be kept (other runs' objects present)"; fi

if [ -z "$CONFIRM" ]; then echo "DRY RUN only. Re-run with: --confirm $RUN"; exit 0; fi

# Delete in dependency order: statefulset first (so pods are not recreated), then the rest, PVCs last.
order() { local want=$1; for o in "${mine[@]:-}"; do [ -n "$o" ] && [[ "$o" == "$want"/* ]] && echo "$o"; done; true; }
# Kind names must match inventory()'s lowercased .kind (e.g. persistentvolumeclaim, not pvc), or that kind
# is listed in the plan but silently skipped here.
for kind in statefulset deployment job cronjob pod service networkpolicy ingress rolebinding role configmap secret serviceaccount persistentvolumeclaim; do
  while read -r o; do
    [ -n "$o" ] || continue
    kk=${o%%/*}; nn=${o#*/}
    guard "$kk" "$nn" "$RUN"                  # re-verify labels immediately before each delete
    k delete "$kk" "$nn" --wait=false
  done < <(order "$kind")
done
# wait for pods/PVCs of this run to disappear
for _ in $(seq 1 60); do
  left=$(inventory | awk -F'\t' -v r="$RUN" '$2=="exp-005" && $3==r' | wc -l)
  [ "$left" = 0 ] && break; sleep 5
done
echo "remaining objects of run $RUN: $left"

# Namespace: only when nothing at all remains and the Namespace is ours.
remaining=$(inventory | grep -c . || true)
if [ "$remaining" = 0 ] && [ "$left" = 0 ]; then
  guard_ns
  exp=$(kubectl --context "$KCTX" get ns "$NS" -o go-template="{{index .metadata.labels \"$EXP_LABEL\"}}")
  [ "$exp" = exp-005 ] || die "namespace lacks experiment label; not deleting"
  kubectl --context "$KCTX" delete namespace "$NS" --wait=false
  echo "namespace $NS deletion requested"
else
  echo "namespace $NS kept ($remaining object(s) remain)"
fi

LIVE_AFTER=$(live_facts)
echo "live $LIVE_NS/$LIVE_POD after:  $LIVE_AFTER"
if [ "$LIVE_BEFORE" = "$LIVE_AFTER" ]; then echo "live Herdr pod UNCHANGED"; else echo "WARNING: live Herdr pod facts differ" >&2; exit 4; fi
