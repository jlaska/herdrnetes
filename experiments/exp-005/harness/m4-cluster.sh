#!/usr/bin/env bash
# EXP-005 M4 driver (workstation side, kubectl only). Usage: KCTX=<context> m4-cluster.sh <run-id>
# Targeted failure/recovery tests F01-F06 (hypotheses H2, H7, H8; REQ links in README):
#   F06 linked worktrees (before F02 so the restart covers them), F01 mid-clone SIGKILL,
#   F03 cross-pod concurrent hydration on one RWO PVC (same node), F04 PVC deletion under running consumers,
#   F05 missing-PVC isolation, F02 container crash (SIGKILL of the herdr server) during hydration.
# Env: KCTX (required, no default); EVIDENCE_DIR (default: scratchpad, never the repo);
#      M1_RUN (run-id label of herdr-scratch; default m1-20261118a); F01_MAX_MB (default 200).
# Mutations (all guarded, all in $NS): apply of the tool ConfigMap / F03 PVC / pods this script creates;
#   `kubectl exec` in herdr-scratch-0 (creates/removes only m4r*-prefixed repos and /tmp sources; adds worktrees to
#   one M1 repo); SIGKILL of the herdr server inside herdr-scratch-0 (F02); graceful `kubectl delete` of PVC/pods
#   THIS script created. No --force, no --grace-period=0, no VolumeAttachment/Longhorn/PV writes (read only).
#   M2 objects and the live herdrnetes-exp namespace are only READ.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

RUN=${1:-}; [ -n "$RUN" ] || die "usage: KCTX=<ctx> $0 <run-id>"
require_kctx; valid_run_id "$RUN"
M1_RUN=${M1_RUN:-m1-20261118a}; valid_run_id "$M1_RUN"
[ "$RUN" != "$M1_RUN" ] || die "M4 run-id must differ from the M1 run-id"
F01_MAX_MB=${F01_MAX_MB:-200}
EVIDENCE_DIR=${EVIDENCE_DIR:-/tmp/claude-1000/-home-jlaska-Projects-herdrnetes/4e33ac86-9385-4fe7-8dc6-2ee8820b89da/scratchpad/m4/evidence-$RUN}
mkdir -p "$EVIDENCE_DIR/raw"
ROUND=$(date -u +%H%M%S)
P="m4r${ROUND}"
CM="request-repo-$RUN"
SCRATCH=herdr-scratch-0
LIVE_NS=herdrnetes-exp; LIVE_POD=herdr-0     # read-only observation only
RES="$EVIDENCE_DIR/results-$ROUND.tsv"; TIM="$EVIDENCE_DIR/timings-$ROUND.tsv"
printf 'test\tstatus\tdetail\n' >"$RES"; printf 'step\tseconds\n' >"$TIM"
FAILS=0

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
kv() { grep -m1 "^$2=" <<<"$1" | cut -d= -f2- || true; }   # kv <text> <key>

# ------------------------------------------------------------ rendering (own wrappers; lib.sh untouched)
affinity_json() { # affinity_json <In|NotIn> <node>   ("none" -> {})
  if [ "$1" = none ]; then echo '{}'; return; fi
  [[ "$2" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "bad node name '$2'"
  printf '{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchFields":[{"key":"metadata.name","operator":"%s","values":["%s"]}]}]}}}\n' "$1" "$2"
}
render_checked() {
  local out; out=$(cat)
  if grep -E '^\s*namespace:' <<<"$out" | grep -vqE 'namespace: "?herdrnetes-exp005"?\s*$'; then die "rendered manifest names a namespace other than $NS"; fi
  printf '%s\n' "$out"
}
render_pvc() { REPO_ID=$1 RUN_ID=$RUN envsubst '${REPO_ID} ${RUN_ID}' <"$MANIFEST_DIR/repo-pvc.yaml" | render_checked; }
render_pod() { # render_pod <pod-name> <repo-id> <component> <affinity-json>   (claimName = repo-<repo-id>)
  POD_NAME=$1 REPO_ID=$2 COMPONENT=$3 AFFINITY_JSON=$4 CM_NAME=$CM RUN_ID=$RUN \
    envsubst '${POD_NAME} ${REPO_ID} ${COMPONENT} ${AFFINITY_JSON} ${CM_NAME} ${RUN_ID}' <"$MANIFEST_DIR/workspace-pod.yaml" | render_checked
}

# ------------------------------------------------------------ small kubectl helpers
px() { k exec -i "$SCRATCH" -c herdr -- bash -s -- "$@"; }              # script on stdin, in herdr-scratch-0
pxp() { local pod=$1; shift; k exec -i "$pod" -c ws -- bash -s -- "$@"; } # script on stdin, in a ws pod
pod_phase() { k get pod "$1" -o go-template='{{.status.phase}}' 2>/dev/null || echo absent; }
pod_ready() { [ "$(k get pod "$1" -o go-template='{{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}' 2>/dev/null)" = True ]; }
wait_pod_ready() { local end=$((SECONDS+$2)); while [ $SECONDS -lt $end ]; do pod_ready "$1" && return 0; sleep 1; done; return 1; }
pod_facts() { k get pod "$1" -o go-template='{{.metadata.uid}} {{(index .status.containerStatuses 0).restartCount}} {{.spec.nodeName}}' 2>/dev/null; }
pod_node() { k get pod "$1" -o go-template='{{.spec.nodeName}}'; }
pod_events() { k get events --field-selector "involvedObject.name=$1" --sort-by=.metadata.creationTimestamp 2>&1 || true; }
# fact_line <pod>: "uid=.. restarts=.. ready=.." (read-only, tolerant)
fact_line() {
  local f r; f=$(pod_facts "$1" || true); r=no; pod_ready "$1" && r=yes
  echo "uid=$(cut -d' ' -f1 <<<"$f") restarts=$(cut -d' ' -f2 <<<"$f") ready=$r"
}
live_line() { kubectl --context "$KCTX" -n "$LIVE_NS" get pod "$LIVE_POD" -o go-template='uid={{.metadata.uid}} restarts={{(index .status.containerStatuses 0).restartCount}} phase={{.status.phase}}' 2>&1 || true; }

herdr_pid() {
  px <<'EOS' || echo none
for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || continue
  case "$c" in "/usr/local/bin/herdr server"*) echo "${p#/proc/}"; exit 0;; esac
done
echo none
EOS
}

# rr <id> <source> [opts]: run request-repo in herdr-scratch-0; sets RR_OUT RR_RC (stderr -> raw/rr-<id>.err)
rr() {
  local id=$1 src=$2; shift 2
  RR_RC=0
  RR_OUT=$(k exec "$SCRATCH" -c herdr -- python3 /opt/exp005/bin/request-repo "$@" "$id" "$src" 2>>"$(raw "rr-$id.err")") || RR_RC=$?
  printf '%s\n' "$RR_OUT" >>"$(raw "rr-$id.json")"
}

# ------------------------------------------------------------ preflight
guard_ns
k get statefulset herdr-scratch >/dev/null 2>&1 || die "herdr-scratch StatefulSet not found in $NS (run M1 first)"
guard statefulset herdr-scratch "$M1_RUN"
guard pod "$SCRATCH" "$M1_RUN"
python3 "$MANIFEST_DIR/gen-configmap.py" "$RUN" "$CM" | render_checked | k apply -f - >/dev/null
guard configmap "$CM" "$RUN"

read -r SU SR SNODE <<<"$(pod_facts "$SCRATCH")"; SPID=$(herdr_pid)
rec M4-baseline INFO "herdr-scratch-0 uid=$SU restartCount=$SR node=$SNODE herdr_pid=$SPID; live $LIVE_NS/$LIVE_POD $(live_line)"
LIVE0=$(live_line)
check M4-baseline-pid "real herdr server process found (pid=$SPID)" test "$SPID" != none
k exec "$SCRATCH" -c herdr -- sh -c 'git --version; python3 --version; uname -r; sed -n 1,4p /usr/share/herdrnetes/manifest.txt' >"$(raw tool-versions.txt)" 2>&1 || true
k get pod "$SCRATCH" -o jsonpath='{.status.containerStatuses[0].imageID}' >"$(raw imageid.txt)" 2>&1 || true

# M2 pods (read-only): names ws-m2r*
M2PODS=$(k get pods -l herdrnetes.io/component=workspace -o name 2>/dev/null | sed 's#^pod/##' | grep -E '^ws-m2r' || true)
declare -A M2F0
for p in $M2PODS; do M2F0[$p]=$(fact_line "$p"); done
rec M4-baseline-m2 INFO "M2 pods (read-only): $(for p in $M2PODS; do echo -n "$p ${M2F0[$p]}; "; done)"

# sc_point <label>: herdr-scratch-0 must be unchanged vs current expectation (SU/SR/SPID)
sc_point() {
  local u r n p; read -r u r n <<<"$(pod_facts "$SCRATCH")"; p=$(herdr_pid)
  check "SC-$1" "herdr-scratch-0 uid $SU->$u restartCount $SR->$r herdr_pid $SPID->$p" test "$u" = "$SU" -a "$r" = "$SR" -a "$p" = "$SPID"
}

# ------------------------------------------------------------ shared scratch helpers
SYN_ENV='export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z'
# small deterministic bare source /tmp/src/<id>.git (idempotent) in a pod; target = "scratch" or ws pod name
mk_small_source() {
  local target=$1 id=$2 runner=px
  [ "$target" = scratch ] || runner="pxp $target"
  $runner "$id" <<EOS
set -eu
$SYN_ENV
s=/tmp/src/\$1.git
[ -d "\$s" ] && exit 0
mkdir -p /tmp/src; w=\$(mktemp -d /tmp/src/w.XXXXXX)
git init -q -b main "\$w"; echo "repo \$1" >"\$w/README"; seq 1 200 >"\$w/data.txt"
git -C "\$w" add .; git -C "\$w" commit -q -m "init \$1"
git clone -q --bare "\$w" "\$s"; rm -rf "\$w"
EOS
}
# scratch_rm <id>: remove an m4r* repo, its staging leftovers, state/lock and /tmp source (frees PVC space)
scratch_rm() {
  px "$1" <<'EOS'
set -eu
case "$1" in m4r*) ;; *) echo "refusing to remove non-m4r id $1" >&2; exit 1;; esac
rm -rf "/workspace/$1" /workspace/.herdr-repos/staging/"$1"@* "/workspace/.herdr-repos/state/$1.json" "/workspace/.herdr-repos/locks/$1.lock" "/tmp/src/$1.git"
EOS
}
m1_repos() { px <<'EOS'
for d in /workspace/m1r*; do [ -d "$d/.git" ] && basename "$d"; done; true
EOS
}
# snap_all <exclude-id>: per M1 repo (main worktrees only) HEAD/status/stash/refs/index hash+mtime/file hashes
snap_all() {
  px "$1" <<'EOS'
export GIT_OPTIONAL_LOCKS=0
for d in /workspace/m1r*; do
  [ -d "$d/.git" ] || continue
  n=$(basename "$d"); [ "$n" = "$1" ] && continue
  echo "== $n"; cd "$d"
  stat -c 'index_mtime=%.9Y' .git/index; sha256sum .git/index
  for f in README data.txt untracked.txt staged.txt; do [ -f "$f" ] && sha256sum "$f"; done
  git status --porcelain=v2 --branch; git rev-parse HEAD; git stash list; git for-each-ref
done
true
EOS
}
fsck_m1() { # fsck all M1 repos; failures logged to raw/fsck-failures.txt
  local r ok=1
  for r in $(m1_repos); do
    px "$r" <<'EOS' >>"$(raw fsck-$r.txt)" 2>&1 || { ok=0; echo "fsck FAILED for $r" >>"$(raw fsck-failures.txt)"; }
echo "fsck $1"; git -C /workspace/$1 fsck --strict
EOS
  done
  [ $ok = 1 ]
}
fsck_one() { px "$1" <<'EOS'
git -C /workspace/$1 fsck --strict
EOS
}

# ============================================================ F06 multiple linked worktrees
WREPO=""
for r in $(m1_repos); do
  # prefer a repo that is not the dirty one (no untracked.txt) and has no stale m4 worktrees
  if ! px "$r" <<'EOS' >/dev/null 2>&1
test -e /workspace/$1/untracked.txt
EOS
  then WREPO=$r; break; fi
done
[ -n "$WREPO" ] || { rec F06 LIMITATION "no clean M1 repo available for worktrees"; WREPO=""; }
BASE_SNAP=$(snap_all "${WREPO:-none}"); printf '%s\n' "$BASE_SNAP" >"$(raw snap-baseline.txt)"
[ -n "$BASE_SNAP" ] || rec M4-snapshot FAIL "empty baseline snapshot (no M1 repos found?)"
if [ -n "$WREPO" ]; then
  W1="$WREPO-w1$ROUND"; W2="$WREPO-w2$ROUND"
  k get pod "$SCRATCH" >/dev/null; guard pod "$SCRATCH" "$M1_RUN"
  F6_HEAD0=$(px "$WREPO" <<'EOS'
git -C /workspace/$1 rev-parse HEAD
EOS
)
  f6=0
  px "$WREPO" "$W1" "$W2" "$ROUND" <<EOS >"$(raw f06-setup.txt)" 2>&1 || f6=$?
set -eu
$SYN_ENV
cd /workspace/\$1
git worktree add -q -b m4-\$4-wt1 /workspace/\$2
git worktree add -q -b m4-\$4-wt2 /workspace/\$3
cd /workspace/\$2; echo m4 >m4.txt; git add m4.txt; git commit -q -m "m4 commit in wt1"
echo "wt1 .git file: \$(cat /workspace/\$2/.git)"
echo "wt1 HEAD: \$(git rev-parse HEAD)"
git -C /workspace/\$1 worktree list --porcelain
EOS
  check F06-setup "worktrees /workspace/$W1 and $W2 added to $WREPO, commit in wt1 (raw/f06-setup.txt)" test "$f6" = 0
  # shellcheck disable=SC2016
  F6_STATE=$(px "$WREPO" "$W1" "$W2" <<'EOS'
export GIT_OPTIONAL_LOCKS=0
echo "main_head=$(git -C /workspace/$1 rev-parse HEAD)"
echo "wt1_head=$(git -C /workspace/$2 rev-parse HEAD)"
echo "wt1_gitfile=$(sha256sum /workspace/$2/.git | cut -d' ' -f1)"
echo "wt1_status=$(git -C /workspace/$2 status --porcelain | wc -l)"
echo "wt_count=$(git -C /workspace/$1 worktree list --porcelain | grep -c '^worktree ')"
echo "prunable=$(git -C /workspace/$1 worktree list --porcelain | grep -c prunable)"
echo "wt2_ok=$(git -C /workspace/$3 status --porcelain >/dev/null 2>&1 && echo 1 || echo 0)"
EOS
)
  printf '%s\n' "$F6_STATE" >"$(raw f06-state-before.txt)"
  SRC6=$(px "$WREPO" <<'EOS'
git -C /workspace/$1 config remote.origin.url
EOS
)
  rr "$W1" "$SRC6"
  st_absent=$(px "$W1" <<'EOS'
[ -e /workspace/.herdr-repos/state/$1.json ] && echo present || echo absent
EOS
)
  F6_STATE2=$(px "$WREPO" "$W1" "$W2" <<'EOS'
export GIT_OPTIONAL_LOCKS=0
echo "main_head=$(git -C /workspace/$1 rev-parse HEAD)"
echo "wt1_head=$(git -C /workspace/$2 rev-parse HEAD)"
echo "wt1_gitfile=$(sha256sum /workspace/$2/.git | cut -d' ' -f1)"
echo "wt1_status=$(git -C /workspace/$2 status --porcelain | wc -l)"
echo "wt_count=$(git -C /workspace/$1 worktree list --porcelain | grep -c '^worktree ')"
echo "prunable=$(git -C /workspace/$1 worktree list --porcelain | grep -c prunable)"
echo "wt2_ok=$(git -C /workspace/$3 status --porcelain >/dev/null 2>&1 && echo 1 || echo 0)"
EOS
)
  check F06 "request-repo $W1 <origin of $WREPO> rc=$RR_RC status=$(jget "$RR_OUT" status) (want 4/conflict); worktree untouched=$([ "$F6_STATE" = "$F6_STATE2" ] && echo yes || echo no); no state file=$st_absent; worktrees=$(kv "$F6_STATE2" wt_count) (want 3) prunable=$(kv "$F6_STATE2" prunable)" \
    test "$RR_RC" = 4 -a "$F6_STATE" = "$F6_STATE2" -a "$st_absent" = absent -a "$(kv "$F6_STATE2" wt_count)" = 3 -a "$(kv "$F6_STATE2" prunable)" = 0 -a "$(kv "$F6_STATE2" main_head)" = "$F6_HEAD0"
  tim F06-note 0
fi
sc_point after-F06

# ============================================================ F01 mid-clone SIGKILL
F1="$P-f01"
guard pod "$SCRATCH" "$M1_RUN"
avail=$(px <<'EOS'
df -Pm /workspace | awk 'NR==2{print $4}'
EOS
)
MB=$(( (avail - 120) * 10 / 26 )); [ "$MB" -le "$F01_MAX_MB" ] || MB=$F01_MAX_MB
rec F01-sizing INFO "workspace PVC free ${avail}MiB (df before); synthetic source sized ${MB}MiB (clone+checkout ~2x on PVC)"
if [ "$MB" -lt 40 ]; then
  rec F01 LIMITATION "insufficient free workspace space (${avail}MiB) for a >=5s clone"
else
  per=$((MB/20)); [ $per -ge 1 ] || per=1
  t0=$(now)
  px "$F1" "$per" <<EOS >"$(raw f01-source.txt)" 2>&1
set -eu
$SYN_ENV
src=/tmp/src/\$1.git
mkdir -p /tmp/src; w=\$(mktemp -d /tmp/src/w.XXXXXX)
git init -q -b main "\$w"
for c in 1 2 3 4; do
  for f in 1 2 3 4 5; do head -c \$((\$2*1048576)) /dev/urandom >"\$w/c\${c}f\${f}.bin"; done
  git -C "\$w" add .; git -C "\$w" commit -q -m "c\$c"
done
git clone -q --bare "\$w" "\$src"; rm -rf "\$w"
echo "source_mb=\$(du -sm \$src | cut -f1)"
echo "commits=\$(git --git-dir=\$src rev-list --count HEAD)"
EOS
  tim F01-build-source "$(since "$t0")"
  F1OUT=$(px "$F1" <<'EOS'
export TERM=dumb
t0=$(date +%s.%N)
d() { awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}'; }
cnt() { pgrep -f "$1" | wc -l; }
setsid nohup python3 /opt/exp005/bin/request-repo "$1" "/tmp/src/$1.git" >/tmp/f01-$1.out 2>/tmp/f01-$1.err </dev/null &
seen=0
for _ in $(seq 1 1800); do
  if ls -d /workspace/.herdr-repos/staging/$1@* >/dev/null 2>&1 && [ "$(cnt "git clone.*staging/$1@")" -gt 0 ] \
     && [ $(( $(cnt 'upload-pack') + $(cnt 'index-pack') + $(cnt 'unpack-objects') + $(cnt 'pack-objects') )) -gt 0 ]; then seen=1; break; fi
  sleep 0.05
done
echo "inflight_seen=$seen"; echo "t_inflight_s=$(d)"
echo "n_clone=$(cnt "git clone.*staging/$1@") n_upload_pack=$(cnt upload-pack) n_index_pack=$(cnt index-pack) n_unpack=$(cnt unpack-objects) n_pack_objects=$(cnt pack-objects)"
ps -eo pid,ppid,etimes,args 2>/dev/null | grep -E 'git|request-repo' | grep -v grep | sed 's/^/PS: /'
du -sm /workspace/.herdr-repos/staging/$1@* 2>/dev/null | sed 's/^/STAGING_MB: /'
tk=$(date +%s.%N)
pkill -9 -f "request-repo $1"
gone=NA
for _ in $(seq 1 100); do
  n=$(( $(cnt 'git clone') + $(cnt 'index-pack') + $(cnt 'unpack-objects') + $(cnt 'upload-pack') + $(cnt 'pack-objects') ))
  [ "$n" -eq 0 ] && { gone=$(awk -v a="$tk" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}'); break; }
  sleep 0.05
done
echo "git_children_gone_after_s=$gone"
echo "request_alive=$(cnt "request-repo $1")"
t=absent; [ -e /workspace/$1 ] && t=PRESENT; echo "target=$t"
s=absent; ls -d /workspace/.herdr-repos/staging/$1@* >/dev/null 2>&1 && s=present; echo "staging=$s"
du -sm /workspace/.herdr-repos/staging/$1@* 2>/dev/null | sed 's/^/STAGING_MB_AFTER: /'
EOS
)
  printf '%s\n' "$F1OUT" >"$(raw f01-kill.txt)"
  if [ "$(kv "$F1OUT" inflight_seen)" != 1 ]; then
    if [ "$(kv "$F1OUT" target)" = PRESENT ]; then
      rec F01 LIMITATION "clone finished before an in-flight git process was observed (source ${MB}MiB too small/fast); raise F01_MAX_MB if space allows"
    else rec F01 FAIL "no staging+git clone observed within 90s; raw/f01-kill.txt"; fi
  else
    gone=$(kv "$F1OUT" git_children_gone_after_s)
    ok_kill=0; { [ "$gone" != NA ] && awk -v g="$gone" 'BEGIN{exit !(g<=2.0)}'; } && ok_kill=1
    check F01-kill "in-flight at +$(kv "$F1OUT" t_inflight_s)s ($(grep -m1 '^n_clone' <<<"$F1OUT")); after SIGKILL of request-repo only: git children gone after ${gone}s (want <=2), request-repo alive=$(kv "$F1OUT" request_alive), target=$(kv "$F1OUT" target) (want absent), staging=$(kv "$F1OUT" staging) (want present)" \
      test "$ok_kill" = 1 -a "$(kv "$F1OUT" target)" = absent -a "$(kv "$F1OUT" staging)" = present -a "$(kv "$F1OUT" request_alive)" = 0
    t0=$(now); rr "$F1" "/tmp/src/$F1.git"; t_rr=$(since "$t0")
    tim F01-rerun-hydrate "$t_rr"
    left=$(px "$F1" <<'EOS'
ls -d /workspace/.herdr-repos/staging/$1@* 2>/dev/null | wc -l
EOS
)
    fok=0; fsck_one "$F1" >"$(raw f01-fsck.txt)" 2>&1 && fok=1
    sh1=$(px "$F1" <<'EOS'
git --git-dir=/tmp/src/$1.git rev-parse HEAD
EOS
)
    stale=0; grep -q 'removing stale staging' "$(raw rr-$F1.err)" && stale=1
    check F01 "rerun rc=$RR_RC action=$(jget "$RR_OUT" action) in ${t_rr}s (duration_ms=$(jget "$RR_OUT" duration_ms)); head matches source=$([ "$(jget "$RR_OUT" head)" = "$sh1" ] && echo yes || echo no); stale staging removed=$stale; staging_left=$left; fsck_clean=$fok" \
      test "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = hydrated -a "$(jget "$RR_OUT" head)" = "$sh1" -a "$left" = 0 -a "$fok" = 1 -a "$stale" = 1
    dur=$(jget "$RR_OUT" duration_ms)
    if [ -n "$dur" ] && [ "$dur" -lt 5000 ]; then rec F01-duration INFO "uninterrupted rerun took only ${dur}ms (<5s); kill window still observed in-flight but margin was small"; else rec F01-duration INFO "uninterrupted clone duration ${dur}ms (>=5s)"; fi
  fi
  scratch_rm "$F1"
  avail2=$(px <<'EOS'
df -Pm /workspace | awk 'NR==2{print $4}'
EOS
)
  rec F01-space INFO "workspace free after removing F01 source+repo: ${avail2}MiB (before ${avail}MiB)"
fi
sc_point after-F01

# ============================================================ F03 cross-pod concurrent hydration (same node, one RWO PVC)
X="$P-x"; XA="ws-$X-a"; XB="ws-$X-b"
[ ${#XA} -le 60 ] || die "pod name too long"
XNODE=$SNODE   # same node as herdr-scratch-0 (its own workspace PVC is a different volume)
if k get pvc "repo-$X" >/dev/null 2>&1; then die "PVC repo-$X already exists"; fi
t0=$(now)
render_pvc "$X" | k apply -f - >/dev/null
guard pvc "repo-$X" "$RUN"
end=$((SECONDS+120)); until [ "$(k get pvc "repo-$X" -o go-template='{{.status.phase}}')" = Bound ]; do [ $SECONDS -lt $end ] || die "PVC repo-$X not Bound in 120s"; sleep 1; done
XPV=$(k get pvc "repo-$X" -o go-template='{{.spec.volumeName}}')
tim F03-pvc-bound "$(since "$t0")"
for p in "$XA" "$XB"; do
  render_pod "$p" "$X" workspace "$(affinity_json In "$XNODE")" | k apply -f - >/dev/null
  guard pod "$p" "$RUN"
done
f3ready=1
for p in "$XA" "$XB"; do wait_pod_ready "$p" 300 || { f3ready=0; pod_events "$p" >"$(raw "$p-notready.txt")"; }; done
if [ $f3ready = 0 ]; then
  rec F03 FAIL "pods not both Ready in 300s (raw/$XA-notready.txt, $XB-notready.txt); F03/F04 skipped"
else
  tim F03-pods-ready "$(since "$t0")"
  nodes="$(pod_node "$XA") $(pod_node "$XB")"
  kc_get volumeattachments -o json 2>/dev/null | python3 -c '
import json, sys
for v in json.load(sys.stdin)["items"]:
    if v["spec"]["source"].get("persistentVolumeName") == sys.argv[1]:
        print(v["spec"]["nodeName"], v.get("status", {}).get("attached"))' "$XPV" >"$(raw f03-va.txt)" 2>&1 || true
  # identical deterministic source (~20MB text) at the same path in both pods
  for p in "$XA" "$XB"; do
    pxp "$p" "$X" <<EOS
set -eu
$SYN_ENV
s=/tmp/src/\$1.git
[ -d "\$s" ] && exit 0
mkdir -p /tmp/src; w=\$(mktemp -d /tmp/src/w.XXXXXX)
git init -q -b main "\$w"; seq 1 3000000 >"\$w/big.txt"; echo "shared \$1" >"\$w/README"
git -C "\$w" add .; git -C "\$w" commit -q -m "init \$1"
git clone -q --bare "\$w" "\$s"; rm -rf "\$w"
EOS
  done
  HA=$(pxp "$XA" "$X" <<'EOS'
git --git-dir=/tmp/src/$1.git rev-parse HEAD
EOS
)
  HB=$(pxp "$XB" "$X" <<'EOS'
git --git-dir=/tmp/src/$1.git rev-parse HEAD
EOS
)
  check F03-precond "both pods on node(s) '$nodes' (want identical); source HEAD identical A=$HA B=$HB" test "$(pod_node "$XA")" = "$(pod_node "$XB")" -a "$HA" = "$HB"
  cat >"$(raw f03-script.sh)" <<'EOS'
set -u
X=$1; tag=$2; B=/workspace/.m4-barrier-$X
mkdir -p "$B"; touch "$B/ready-$tag"
while [ ! -e "$B/go" ]; do sleep 0.01; done
for i in 1 2 3 4; do
  ( python3 /opt/exp005/bin/request-repo "$X" "/tmp/src/$X.git" >/tmp/f03-$tag-$i.out 2>/tmp/f03-$tag-$i.err; echo $? >/tmp/f03-$tag-$i.rc ) &
done
wait
for i in 1 2 3 4; do echo "RESULT $tag $i rc=$(cat /tmp/f03-$tag-$i.rc) $(cat /tmp/f03-$tag-$i.out)"; done
echo "CLONING $tag $(cat /tmp/f03-$tag-*.err | grep -c 'cloning ')"
EOS
  : >"$(raw f03-a.out)"; : >"$(raw f03-b.out)"
  k exec -i "$XA" -c ws -- bash -s -- "$X" a <"$(raw f03-script.sh)" >"$(raw f03-a.out)" 2>"$(raw f03-a.err)" & pa=$!
  k exec -i "$XB" -c ws -- bash -s -- "$X" b <"$(raw f03-script.sh)" >"$(raw f03-b.out)" 2>"$(raw f03-b.err)" & pb=$!
  armed=0
  for _ in $(seq 1 60); do
    n=$(pxp "$XA" "$X" <<'EOS' 2>/dev/null || echo 0
ls /workspace/.m4-barrier-$1/ready-* 2>/dev/null | wc -l
EOS
)
    [ "$n" = 2 ] && { armed=1; break; }; sleep 1
  done
  if [ $armed = 1 ]; then
    t0=$(now)
    pxp "$XA" "$X" <<'EOS'
touch /workspace/.m4-barrier-$1/go
EOS
  else
    kill "$pa" "$pb" 2>/dev/null || true
  fi
  wait "$pa" || true; wait "$pb" || true
  [ $armed = 0 ] || tim F03-concurrent-hydrate "$(since "$t0")"
  cat "$(raw f03-a.out)" "$(raw f03-b.out)" >"$(raw f03-all.txt)"
  summ=$(python3 - "$(raw f03-all.txt)" <<'PY'
import json, sys, collections
acts = collections.Counter(); rcs = collections.Counter(); clon = 0; n = 0
for line in open(sys.argv[1]):
    if line.startswith("RESULT "):
        parts = line.split(" ", 4); n += 1
        rcs[parts[3]] += 1
        try: acts[json.loads(parts[4]).get("action")] += 1
        except Exception: acts["unparsed"] += 1
    elif line.startswith("CLONING "):
        clon += int(line.split()[2])
print("n=%d hydrated=%d already_ready=%d other=%d rcs=%s cloning_msgs=%d" % (
    n, acts["hydrated"], acts["already_ready"], n - acts["hydrated"] - acts["already_ready"], dict(rcs), clon))
PY
)
  rec F03-raw INFO "$summ (raw/f03-all.txt)"
  attempts=$(pxp "$XA" "$X" <<'EOS'
python3 -c 'import json,sys; print(json.load(open("/workspace/.herdr-repos/state/%s.json" % sys.argv[1])).get("attempts"))' "$1"
EOS
)
  fa=0; pxp "$XB" "$X" <<'EOS' >"$(raw f03-fsck.txt)" 2>&1 && fa=1
git -C /workspace/$1 fsck --strict
EOS
  left=$(pxp "$XA" "$X" <<'EOS'
ls /workspace/.herdr-repos/staging | wc -l
EOS
)
  check F03 "2 pods x 4 parallel requests on $(pod_node "$XA"): $summ; state attempts=$attempts (want 1); staging entries=$left; fsck clean (from B)=$fa; barrier armed=$armed" \
    test "$armed" = 1 -a "$(grep -c 'hydrated=1 ' <<<"$summ")" = 1 -a "$(grep -c 'already_ready=7 ' <<<"$summ")" = 1 -a "$(grep -c "rcs={'rc=0': 8}" <<<"$summ")" = 1 -a "$(grep -c 'cloning_msgs=1$' <<<"$summ")" = 1 -a "$attempts" = 1 -a "$left" = 0 -a "$fa" = 1
  pxp "$XA" "$X" <<'EOS' || true
rm -rf /workspace/.m4-barrier-$1
EOS
  sc_point after-F03

  # ========================================================== F04 PVC deletion under running consumers
  guard pvc "repo-$X" "$RUN"; guard pod "$XA" "$RUN"; guard pod "$XB" "$RUN"
  k get pv "$XPV" -o yaml >"$(raw "pv-$XPV-before.yaml")" 2>&1 || true
  RECLAIM=$(kc_get pv "$XPV" -o go-template='{{.spec.persistentVolumeReclaimPolicy}}' 2>/dev/null || echo unknown)
  tdel=$(now)
  k delete pvc "repo-$X" --wait=false >"$(raw f04-delete-pvc.txt)" 2>&1
  : >"$(raw f04-timeline.txt)"
  samples=0; bad=0
  while [ "$(since "$tdel" | cut -d. -f1)" -lt 32 ]; do
    pv=$(k get pvc "repo-$X" -o go-template='{{.status.phase}}|{{if .metadata.deletionTimestamp}}Terminating{{else}}live{{end}}|{{range .metadata.finalizers}}{{.}},{{end}}' 2>&1 || true)
    ph="$(pod_phase "$XA")/$(pod_phase "$XB")"
    rw=0; pxp "$XB" "$X" <<'EOS' >/dev/null 2>&1 && rw=1
git -C /workspace/$1 status --porcelain >/dev/null && git -C /workspace/$1 log -1 --format=%H >/dev/null && date >>/workspace/$1-f04-write.txt && sync
EOS
    echo "$(since "$tdel")s pvc=$pv pods=$ph rw_ok=$rw" >>"$(raw f04-timeline.txt)"
    samples=$((samples+1))
    case "$pv" in *Terminating*kubernetes.io/pvc-protection*) ;; *) bad=$((bad+1));; esac
    [ "$ph" = Running/Running ] || bad=$((bad+1))
    [ $rw = 1 ] || bad=$((bad+1))
    sleep 4
  done
  check F04-observe "PVC delete issued with consumers running; $samples samples over >=30s, deviations=$bad (want 0: PVC Terminating + kubernetes.io/pvc-protection finalizer, both pods Running, repo readable and writable); raw/f04-timeline.txt" test "$bad" = 0 -a "$samples" -ge 5
  k delete pod "$XA" --wait=true --timeout=120s >"$(raw f04-delete-pod-a.txt)" 2>&1 || rec F04-pod-delete FAIL "delete of $XA incomplete in 120s (NOT forcing)"
  k get pvc "repo-$X" -o go-template='{{.status.phase}} deletionTimestamp={{.metadata.deletionTimestamp}} finalizers={{.metadata.finalizers}}{{"\n"}}' >"$(raw f04-after-pod-a.txt)" 2>&1 || true
  k delete pod "$XB" --wait=true --timeout=120s >"$(raw f04-delete-pod-b.txt)" 2>&1 || rec F04-pod-delete FAIL "delete of $XB incomplete in 120s (NOT forcing)"
  tpods=$(since "$tdel")
  end=$((SECONDS+180)); pvc_gone=0
  while [ $SECONDS -lt $end ]; do k get pvc "repo-$X" >/dev/null 2>&1 || { pvc_gone=1; break; }; sleep 3; done
  tim F04-pvc-delete-to-pvc-gone "$(since "$tdel")"
  pv_state=""; end=$((SECONDS+180))
  while [ $SECONDS -lt $end ]; do
    pv_state=$(kc_get pv "$XPV" -o go-template='{{.status.phase}}' 2>/dev/null) || { pv_state=GONE; break; }
    [ "$RECLAIM" != Delete ] && [ "$pv_state" = Released ] && break
    sleep 3
  done
  tim "F04-pvc-delete-to-pv-($pv_state)" "$(since "$tdel")"
  kc_get pv "$XPV" -o yaml >"$(raw "pv-$XPV-after.yaml")" 2>&1 || true
  okpv=0; { [ "$RECLAIM" = Delete ] && [ "$pv_state" = GONE ]; } || { [ "$RECLAIM" != Delete ] && [ "$pv_state" = Released ]; } && okpv=1
  check F04 "after graceful pod deletion (at ${tpods}s) PVC gone=$pvc_gone, PV $XPV state=$pv_state (reclaim=$RECLAIM; want GONE if Delete, else Released); raw/f04-*.txt" test "$pvc_gone" = 1 -a "$okpv" = 1
  sc_point after-F04
fi

# ============================================================ F05 missing-PVC isolation (H8)
MISS="$P-missing"; MP="ws-$MISS"
if k get pvc "repo-$MISS" >/dev/null 2>&1; then die "PVC repo-$MISS unexpectedly exists"; fi
declare -A M2F1
render_pod "$MP" "$MISS" workspace "$(affinity_json none x)" | k apply -f - >/dev/null
guard pod "$MP" "$RUN"
t0=$(now); reason=""; phase=""
: >"$(raw f05-timeline.txt)"
while [ "$(since "$t0" | cut -d. -f1)" -lt 40 ]; do
  phase=$(pod_phase "$MP")
  reason=$(k get events --field-selector "involvedObject.name=$MP" -o go-template='{{range .items}}{{.reason}}: {{.message}}{{"\n"}}{{end}}' 2>/dev/null | head -1 || true)
  echo "$(since "$t0")s phase=$phase event=$reason" >>"$(raw f05-timeline.txt)"
  [ -n "$reason" ] && [ "$(since "$t0" | cut -d. -f1)" -ge 15 ] && break
  sleep 3
done
pod_events "$MP" >"$(raw f05-events.txt)"
k get pod "$MP" -o yaml >"$(raw f05-pod.yaml)" 2>&1 || true
unaff=1; msg=""
read -r u r _ <<<"$(pod_facts "$SCRATCH")"; [ "$u" = "$SU" ] && [ "$r" = "$SR" ] && pod_ready "$SCRATCH" || unaff=0
for p in $M2PODS; do M2F1[$p]=$(fact_line "$p"); [ "${M2F1[$p]}" = "${M2F0[$p]}" ] || unaff=0; msg="$msg $p ${M2F0[$p]} -> ${M2F1[$p]};"; done
check F05 "pod $MP referencing non-existent PVC repo-$MISS: phase=$phase (want Pending); first event: ${reason:-none} (want FailedScheduling ... not found); herdr-scratch-0 ready+unchanged and M2 pods unchanged:$msg unaffected=$unaff" \
  test "$phase" = Pending -a "$unaff" = 1 -a "$(grep -c 'not found' <<<"$reason")" = 1
guard pod "$MP" "$RUN"; k delete pod "$MP" --wait=true --timeout=60s >"$(raw f05-delete.txt)" 2>&1 || rec F05-cleanup FAIL "delete of $MP incomplete (NOT forcing)"
sc_point after-F05

# ============================================================ F02 container crash (SIGKILL herdr server) during hydration
F2="$P-f02"
FIRST_SNAP=$(snap_all "${WREPO:-none}")
check F02-pre "M1 snapshot unchanged going into F02" test "$BASE_SNAP" = "$FIRST_SNAP"
mk_small_source scratch "$F2"
px "$F2" <<'EOS'
setsid nohup env REQUEST_REPO_TEST_PAUSE_AFTER_CLONE=60 python3 /opt/exp005/bin/request-repo "$1" "/tmp/src/$1.git" >/tmp/f02-$1.out 2>/tmp/f02-$1.err </dev/null &
EOS
paused=0
for _ in $(seq 1 60); do
  if px "$F2" <<'EOS' >/dev/null 2>&1; then paused=1; break; fi
ls -d /workspace/.herdr-repos/staging/$1@* >/dev/null 2>&1 && grep -q 'TEST-ONLY pause' /tmp/f02-$1.err
EOS
  sleep 1
done
check F02-paused "request-repo for $F2 paused after clone, staging present, target absent" test "$paused" = 1
read -r U0 R0 _ <<<"$(pod_facts "$SCRATCH")"; PID0=$(herdr_pid)
guard pod "$SCRATCH" "$M1_RUN"
t0=$(now)
px "$PID0" <<'EOS' >"$(raw f02-kill.txt)" 2>&1 || true
case "$1" in none|"") echo "no herdr server pid"; exit 1;; esac
echo "killing herdr server pid $1: $(tr '\0' ' ' </proc/$1/cmdline)"
echo "pid1: $(tr '\0' ' ' </proc/1/cmdline)"
kill -9 "$1"
EOS
changed=0; U1=$U0; R1=$R0
end=$((SECONDS+90))
while [ $SECONDS -lt $end ]; do
  f=$(pod_facts "$SCRATCH" || true)
  if [ -n "$f" ]; then read -r U1 R1 _ <<<"$f"; if [ "$U1" != "$U0" ] || [ "$R1" != "$R0" ]; then changed=1; break; fi; fi
  sleep 1
done
t_change=$(since "$t0")
if [ $changed = 1 ]; then
  end=$((SECONDS+420)); rdy=0
  while [ $SECONDS -lt $end ]; do
    if pod_ready "$SCRATCH" && [ "$(herdr_pid)" != none ]; then rdy=1; break; fi
    sleep 3
  done
  t_ready=$(since "$t0")
  tim F02-kill-to-restart-observed "$t_change"; tim F02-kill-to-ready "$t_ready"
  k get pod "$SCRATCH" -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}{.status.containerStatuses[0].state}{"\n"}' >"$(raw f02-container-state.txt)" 2>&1 || true
  read -r U1 R1 _ <<<"$(pod_facts "$SCRATCH")"
  if [ "$U1" = "$U0" ] && [ "$R1" -gt "$R0" ]; then kind="container restarted in place (same pod UID, restartCount $R0->$R1)"
  else kind="pod replaced (uid $U0->$U1)"; fi
  rec F02-restart INFO "$kind; observed after ${t_change}s, Ready after ${t_ready}s; lastState in raw/f02-container-state.txt"
  PIDN=$(herdr_pid)
  # A restarted container gets a new PID namespace, so the server PID number can repeat (7 -> 7);
  # the restart itself is shown by restartCount and lastState (raw/f02-container-state.txt).
  check F02-ready "pod Ready again with a herdr server in a restarted container (restartCount $R0 -> $R1, pid $PID0 -> $PIDN)" test "$rdy" = 1 -a "$PIDN" != none -a "$R1" != "$R0"
  SU=$U1; SR=$R1; SPID=$PIDN
else
  rec F02-restart LIMITATION "killing the herdr server (pid $PID0) did not restart the container or replace the pod within 90s (entrypoint/tini keeps the container alive or respawns); pod UID/restartCount unchanged; NOT force-deleting the pod. See raw/f02-kill.txt"
  px "$F2" <<'EOS' || true
pkill -9 -f "request-repo $1" || echo "no paused request-repo left"
EOS
  PIDN=$(herdr_pid); rec F02-server INFO "herdr server pid after kill: $PIDN (was $PID0)"
fi
# state of the interrupted hydration
mk_small_source scratch "$F2"
st=$(px "$F2" <<'EOS'
t=absent; [ -e /workspace/$1 ] && t=PRESENT; echo "target=$t"
s=absent; ls -d /workspace/.herdr-repos/staging/$1@* >/dev/null 2>&1 && s=present; echo "staging=$s"
echo "request_proc=$(pgrep -f "request-repo $1" | wc -l)"
EOS
)
printf '%s\n' "$st" >"$(raw f02-post-restart-state.txt)"
check F02-target "after restart: target=$(kv "$st" target) (want absent), staging=$(kv "$st" staging) (want present if container/pod kept the PVC; stale), interrupted request process=$(kv "$st" request_proc)" \
  test "$(kv "$st" target)" = absent -a "$(kv "$st" staging)" = present
rr "$F2" "/tmp/src/$F2.git"
left=$(px "$F2" <<'EOS'
ls -d /workspace/.herdr-repos/staging/$1@* 2>/dev/null | wc -l
EOS
)
stale=0; grep -q 'removing stale staging' "$(raw rr-$F2.err)" && stale=1
f2ok=0; fsck_one "$F2" >"$(raw f02-fsck.txt)" 2>&1 && f2ok=1
check F02-rerun "rerun rc=$RR_RC action=$(jget "$RR_OUT" action) attempt=$(jget "$RR_OUT" attempt); stale staging removed=$stale, staging_left=$left; fsck=$f2ok" \
  test "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = hydrated -a "$stale" = 1 -a "$left" = 0 -a "$f2ok" = 1
m1ok=0; fsck_m1 >/dev/null 2>&1 && m1ok=1
POST_SNAP=$(snap_all "${WREPO:-none}"); printf '%s\n--\n%s\n' "$BASE_SNAP" "$POST_SNAP" >"$(raw f02-snapshot-before-after.txt)"
check F02-m1 "all M1 repos fsck clean=$m1ok; M1 dirty/untracked/staged/stash snapshot (index mtime included) identical to baseline=$([ "$BASE_SNAP" = "$POST_SNAP" ] && echo yes || echo no)" \
  test "$m1ok" = 1 -a "$BASE_SNAP" = "$POST_SNAP" -a -n "$BASE_SNAP"
if [ -n "$WREPO" ]; then
  F6_STATE3=$(px "$WREPO" "$W1" "$W2" <<'EOS'
export GIT_OPTIONAL_LOCKS=0
echo "main_head=$(git -C /workspace/$1 rev-parse HEAD)"
echo "wt1_head=$(git -C /workspace/$2 rev-parse HEAD)"
echo "wt1_gitfile=$(sha256sum /workspace/$2/.git | cut -d' ' -f1)"
echo "wt1_status=$(git -C /workspace/$2 status --porcelain | wc -l)"
echo "wt_count=$(git -C /workspace/$1 worktree list --porcelain | grep -c '^worktree ')"
echo "prunable=$(git -C /workspace/$1 worktree list --porcelain | grep -c prunable)"
echo "wt2_ok=$(git -C /workspace/$3 status --porcelain >/dev/null 2>&1 && echo 1 || echo 0)"
EOS
)
  printf '%s\n' "$F6_STATE3" >"$(raw f06-state-after-f02.txt)"
  check F06-after-F02 "worktrees after F02: identical to pre-F02 state=$([ "$F6_STATE2" = "$F6_STATE3" ] && echo yes || echo no); count=$(kv "$F6_STATE3" wt_count) prunable=$(kv "$F6_STATE3" prunable) wt2 status ok=$(kv "$F6_STATE3" wt2_ok)" \
    test "$F6_STATE2" = "$F6_STATE3" -a "$(kv "$F6_STATE3" prunable)" = 0 -a "$(kv "$F6_STATE3" wt2_ok)" = 1
fi
if [ "$changed" = 1 ]; then
  if [ "$rdy" = 1 ] && [ "$f2ok" = 1 ] && [ "$m1ok" = 1 ] && [ "$BASE_SNAP" = "$POST_SNAP" ]; then cls="fully restored (repo data + hydration path); the herdr server process and any agent/session processes were interrupted by the crash, session recovery is NOT measured here"; else cls="recoverable with manual action or lost: see failing rows"; fi
  rec F02-classification INFO "$cls"
else
  rec F02-classification INFO "not exercised (LIMITATION: server kill did not restart the container)"
fi
scratch_rm "$F2"
SPID_NOW=$(herdr_pid)
rec F02-final INFO "herdr-scratch-0 now: $(fact_line "$SCRATCH") herdr_pid=$SPID_NOW"

# ============================================================ wrap up
LIVE1=$(live_line)
check M4-live-herdr "live $LIVE_NS/$LIVE_POD unchanged (read-only): before [$LIVE0] after [$LIVE1]" test "$LIVE0" = "$LIVE1"
for p in $M2PODS; do check "M4-m2-$p" "M2 pod unchanged at end: before ${M2F0[$p]} after $(fact_line "$p")" test "${M2F0[$p]}" = "$(fact_line "$p")"; done
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
echo "M4 complete: $FAILS failed check(s). Evidence: $EVIDENCE_DIR (results-$ROUND.tsv). Remaining: ConfigMap $CM, worktrees ${W1:-none}/${W2:-none} in $WREPO; run cleanup.sh $RUN when done."
[ "$FAILS" = 0 ]
