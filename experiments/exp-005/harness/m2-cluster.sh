#!/usr/bin/env bash
# EXP-005 M2 driver (workstation side, kubectl only). Usage: KCTX=<context> m2-cluster.sh <run-id>
# Per-repository Longhorn PVC + independent workspace pod (tests P01-P12, hypotheses H4-H8).
# Env: KCTX (required, no default); EVIDENCE_DIR (default: scratchpad, never the repo);
#      M1_RUN (run-id label of the existing herdr-scratch StatefulSet; default = <run-id>).
# Prerequisite: M1 deployed herdr-scratch-0 (read-only here: exec + server-side DRY-RUN patches only).
# Mutations (all guarded, all in $NS): apply of repo PVC / workspace pod / probe pod / tool ConfigMap,
# graceful `kubectl delete pod|pvc` of objects THIS script created. No --force, no --grace-period=0,
# no VolumeAttachment/Longhorn/PV writes (those are only read). herdr-scratch is never modified.
# Rerun-safe: repo ids carry a per-invocation ROUND suffix.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

RUN=${1:-}; [ -n "$RUN" ] || die "usage: KCTX=<ctx> $0 <run-id>"
require_kctx; valid_run_id "$RUN"
M1_RUN=${M1_RUN:-$RUN}; valid_run_id "$M1_RUN"
EVIDENCE_DIR=${EVIDENCE_DIR:-/tmp/claude-1000/-home-jlaska-Projects-herdrnetes/4e33ac86-9385-4fe7-8dc6-2ee8820b89da/scratchpad/m2/evidence-$RUN}
mkdir -p "$EVIDENCE_DIR/raw"
ROUND=$(date -u +%H%M%S)
P="m2r${ROUND}"
A=${P}-a; B=${P}-b
CM="request-repo-$RUN"
SCRATCH=herdr-scratch-0
IMAGE=ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277
RES="$EVIDENCE_DIR/results-$ROUND.tsv"; TIM="$EVIDENCE_DIR/timings-$ROUND.tsv"
printf 'test\tstatus\tdetail\n' >"$RES"; printf 'step\tseconds\n' >"$TIM"
FAILS=0
[ ${#A} -le 40 ] || die "repo id too long"

rec() { # rec <test> <PASS|FAIL|INFO|LIMITATION> <detail>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RES"
  log "$1 $2 $3"
  [ "$2" = FAIL ] && FAILS=$((FAILS+1))
  return 0
}
check() { local t=$1 d=$2; shift 2; if "$@"; then rec "$t" PASS "$d"; else rec "$t" FAIL "$d"; fi; }
tim() { printf '%s\t%s\n' "$1" "$2" >>"$TIM"; }
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }
raw() { printf '%s/raw/%s' "$EVIDENCE_DIR" "$1"; }

jget() { python3 -c '
import json,sys
try: v=json.loads(sys.argv[1]).get(sys.argv[2])
except Exception: v=None
print("" if v is None else v)' "$1" "$2"; }

# ------------------------------------------------------------ rendering (own templates; lib.sh untouched)
affinity_json() { # affinity_json <In|NotIn> <node>   ("none" -> {})
  if [ "$1" = none ]; then echo '{}'; return; fi
  [[ "$2" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "bad node name '$2'"
  printf '{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchFields":[{"key":"metadata.name","operator":"%s","values":["%s"]}]}]}}}\n' "$1" "$2"
}
render_checked() { # reads stdin, verifies namespace, prints
  local out; out=$(cat)
  if grep -E '^\s*namespace:' <<<"$out" | grep -vqE 'namespace: "?herdrnetes-exp005"?\s*$'; then die "rendered manifest names a namespace other than $NS"; fi
  printf '%s\n' "$out"
}
render_pvc() { REPO_ID=$1 RUN_ID=$RUN envsubst '${REPO_ID} ${RUN_ID}' <"$MANIFEST_DIR/repo-pvc.yaml" | render_checked; }
render_pod() { # render_pod <pod-name> <repo-id> <component> <affinity-json>
  POD_NAME=$1 REPO_ID=$2 COMPONENT=$3 AFFINITY_JSON=$4 CM_NAME=$CM RUN_ID=$RUN \
    envsubst '${POD_NAME} ${REPO_ID} ${COMPONENT} ${AFFINITY_JSON} ${CM_NAME} ${RUN_ID}' <"$MANIFEST_DIR/workspace-pod.yaml" | render_checked
}
valid_repo_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || die "invalid repo id '$1' (lowercase alnum/dash)"; }

# ------------------------------------------------------------ small kubectl helpers
pxw() { local id=$1; shift; k exec -i "ws-$id" -c ws -- bash -s -- "$id" "$@"; }
pod_phase() { k get pod "$1" -o go-template='{{.status.phase}}' 2>/dev/null || echo absent; }
pod_ready() { [ "$(k get pod "$1" -o go-template='{{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}' 2>/dev/null)" = True ]; }
wait_pod_ready() { local end=$((SECONDS+$2)); while [ $SECONDS -lt $end ]; do pod_ready "$1" && return 0; sleep 1; done; return 1; }
pod_uid() { k get pod "$1" -o go-template='{{.metadata.uid}}'; }
pod_facts() { k get pod "$1" -o go-template='{{.metadata.uid}} {{(index .status.containerStatuses 0).restartCount}} {{.spec.nodeName}}'; }
pod_node() { k get pod "$1" -o go-template='{{.spec.nodeName}}'; }
pvc_pv() { k get pvc "$1" -o go-template='{{.spec.volumeName}}'; }
pod_events() { k get events --field-selector "involvedObject.name=$1" --sort-by=.metadata.creationTimestamp 2>&1 || true; }
# conditions of a pod as "Type=transition-time" lines, plus seconds Scheduled->Ready
cond_times() {
  k get pod "$1" -o json | python3 -c '
import json, sys, datetime as d
c = {x["type"]: x["lastTransitionTime"] for x in json.load(sys.stdin)["status"]["conditions"]}
t = lambda s: d.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
for n, v in c.items(): print("%s=%s" % (n, v))
if "PodScheduled" in c and "Ready" in c: print("scheduled_to_ready_s=%d" % (t(c["Ready"]) - t(c["PodScheduled"])).total_seconds())'
}
# VolumeAttachments for a PV (read-only): lines "<node>:<attached true/false>"
va_nodes() {
  kc_get volumeattachments -o json | python3 -c '
import json, sys
for v in json.load(sys.stdin)["items"]:
    if v["spec"]["source"].get("persistentVolumeName") == sys.argv[1]:
        print("%s:%s" % (v["spec"]["nodeName"], str(v.get("status", {}).get("attached", False)).lower()))' "$1"
}
va_snapshot() { { echo "# $(date -u +%FT%TZ) VolumeAttachments for $1"; va_nodes "$1"; } >>"$(raw "$2")"; }

# kdry: server-side DRY-RUN patch against herdr-scratch; refuses to run without --dry-run=server.
kdry() { # kdry <patch args...>; prints combined output, returns kubectl rc
  local a ok=0; for a in "$@"; do [ "$a" = --dry-run=server ] && ok=1; done
  [ $ok = 1 ] || die "kdry without --dry-run=server"
  k patch pod "$SCRATCH" "$@" 2>&1
}

# ------------------------------------------------------------ preflight
guard_ns
k get statefulset herdr-scratch >/dev/null 2>&1 || die "herdr-scratch StatefulSet not found in $NS (run M1 first)"
guard statefulset herdr-scratch "$M1_RUN"
guard pod "$SCRATCH" "$M1_RUN"

herdr_pid() {
  k exec -i "$SCRATCH" -c herdr -- bash -s <<'EOS'
for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || continue
  case "$c" in "/usr/local/bin/herdr server"*) echo "${p#/proc/}"; exit 0;; esac
done
echo none
EOS
}
read -r SUID0 SRC0 SNODE0 <<<"$(pod_facts "$SCRATCH")"; SPID0=$(herdr_pid)
rec P10-baseline INFO "herdr-scratch-0 uid=$SUID0 restartCount=$SRC0 node=$SNODE0 herdr_pid=$SPID0"
check P10-baseline-pid "real herdr server process found (pid=$SPID0)" test "$SPID0" != none
p10_point() { # p10_point <label>
  local u r n p; read -r u r n <<<"$(pod_facts "$SCRATCH")"; p=$(herdr_pid)
  check "P10-$1" "uid $SUID0->$u restartCount $SRC0->$r node $SNODE0->$n herdr_pid $SPID0->$p" \
    test "$u" = "$SUID0" -a "$r" = "$SRC0" -a "$p" = "$SPID0"
}

# ------------------------------------------------------------ tool ConfigMap (own copy; survives M1 cleanup edits)
python3 "$MANIFEST_DIR/gen-configmap.py" "$RUN" "$CM" | render_checked | k apply -f - >/dev/null
guard configmap "$CM" "$RUN"

# ------------------------------------------------------------ request_repo_pvc
declare -A PV NODE
# request_repo_pvc <id>: PVC -> Bound -> ws pod -> Ready -> synthetic source -> request-repo.
# Sets PV[id], NODE[id], PVC_WAS_ABSENT, T_BOUND, T_READY, RR_OUT, RR_RC. Idempotent.
request_repo_pvc() {
  local id=$1 t0
  valid_repo_id "$id"
  PVC_WAS_ABSENT=0
  if k get pvc "repo-$id" >/dev/null 2>&1; then
    guard pvc "repo-$id" "$RUN"; T_BOUND=0
  else
    PVC_WAS_ABSENT=1
    t0=$(now)
    render_pvc "$id" | k apply -f - >/dev/null
    guard pvc "repo-$id" "$RUN"
    local end=$((SECONDS+120))
    until [ "$(k get pvc "repo-$id" -o go-template='{{.status.phase}}')" = Bound ]; do
      [ $SECONDS -lt "$end" ] || { k describe pvc "repo-$id" >"$(raw "pvc-$id-notbound.txt")" 2>&1 || true; die "PVC repo-$id not Bound in 120s"; }
      sleep 0.5
    done
    T_BOUND=$(since "$t0")
  fi
  PV[$id]=$(pvc_pv "repo-$id")
  k get pvc "repo-$id" -o yaml >"$(raw "pvc-$id.yaml")"
  if k get pod "ws-$id" >/dev/null 2>&1; then
    guard pod "ws-$id" "$RUN"
  else
    t0=$(now)
    render_pod "ws-$id" "$id" workspace "$(affinity_json none x)" | k apply -f - >/dev/null
    guard pod "ws-$id" "$RUN"
  fi
  t0=${t0:-$(now)}
  wait_pod_ready "ws-$id" 300 || { pod_events "ws-$id" >"$(raw "ws-$id-notready.txt")"; die "pod ws-$id not Ready in 300s (see raw/ws-$id-notready.txt)"; }
  T_READY=$(since "$t0")
  NODE[$id]=$(pod_node "ws-$id")
  pod_events "ws-$id" >"$(raw "ws-$id-events.txt")"
  cond_times "ws-$id" >"$(raw "ws-$id-conditions.txt")"
  va_snapshot "${PV[$id]}" "va-$id.txt"
  # synthetic bare source in the ws pod's /tmp (deterministic dates => identical commit if recreated)
  mk_source "$id"
  rr "$id"
}
mk_source() { pxw "$1" <<'EOS'
set -eu
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
s=/tmp/src/$1.git
[ -d "$s" ] && exit 0
mkdir -p /tmp/src; w=$(mktemp -d /tmp/src/w.XXXXXX)
git init -q -b main "$w"; echo "repo $1" >"$w/README"; seq 1 200 >"$w/data.txt"
git -C "$w" add .; git -C "$w" commit -q -m "init $1"
git clone -q --bare "$w" "$s"; rm -rf "$w"
EOS
}
rr() { # rr <id>: run the M1 tool unchanged inside ws-<id>
  RR_RC=0
  RR_OUT=$(k exec "ws-$1" -c ws -- python3 /opt/exp005/bin/request-repo "$1" "/tmp/src/$1.git" 2>>"$(raw "rr-$1.err")") || RR_RC=$?
  printf '%s\n' "$RR_OUT" >>"$(raw "rr-$1.json")"
}
src_head() { pxw "$1" <<'EOS'
git --git-dir=/tmp/src/$1.git rev-parse HEAD
EOS
}
fsck_repo() { pxw "$1" <<'EOS'
git -C /workspace/$1 fsck --strict
EOS
}
mount_line() { pxw "$1" <<'EOS'
awk '$5=="/workspace" { fs="?"; src="?"; for(i=7;i<=NF;i++) if($i=="-") { fs=$(i+1); src=$(i+2) } print "majmin=" $3, "fstype=" fs, "source=" src }' /proc/self/mountinfo
EOS
}
dirty() { pxw "$1" <<'EOS'
set -eu
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
cd /workspace/$1
echo dirty >>README; echo untracked >untracked.txt; echo local >>data.txt
git commit -qam "local commit"; echo stash >>data.txt; git stash -q
echo dirty2 >>README; echo staged >staged.txt; git add staged.txt
EOS
}
snap() { pxw "$1" <<'EOS'
export GIT_OPTIONAL_LOCKS=0; cd /workspace/$1
stat -c 'index_mtime=%.9Y' .git/index; sha256sum .git/index README data.txt untracked.txt staged.txt
git status --porcelain=v2 --branch; git rev-parse HEAD; git stash list; git for-each-ref
EOS
}

# ============================================================ P01-P05 repo A
if k get pvc "repo-$A" >/dev/null 2>&1; then rec P01 FAIL "PVC repo-$A already exists"; else rec P01 PASS "PVC repo-$A absent before request"; fi
request_repo_pvc "$A"
tim "P03-pvc-create-to-bound" "$T_BOUND"; tim "P04-create-to-ws-ready" "$T_READY"
check P02 "PVC repo-$A created (storageClass=longhorn, 1Gi, RWO) pv=${PV[$A]}" \
  test "$PVC_WAS_ABSENT" = 1 -a "$(k get pvc "repo-$A" -o go-template='{{.spec.storageClassName}} {{.status.capacity.storage}} {{index .status.accessModes 0}}')" = "longhorn 1Gi ReadWriteOnce"
check P03 "Bound in ${T_BOUND}s (Immediate binding) pv=${PV[$A]}" test -n "${PV[$A]}" -a "$PVC_WAS_ABSENT" = 1
ml=$(mount_line "$A"); printf '%s\n' "$ml" >"$(raw mountinfo-ws-$A.txt)"
if grep -qE "fstype=ext4" <<<"$ml" && grep -qiE "longhorn|${PV[$A]}" <<<"$ml"; then rec P04 PASS "ws-$A Ready in ${T_READY}s on ${NODE[$A]}; /workspace: $ml"
elif grep -q "fstype=ext4" <<<"$ml"; then rec P04 INFO "ws-$A Ready in ${T_READY}s on ${NODE[$A]}; /workspace is ext4 but device name not longhorn-labelled: $ml"
else rec P04 FAIL "ws-$A /workspace mount not ext4 block device: $ml"; fi
rec P04-timing INFO "$(tr '\n' ' ' <"$(raw ws-$A-conditions.txt)")"
sh_a=$(src_head "$A")
fsck_ok=0; fsck_repo "$A" >"$(raw p05-fsck.txt)" 2>&1 && fsck_ok=1
check P05 "request-repo rc=$RR_RC action=$(jget "$RR_OUT" action) head=$(jget "$RR_OUT" head) fsck_clean=$fsck_ok path=$(jget "$RR_OUT" path)" \
  test "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = hydrated -a "$(jget "$RR_OUT" head)" = "$sh_a" -a "$fsck_ok" = 1 -a "$(jget "$RR_OUT" path)" = "/workspace/$A"

# ============================================================ P07 prep (dirty state BEFORE the move)
dirty "$A"; pre7=$(snap "$A"); [ -n "$pre7" ] || die "empty pre-move snapshot"
read -r WUID_A0 WRC_A0 _ <<<"$(pod_facts "ws-$A")"

# ============================================================ P06 cross-node move
guard pod "ws-$A" "$RUN"
OLDN=${NODE[$A]}; PVA=${PV[$A]}
va_snapshot "$PVA" va-p06.txt
t0=$(now)
k delete pod "ws-$A" --wait=true --timeout=180s >"$(raw p06-delete.txt)" 2>&1
t_del=$(since "$t0")
va_snapshot "$PVA" va-p06.txt
render_pod "ws-$A" "$A" workspace "$(affinity_json NotIn "$OLDN")" | k apply -f - >/dev/null
guard pod "ws-$A" "$RUN"
t_old_gone=""; t_new_att=""
end=$((SECONDS+420)); moved=0
while [ $SECONDS -lt $end ]; do
  vas=$(va_nodes "$PVA" || true); echo "$(since "$t0") ${vas//$'\n'/ }" >>"$(raw va-p06-timeline.txt)"
  grep -q "^$OLDN:" <<<"$vas" || [ -n "$t_old_gone" ] || t_old_gone=$(since "$t0")
  grep -qE ":true$" <<<"$vas" && ! grep -q "^$OLDN:" <<<"$vas" && [ -z "$t_new_att" ] && t_new_att=$(since "$t0")
  if pod_ready "ws-$A"; then moved=1; break; fi
  sleep 1
done
t_ready=$(since "$t0")
pod_events "ws-$A" >"$(raw ws-$A-events-after-move.txt)"; cond_times "ws-$A" >"$(raw ws-$A-conditions-after-move.txt)"
va_snapshot "$PVA" va-p06.txt
[ $moved = 1 ] || die "ws-$A not Ready within 420s after move (see raw/ws-$A-events-after-move.txt); volume left as-is, no force actions taken"
NEWN=$(pod_node "ws-$A"); NODE[$A]=$NEWN
tim "P06-pod-delete" "$t_del"; tim "P06-va-old-node-gone" "${t_old_gone:-NA}"; tim "P06-va-new-node-attached" "${t_new_att:-NA}"; tim "P06-delete-to-new-pod-ready" "$t_ready"
mk_source "$A"   # /tmp is fresh in the new pod; deterministic source
rr "$A"
fsck_ok=0; fsck_repo "$A" >"$(raw p06-fsck.txt)" 2>&1 && fsck_ok=1
post7=$(snap "$A"); printf '%s\n--\n%s\n' "$pre7" "$post7" >"$(raw p07-before-after.txt)"
read -r WUID_A1 _ _ <<<"$(pod_facts "ws-$A")"
check P06 "ws-$A moved $OLDN -> $NEWN (new uid $WUID_A0 -> $WUID_A1); delete ${t_del}s; VA old-node-gone=${t_old_gone:-NA}s new-attached=${t_new_att:-NA}s; delete->Ready ${t_ready}s; fsck_clean=$fsck_ok; request-repo action=$(jget "$RR_OUT" action)" \
  test "$NEWN" != "$OLDN" -a "$WUID_A0" != "$WUID_A1" -a "$fsck_ok" = 1 -a "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = already_ready
check P07 "dirty/untracked/staged/local commit/stash snapshot identical across cross-node move (index mtime included)" \
  test "$pre7" = "$post7"
p10_point after-P06

# ============================================================ P08 second repo
request_repo_pvc "$B"
tim "P08-pvc-create-to-bound" "$T_BOUND"; tim "P08-create-to-ws-ready" "$T_READY"
a_sees_b=0; pxw "$A" "$B" <<'EOS' >/dev/null 2>&1 && a_sees_b=1 || true
[ -e "/workspace/$2" ]
EOS
fsck_ok=0; fsck_repo "$B" >"$(raw p08-fsck.txt)" 2>&1 && fsck_ok=1
check P08 "repo-$B pv=${PV[$B]} node=${NODE[$B]} (A pv=${PV[$A]} node=${NODE[$A]}); separate PVC+PV=$([ "${PV[$A]}" != "${PV[$B]}" ] && echo yes || echo no); B fsck=$fsck_ok rr_rc=$RR_RC; ws-$A sees /workspace/$B: $a_sees_b (want 0)" \
  test -n "${PV[$B]}" -a "${PV[$A]}" != "${PV[$B]}" -a "$fsck_ok" = 1 -a "$RR_RC" = 0 -a "$a_sees_b" = 0

# ============================================================ P11 accessibility from the (unchanged) Herdr pod
k exec -i "$SCRATCH" -c herdr -- cat /proc/self/mountinfo >"$(raw mountinfo-herdr-scratch.txt)" 2>&1 || true
absent=0; k exec "$SCRATCH" -c herdr -- test ! -e "/workspace/$A" && absent=1
in_mi=$(grep -cE "${PV[$A]}|repo-$A|/$A( |$)" "$(raw mountinfo-herdr-scratch.txt)" || true)
check P11a "herdr-scratch-0: /workspace/$A absent=$absent; mountinfo lines naming PV ${PV[$A]} / repo-$A: $in_mi (want absent=1, 0 lines)" \
  test "$absent" = 1 -a "$in_mi" = 0
patch_vol=$(printf '[{"op":"add","path":"/spec/volumes/-","value":{"name":"repo-%s","persistentVolumeClaim":{"claimName":"repo-%s"}}},{"op":"add","path":"/spec/containers/0/volumeMounts/-","value":{"name":"repo-%s","mountPath":"/workspace/%s"}}]' "$A" "$A" "$A" "$A")
rc=0; out=$(kdry --dry-run=server --type=json -p "$patch_vol") || rc=$?
printf '%s\n' "$out" >"$(raw p11b-volume-patch.txt)"
# PASS only on the API server's pod-update immutability error, not on any client/flag error.
if [ "$rc" != 0 ] && grep -q 'pod updates may not change fields' <<<"$out"; then
  rec P11b PASS "volume+mount patch on running pod REJECTED by immutability rule (H4 holds), dry-run rc=$rc: $(tr '\n' ' ' <<<"$out" | cut -c1-400)"
elif [ "$rc" != 0 ]; then rec P11b FAIL "patch failed for an UNEXPECTED reason (inconclusive): $(tr '\n' ' ' <<<"$out" | cut -c1-400)"
else rec P11b FAIL "API ACCEPTED (dry-run) a volume patch on the running pod: $out"; fi
eph() { # eph <volume-name> <mountPath> <ctr-name>
  printf '{"spec":{"ephemeralContainers":[{"name":"%s","image":"%s","command":["sleep","1"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":1000,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}},"volumeMounts":[{"name":"%s","mountPath":"%s"}]}]}}' "$3" "$IMAGE" "$1" "$2"
}
# P11d first: the identical request mounting an EXISTING volume is the syntax control for P11c.
rcd=0; outd=$(kdry --subresource=ephemeralcontainers --dry-run=server --type=strategic -p "$(eph workspace /mnt/ws dbg-ws)") || rcd=$?
printf '%s\n' "$outd" >"$(raw p11d-ephemeral-existing.txt)"
rec P11d INFO "control: ephemeral container mounting EXISTING volume 'workspace' (dry-run) rc=$rcd: $(tr '\n' ' ' <<<"$outd" | cut -c1-300)"
rc=0; out=$(kdry --subresource=ephemeralcontainers --dry-run=server --type=strategic -p "$(eph "repo-$A" /mnt/repo dbg-repo)") || rc=$?
printf '%s\n' "$out" >"$(raw p11c-ephemeral-newclaim.txt)"
if [ "$rc" != 0 ] && [ "$rcd" = 0 ] && grep -qiE 'volumeMounts.*(not found|Not found)' <<<"$out"; then
  rec P11c PASS "ephemeral container mounting not-in-spec volume repo-$A REJECTED (control accepted), rc=$rc: $(tr '\n' ' ' <<<"$out" | cut -c1-400)"
elif [ "$rc" = 0 ]; then rec P11c FAIL "API ACCEPTED (dry-run) an ephemeral container mounting repo-$A: $out"
else rec P11c FAIL "inconclusive: rc=$rc control_rc=$rcd (syntax or unexpected error): $(tr '\n' ' ' <<<"$out" | cut -c1-400)"; fi
# confirm herdr-scratch spec truly unchanged by the dry-runs
nvol=$(k get pod "$SCRATCH" -o jsonpath='volumes={.spec.volumes[*].name} eph={.spec.ephemeralContainers[*].name}')
rec P11-spec-unchanged INFO "herdr-scratch-0 volumes/ephemeral after dry-runs: $nvol"
rec P11-conclusion INFO "H6: repo-$A is mounted only in ws-$A; Herdr pod has no path to it. Kubernetes provisioning/mounting a PVC elsewhere is not Herdr access."
p10_point after-P11

# ============================================================ P12 RWO attachment constraints
PVA=${PV[$A]}; NA=${NODE[$A]}
LOCK="/workspace/.herdr-repos/locks/$A.lock"
# (a) same node
PS="probe-$A-same"
guard pod "ws-$A" "$RUN"
render_pod "$PS" "$A" probe "$(affinity_json In "$NA")" | k apply -f - >/dev/null
guard pod "$PS" "$RUN"
if wait_pod_ready "$PS" 180; then
  va_snapshot "$PVA" va-p12a.txt; pod_events "$PS" >"$(raw "$PS-events.txt")"
  held=0; ( k exec "ws-$A" -c ws -- flock "$LOCK" sleep 20 >/dev/null 2>"$(raw p12a-holder.err)" ) &
  holder=$!
  for _ in $(seq 1 20); do
    rcx=0; k exec "ws-$A" -c ws -- flock -n -E 75 "$LOCK" true >/dev/null 2>&1 || rcx=$?
    [ "$rcx" = 75 ] && { held=1; break; }; sleep 1
  done
  rc_blocked=0; k exec "$PS" -c ws -- flock -n -E 75 "$LOCK" true >/dev/null 2>&1 || rc_blocked=$?
  wait "$holder" || true
  rc_free=0; k exec "$PS" -c ws -- flock -n -E 75 "$LOCK" true >/dev/null 2>&1 || rc_free=$?
  same_node=$(pod_node "$PS")
  check P12a "probe pod on same node ($same_node vs $NA) Running/Ready; both mount repo-$A; cross-pod flock: holder_ready=$held probe_while_held rc=$rc_blocked (want 75) probe_after_release rc=$rc_free (want 0)" \
    test "$same_node" = "$NA" -a "$held" = 1 -a "$rc_blocked" = 75 -a "$rc_free" = 0
else
  pod_events "$PS" >"$(raw "$PS-events.txt")"
  rec P12a FAIL "same-node probe $PS not Ready in 180s (phase $(pod_phase "$PS")); see raw/$PS-events.txt"
fi
guard pod "$PS" "$RUN"; k delete pod "$PS" --wait=true --timeout=120s >"$(raw "$PS-delete.txt")" 2>&1 || rec P12a-cleanup FAIL "delete of $PS did not complete in 120s; NOT forcing"

# (b) different node, expect Multi-Attach
PD="probe-$A-diff"
render_pod "$PD" "$A" probe "$(affinity_json NotIn "$NA")" | k apply -f - >/dev/null
guard pod "$PD" "$RUN"
t0=$(now); became_ready=0
: >"$(raw p12b-timeline.txt)"
while [ "$(since "$t0" | cut -d. -f1)" -lt 120 ]; do
  ph=$(pod_phase "$PD"); wr=$(k get pod "$PD" -o go-template='{{range .status.containerStatuses}}{{.state}}{{end}}' 2>/dev/null || true)
  echo "$(since "$t0")s phase=$ph node=$(pod_node "$PD") state=$wr va=$(va_nodes "$PVA" | tr '\n' ' ')" >>"$(raw p12b-timeline.txt)"
  if pod_ready "$PD"; then became_ready=1; break; fi
  sleep 5
done
pod_events "$PD" >"$(raw "$PD-events.txt")"; va_snapshot "$PVA" va-p12b.txt
diffnode=$(pod_node "$PD"); ph=$(pod_phase "$PD")
ma=$(grep -cE "Multi-Attach|FailedAttachVolume" "$(raw "$PD-events.txt")" || true)
if [ $became_ready = 1 ]; then
  rec P12b FAIL "probe on different node ($diffnode vs $NA) became Ready: RWO NOT enforced as expected (H7 falsified); see raw/$PD-events.txt"
else
  check P12b "probe on different node ($diffnode vs $NA) NOT Ready after 120s: phase=$ph; Multi-Attach/FailedAttach events=$ma; VolumeAttachments: $(va_nodes "$PVA" | tr '\n' ' ')" \
    test "$ma" -ge 1 -a "$ph" != Running
fi
guard pod "$PD" "$RUN"
k delete pod "$PD" --wait=true --timeout=180s >"$(raw "$PD-delete.txt")" 2>&1 || rec P12b-cleanup FAIL "delete of $PD did not complete in 180s; NOT forcing, inspect manually"
# ws-A must be undisturbed
read -r WUID_A2 WRC_A2 WNODE_A2 <<<"$(pod_facts "ws-$A")"
fsck_ok=0; fsck_repo "$A" >"$(raw p12-fsck.txt)" 2>&1 && fsck_ok=1
post12=$(snap "$A"); ready_a=no; pod_ready "ws-$A" && ready_a=yes
check P12-after "ws-$A uid $WUID_A1->$WUID_A2 restartCount=$WRC_A2 node=$WNODE_A2 Ready=$ready_a; repo fsck=$fsck_ok; dirty snapshot unchanged; VAs: $(va_nodes "$PVA" | tr '\n' ' ')" \
  test "$WUID_A1" = "$WUID_A2" -a "$WRC_A2" = 0 -a "$fsck_ok" = 1 -a "$post12" = "$post7" -a "$ready_a" = yes
p10_point after-P12

# ============================================================ P09 delete repo B pod+PVC; A and Herdr unaffected (H8)
guard pod "ws-$B" "$RUN"; guard pvc "repo-$B" "$RUN"
PVB=${PV[$B]}
k get pv "$PVB" -o yaml >"$(raw "pv-$PVB-before.yaml")" 2>&1 || true
RECLAIM=$(kc_get pv "$PVB" -o go-template='{{.spec.persistentVolumeReclaimPolicy}}' 2>/dev/null || echo unknown)
t0=$(now)
k delete pod "ws-$B" --wait=true --timeout=180s >"$(raw p09-delete-pod.txt)" 2>&1
k delete pvc "repo-$B" --wait=true --timeout=180s >"$(raw p09-delete-pvc.txt)" 2>&1 || rec P09-pvc-delete FAIL "PVC repo-$B deletion did not finish in 180s"
pv_state=""; end=$((SECONDS+180))
while [ $SECONDS -lt $end ]; do
  pv_state=$(kc_get pv "$PVB" -o go-template='{{.status.phase}}' 2>/dev/null) || { pv_state=GONE; break; }
  sleep 3
done
tim "P09-delete-to-pv-state-($pv_state)" "$(since "$t0")"
kc_get pv "$PVB" -o yaml >"$(raw "pv-$PVB-after.yaml")" 2>&1 || true
va_leftover=$(va_nodes "$PVB" | tr '\n' ' ')
read -r WUID_A3 WRC_A3 _ <<<"$(pod_facts "ws-$A")"
fsck_ok=0; fsck_repo "$A" >"$(raw p09-fsck-A.txt)" 2>&1 && fsck_ok=1
if [ "$RECLAIM" = Delete ]; then want="GONE (reclaim Delete)"; else want="Released (reclaim $RECLAIM)"; fi
okpv=0; { [ "$RECLAIM" = Delete ] && [ "$pv_state" = GONE ]; } || { [ "$RECLAIM" != Delete ] && [ "$pv_state" = Released ]; } && okpv=1
check P09 "repo B pod+PVC deleted; PV $PVB state=$pv_state (want $want) leftover VAs: ${va_leftover:-none}; ws-$A uid unchanged=$([ "$WUID_A3" = "$WUID_A1" ] && echo yes || echo no) restarts=$WRC_A3 fsck=$fsck_ok" \
  test "$okpv" = 1 -a "$WUID_A3" = "$WUID_A1" -a "$WRC_A3" = 0 -a "$fsck_ok" = 1
rec P09-H8 INFO "H8 partial: deleting repo-$B (its only consumer ws-$B removed first) left ws-$A and herdr-scratch-0 untouched. A truly UNAVAILABLE volume under a running consumer was not induced (no Longhorn/node fault injection)."

# ============================================================ wrap up
p10_point final
k get pods,pvc,configmap -o wide >"$(raw final-objects.txt)" 2>&1 || true
k get events --sort-by=.lastTimestamp >"$(raw events.txt)" 2>&1 || true
kc_get pv -o wide >"$(raw pv-list.txt)" 2>&1 || true
python3 - "$RES" "$TIM" "$EVIDENCE_DIR/summary-$ROUND.json" "$RUN" "$FAILS" <<'PY'
import csv, json, sys
res = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
tim = list(csv.DictReader(open(sys.argv[2]), delimiter="\t"))
json.dump({"run_id": sys.argv[4], "failures": int(sys.argv[5]), "results": res, "timings": tim},
          open(sys.argv[3], "w"), indent=1)
PY
echo "M2 complete: $FAILS failed check(s). Evidence: $EVIDENCE_DIR (results-$ROUND.tsv). ws-$A and PVC repo-$A remain; run cleanup.sh $RUN when done."
[ "$FAILS" = 0 ]
