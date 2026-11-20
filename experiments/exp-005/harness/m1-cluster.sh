#!/usr/bin/env bash
# EXP-005 M1 driver (workstation side, kubectl only). Usage: KCTX=<context> m1-cluster.sh <run-id>
# Deploys the scratch Herdr-equivalent pod in namespace herdrnetes-exp005 and runs S01-S13.
# Env: KCTX (required, no default); EVIDENCE_DIR (default: scratchpad, never the repo).
# Rerun-safe: repository ids carry a per-invocation ROUND suffix so S01 ("absent") holds each time.
# Mutations: kubectl apply of this experiment's manifests, kubectl exec in herdr-scratch-0, and
# S11's delete of herdr-scratch-0 (guarded by label checks). Nothing outside $NS is touched.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

RUN=${1:-}; [ -n "$RUN" ] || die "usage: KCTX=<ctx> $0 <run-id>"
require_kctx; valid_run_id "$RUN"
EVIDENCE_DIR=${EVIDENCE_DIR:-/tmp/claude-1000/-home-jlaska-Projects-herdrnetes/4e33ac86-9385-4fe7-8dc6-2ee8820b89da/scratchpad/m1/evidence-$RUN}
mkdir -p "$EVIDENCE_DIR/raw"
ROUND=$(date -u +%H%M%S)
P="m1r${ROUND}"                       # repo id prefix for this invocation
POD=herdr-scratch-0
RES="$EVIDENCE_DIR/results-$ROUND.tsv"; TIM="$EVIDENCE_DIR/timings-$ROUND.tsv"
printf 'test\tstatus\tdetail\n' >"$RES"; printf 'step\tseconds\n' >"$TIM"
FAILS=0

rec() { # rec <test> <PASS|FAIL|INFO> <detail>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RES"
  log "$1 $2 $3"
  [ "$2" = FAIL ] && FAILS=$((FAILS+1))
  return 0
}
check() { # check <test> <detail> <command...>   (command evaluates locally)
  local t=$1 d=$2; shift 2
  if "$@"; then rec "$t" PASS "$d"; else rec "$t" FAIL "$d"; fi
}
timed() { local s=$SECONDS; "$@"; printf '%s\t%s\n' "$1" "$((SECONDS-s))" >>"$TIM"; }
# px [args...]: run a bash script (stdin) in the pod as uid 1000; args become $1...
px() { k exec -i "$POD" -c herdr -- bash -s -- "$@"; }
# rr <id> <source> [opts]: run request-repo in the pod; sets RR_OUT, RR_RC
rr() {
  local id=$1 src=$2; shift 2
  RR_RC=0
  RR_OUT=$(k exec "$POD" -c herdr -- python3 /opt/exp005/bin/request-repo "$@" "$id" "$src" 2>"$EVIDENCE_DIR/raw/rr-$id-$$.err") || RR_RC=$?
  printf '%s\n' "$RR_OUT" >>"$EVIDENCE_DIR/raw/rr-$id.json"
}
jget() { python3 -c '
import json,sys
try: v=json.loads(sys.argv[1]).get(sys.argv[2])
except Exception: v=None
print("" if v is None else v)' "$1" "$2"; }

pod_facts() { # uid restartCount node
  k get pod "$POD" -o go-template='{{.metadata.uid}} {{(index .status.containerStatuses 0).restartCount}} {{.spec.nodeName}}'
}
herdr_pid() {
  px <<'EOS'
for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || continue
  case "$c" in "/usr/local/bin/herdr server"*) echo "${p#/proc/}"; exit 0;; esac
done
echo none
EOS
}
wait_ready() { # wait_ready <old-uid-or-empty>
  local end=$((SECONDS+420)) uid
  while [ $SECONDS -lt $end ]; do
    uid=$(k get pod "$POD" -o go-template='{{.metadata.uid}}' 2>/dev/null || true)
    if [ -n "$uid" ] && [ "$uid" != "${1:-}" ] \
       && [ "$(k get pod "$POD" -o go-template='{{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}' 2>/dev/null)" = True ]; then
      return 0
    fi
    sleep 3
  done
  die "pod $POD not Ready within 420s"
}

# ---------------------------------------------------------------- deploy
deploy() {
  guard_ns
  if k get statefulset herdr-scratch >/dev/null 2>&1; then guard statefulset herdr-scratch "$RUN"; fi
  render namespace "$RUN" | kubectl --context "$KCTX" apply -f -
  guard_ns
  render request-repo-configmap "$RUN" | k apply -f -
  render networkpolicy "$RUN" | k apply -f -
  render herdr-scratch "$RUN" | k apply -f -
  guard statefulset herdr-scratch "$RUN"; guard configmap request-repo "$RUN"
  # wait for the pod object to exist, then for Ready
  local end=$((SECONDS+120)); until k get pod "$POD" >/dev/null 2>&1; do [ $SECONDS -lt $end ] || die "pod never created"; sleep 2; done
  wait_ready ""
}
timed deploy
guard pod "$POD" "$RUN"
read -r UID0 RC0 NODE0 <<<"$(pod_facts)"; PID0=$(herdr_pid)
k get pod "$POD" -o jsonpath='{.status.containerStatuses[0].imageID}' >"$EVIDENCE_DIR/raw/imageid.txt"; echo >>"$EVIDENCE_DIR/raw/imageid.txt"
k get pvc -o wide >"$EVIDENCE_DIR/raw/pvc-initial.txt"
rec S04-baseline INFO "pod_uid=$UID0 restartCount=$RC0 node=$NODE0 herdr_pid=$PID0 imageID=$(cat "$EVIDENCE_DIR/raw/imageid.txt")"
check S04-baseline-pid "real herdr server process found (pid=$PID0)" test "$PID0" != none
px <<'EOS' >"$EVIDENCE_DIR/raw/tool-versions.txt"
git --version; python3 --version; id; uname -r; sed -n 1,4p /usr/share/herdrnetes/manifest.txt
EOS

# ---------------------------------------------------------------- synthetic sources (in /tmp, not the workspace PVC)
mk_sources() {
  px <<'EOS'
set -eu
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p /tmp/sources
for n in a b; do
  [ -d /tmp/sources/$n.git ] && continue
  w=$(mktemp -d /tmp/sources/w.XXXXXX); git init -q -b main "$w"
  echo "repo $n" >"$w/README"; seq 1 200 >"$w/data.txt"; git -C "$w" add .; git -C "$w" commit -q -m "init $n"
  git clone -q --bare "$w" /tmp/sources/$n.git; rm -rf "$w"
done
ls /tmp/sources
EOS
}
timed mk_sources
SA=/tmp/sources/a.git; SB=/tmp/sources/b.git
RA=${P}-a; RB=${P}-b; RC=${P}-c; RD=${P}-d; RE=${P}-e

# ---------------------------------------------------------------- S01-S03
if px "$RA" <<'EOS'
[ ! -e "/workspace/$1" ]
EOS
then rec S01 PASS "/workspace/$RA absent before request"; else rec S01 FAIL "/workspace/$RA present before request"; fi
s=$SECONDS; rr "$RA" "$SA"; printf 'S02-hydrate\t%s\n' "$((SECONDS-s))" >>"$TIM"
src_head=$(px <<EOS
git --git-dir=$SA rev-parse HEAD
EOS
)
check S02 "rc=0 status=ready action=hydrated head=$(jget "$RR_OUT" head)" \
  test "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = hydrated -a "$(jget "$RR_OUT" head)" = "$src_head"
if px "$RA" <<'EOS' >"$EVIDENCE_DIR/raw/s02-fsck.txt" 2>&1
git -C "/workspace/$1" fsck --strict
EOS
then rec S02-fsck PASS "git fsck --strict clean"; else rec S02-fsck FAIL "see raw/s02-fsck.txt"; fi
check S03 "path=$(jget "$RR_OUT" path)" test "$(jget "$RR_OUT" path)" = "/workspace/$RA"
top=$(px "$RA" <<'EOS'
git -C "/workspace/$1" rev-parse --show-toplevel
EOS
)
check S03-toplevel "show-toplevel=$top" test "$top" = "/workspace/$RA"

# ---------------------------------------------------------------- S05
snap_git() { px "$1" <<'EOS'
d=/workspace/$1/.git
stat -c 'inode=%i mtime=%.9Y' "$d"; stat -c 'index_inode=%i index_mtime=%.9Y' "$d/index"; sha256sum "$d/HEAD" "$d/config"
EOS
}
b=$(snap_git "$RA"); rr "$RA" "$SA"; a=$(snap_git "$RA")
check S05 "rc=$RR_RC action=$(jget "$RR_OUT" action); .git inode/mtime/index/HEAD/config unchanged" \
  test "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = already_ready -a "$b" = "$a"
printf '%s\n--\n%s\n' "$b" "$a" >"$EVIDENCE_DIR/raw/s05-before-after.txt"

# ---------------------------------------------------------------- S06
rr "$RB" "$SB"
rc_b=$RR_RC
px "$RA" "$RB" <<'EOS' >"$EVIDENCE_DIR/raw/s06.txt" 2>&1 && ok6=1 || ok6=0
for r in "$@"; do git -C /workspace/$r fsck --strict && echo "$r head=$(git -C /workspace/$r rev-parse HEAD) $(cat /workspace/$r/README)"; done
EOS
check S06 "second repo hydrated rc=$rc_b; both fsck clean; contents differ" \
  test "$rc_b" = 0 -a "${ok6:-0}" = 1 -a "$(grep -c . "$EVIDENCE_DIR/raw/s06.txt")" = 2

# ---------------------------------------------------------------- S07 (8 parallel execs)
s=$SECONDS
pids=(); for i in 1 2 3 4 5 6 7 8; do
  ( k exec "$POD" -c herdr -- python3 /opt/exp005/bin/request-repo "$RC" "$SA" >"$EVIDENCE_DIR/raw/s07-$i.json" 2>"$EVIDENCE_DIR/raw/s07-$i.err"; echo $? >"$EVIDENCE_DIR/raw/s07-$i.rc" ) &
  pids+=($!)
done
wait "${pids[@]}" || true
printf 'S07-concurrent\t%s\n' "$((SECONDS-s))" >>"$TIM"
ok=0 hyd=0 aready=0 clones=0
for i in 1 2 3 4 5 6 7 8; do
  [ "$(cat "$EVIDENCE_DIR/raw/s07-$i.rc")" = 0 ] && ok=$((ok+1))
  act=$(jget "$(cat "$EVIDENCE_DIR/raw/s07-$i.json")" action)
  [ "$act" = hydrated ] && hyd=$((hyd+1)); [ "$act" = already_ready ] && aready=$((aready+1))
  clones=$((clones + $(grep -c 'cloning ' "$EVIDENCE_DIR/raw/s07-$i.err" || true)))
done
attempts=$(px "$RC" <<'EOS'
python3 -c 'import json,sys; print(json.load(open("/workspace/.herdr-repos/state/%s.json" % sys.argv[1]))["attempts"])' "$1"
EOS
)
fsck7=0; px "$RC" <<'EOS' >/dev/null 2>&1 && fsck7=1
git -C /workspace/$1 fsck --strict
EOS
check S07 "ok=$ok/8 hydrated=$hyd already_ready=$aready clone_log_lines=$clones state_attempts=$attempts fsck_clean=$fsck7" \
  test "$ok" = 8 -a "$hyd" = 1 -a "$aready" = 7 -a "$clones" = 1 -a "$attempts" = 1 -a "$fsck7" = 1

# ---------------------------------------------------------------- S08
rr "$RD" /tmp/sources/does-not-exist.git
rc_bad=$RR_RC
absent=0; px "$RD" <<'EOS' >/dev/null 2>&1 && absent=1
[ ! -e /workspace/$1 ]
EOS
st=$(px "$RD" <<'EOS'
python3 -c 'import json,sys; print(json.load(open("/workspace/.herdr-repos/state/%s.json" % sys.argv[1]))["status"])' "$1"
EOS
)
rr "$RD" "$SA"
check S08 "bad source rc=$rc_bad (want 5) target_absent=$absent state=$st; retry rc=$RR_RC action=$(jget "$RR_OUT" action) attempt=$(jget "$RR_OUT" attempt)" \
  test "$rc_bad" = 5 -a "$absent" = 1 -a "$st" = failed -a "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = hydrated

# ---------------------------------------------------------------- S09 (SIGKILL mid-hydration)
px "$RE" "$SA" <<'EOS'
setsid nohup env REQUEST_REPO_TEST_PAUSE_AFTER_CLONE=300 python3 /opt/exp005/bin/request-repo "$1" "$2" >/tmp/s09.out 2>/tmp/s09.err </dev/null &
EOS
# wait for staging dir, then kill via a second exec
staged=0; for _ in $(seq 1 60); do
  if px "$RE" <<'EOS' >/dev/null 2>&1; then staged=1; break; fi
ls -d /workspace/.herdr-repos/staging/$1@* >/dev/null 2>&1 && grep -q 'TEST-ONLY pause' /tmp/s09.err
EOS
  sleep 1
done
px "$RE" <<'EOS' || true
pkill -9 -f "request-repo $1" || echo "pkill found nothing"
EOS
sleep 1
state9=$(px "$RE" <<'EOS'
t=absent; [ -e /workspace/$1 ] && t=PRESENT
s=none; ls -d /workspace/.herdr-repos/staging/$1@* >/dev/null 2>&1 && s=present
p=gone; pgrep -f "request-repo $1" >/dev/null && p=ALIVE
echo "target=$t staging=$s proc=$p"
EOS
)
rr "$RE" "$SA"
left=$(px "$RE" <<'EOS'
ls -d /workspace/.herdr-repos/staging/$1@* 2>/dev/null | wc -l
EOS
)
check S09 "staged_before_kill=$staged after_kill: $state9 (want target=absent staging=present proc=gone); rerun rc=$RR_RC action=$(jget "$RR_OUT" action) staging_left=$left" \
  test "$staged" = 1 -a "$state9" = "target=absent staging=present proc=gone" -a "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = hydrated -a "$left" = 0

# ---------------------------------------------------------------- S10
dirty() { px "$RA" <<'EOS'
set -eu
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
cd /workspace/$1
echo dirty >>README; echo untracked >untracked.txt; echo local >>data.txt
git commit -qam "local commit"; echo stash >>data.txt; git stash -q
echo dirty2 >>README; echo staged >staged.txt; git add staged.txt
EOS
}
snap10() { px "$1" <<'EOS'
export GIT_OPTIONAL_LOCKS=0; cd /workspace/$1
stat -c 'index_mtime=%.9Y' .git/index; sha256sum .git/index README data.txt untracked.txt staged.txt
git status --porcelain=v2 --branch; git rev-parse HEAD; git stash list; git for-each-ref
EOS
}
dirty; b=$(snap10 "$RA"); rr "$RA" "$SA"; a=$(snap10 "$RA")
printf '%s\n--\n%s\n' "$b" "$a" >"$EVIDENCE_DIR/raw/s10-before-after.txt"
check S10 "rc=$RR_RC action=$(jget "$RR_OUT" action); dirty/untracked/staged/commit/stash snapshot identical" \
  test "$RR_RC" = 0 -a "$(jget "$RR_OUT" action)" = already_ready -a "$b" = "$a" -a -n "$b"

# ---------------------------------------------------------------- S13 (before S11 so it persists)
if px "$RA" <<'EOS' >"$EVIDENCE_DIR/raw/s13.txt" 2>&1
set -eu
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git --version
git -C /workspace/$1 worktree add -q -b wt-feat /workspace/$1-wt
echo "worktree .git file: $(cat /workspace/$1-wt/.git)"
echo "admin gitdir backlink: $(cat /workspace/$1/.git/worktrees/$1-wt/gitdir)"
EOS
then rec S13 INFO "recorded in raw/s13.txt: $(tr '\n' ' ' <"$EVIDENCE_DIR/raw/s13.txt" | cut -c1-300)"; else rec S13 FAIL "worktree add failed (raw/s13.txt)"; fi

# ---------------------------------------------------------------- S04 (end of S01-S10)
read -r UID1 RC1 NODE1 <<<"$(pod_facts)"; PID1=$(herdr_pid)
check S04 "uid $UID0->$UID1 restartCount $RC0->$RC1 herdr_pid $PID0->$PID1" \
  test "$UID0" = "$UID1" -a "$RC0" = "$RC1" -a "$PID0" = "$PID1"

# ---------------------------------------------------------------- S12
s12=0
px "$RA" <<'EOS' >"$EVIDENCE_DIR/raw/s12.txt" 2>&1 || s12=$?
set -u
dev() { awk -v m="$1" '$5==m {print $3, $9, $10}' /proc/self/mountinfo; }   # major:minor fstype source
h=$(dev /home/herdr); w=$(dev /workspace)
echo "home: $h"; echo "workspace: $w"
[ -n "$h" ] && [ -n "$w" ] && [ "${h%% *}" != "${w%% *}" ] || { echo "home/workspace not separate mounts"; exit 1; }
n=$(find /home/herdr -maxdepth 4 \( -name '.herdr-repos' -o -name "m1r*" \) 2>/dev/null | wc -l)
echo "repo artefacts under home: $n"; [ "$n" = 0 ]
EOS
check S12 "$(tr '\n' ';' <"$EVIDENCE_DIR/raw/s12.txt")" test "$s12" = 0

# ---------------------------------------------------------------- S11 (pod delete/recreate, same PVCs)
presnap=$(snap10 "$RA")
guard pod "$POD" "$RUN"
s=$SECONDS
k delete pod "$POD" --wait=true --timeout=180s >"$EVIDENCE_DIR/raw/s11-delete.txt" 2>&1
wait_ready "$UID1"
printf 'S11-recreate-ready\t%s\n' "$((SECONDS-s))" >>"$TIM"
read -r UID2 _ NODE2 <<<"$(pod_facts)"; PID2=$(herdr_pid)
postsnap=$(snap10 "$RA")
fsck11=1; for r in "$RA" "$RB" "$RC" "$RD" "$RE"; do
  px "$r" <<'EOS' >>"$EVIDENCE_DIR/raw/s11-fsck.txt" 2>&1 || fsck11=0
echo "fsck $1"; git -C /workspace/$1 fsck --strict
EOS
done
# sources in /tmp are gone (emptyDir); request on a ready repo must still be already_ready
rr "$RA" "$SA"
wt=$(px "$RA" <<'EOS'
git -C /workspace/$1 worktree list --porcelain | grep -c '^worktree '
EOS
)
check S11 "uid $UID1->$UID2 (new pod, node $NODE1->$NODE2, herdr_pid $PID1->$PID2); fsck_all=$fsck11; dirty snapshot identical (index mtime included); already_ready=$(jget "$RR_OUT" action); worktrees=$wt" \
  test "$UID1" != "$UID2" -a "$fsck11" = 1 -a "$presnap" = "$postsnap" -a "$(jget "$RR_OUT" action)" = already_ready -a "$wt" = 2

# ---------------------------------------------------------------- wrap up
k get pods,pvc,statefulset -o wide >"$EVIDENCE_DIR/raw/final-objects.txt" 2>&1 || true
k get events --sort-by=.lastTimestamp >"$EVIDENCE_DIR/raw/events.txt" 2>&1 || true
python3 - "$RES" "$TIM" "$EVIDENCE_DIR/summary-$ROUND.json" "$RUN" "$FAILS" <<'PY'
import csv, json, sys
res = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
tim = list(csv.DictReader(open(sys.argv[2]), delimiter="\t"))
json.dump({"run_id": sys.argv[4], "failures": int(sys.argv[5]), "results": res, "timings": tim},
          open(sys.argv[3], "w"), indent=1)
PY
echo "M1 complete: $FAILS failed check(s). Evidence: $EVIDENCE_DIR (results-$ROUND.tsv). Cluster objects remain; run cleanup.sh when done."
[ "$FAILS" = 0 ]
