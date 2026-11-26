#!/bin/sh
# EXP-008 Stage C4 task step (K03-style, token-chained). Runs inside the sandbox, invoked by the agent.
# Derived from ../../stage-c/task/step.sh (unchanged there). C4 changes, and nothing else:
#   - default sleep 45 s (approved STEP_SLEEP=45; the launcher also exports it) and the sleep is recorded
#     in every attempt line (sleep=), so the harness can verify the pacing it gates on;
#   - a lock owner record now carries the owner's boot id; an owner record with an empty start time or a
#     different boot id is stale (the C0-C3 copy compared empty with empty and could report busy forever
#     after a torn owner write); locks.log records both boot ids;
#   - INT/TERM/HUP end the step without writing done (see the trap below).
#
#   ./step.sh N TOKEN
#
# - N must be exactly (last completed step + 1); step 1 takes the fixed token "start".
# - TOKEN must be the one-time token printed by step N-1. Only its sha256 is kept (in .state/), so
#   reading .state/ cannot reveal it; the agent's settings also deny reading .state/.
# - A wrong/repeated/out-of-order N, a wrong token, or a concurrent invocation is refused and
#   appended to refusals.log (nothing else changes).
# - Otherwise: append "attempt" to attempts.log, sleep STEP_SLEEP (45 s), append "done" to
#   progress.log and a hash-chained line to ledger.log, rotate the token, print the next command.
#
# The image has no git (EXP-006 base: tmux, openssh-server, tini, procps; + python3-minimal,
# ca-certificates), so the "commit" of the Stage C proposal (section 3.3) is replaced by ledger.log:
# each line carries sha256(previous line), so truncation or rewriting is detectable.
# Every log line records the invoking shell's PID and start time (ppid=, pstart=) and this
# process's PID, so the harness can tell whether two steps came from one tool-call shell (batched).
# POSIX sh + coreutils only. No network. Writes only inside its own directory.
set -u
D=$(cd "$(dirname "$0")" && pwd)
S=$D/.state
MAX=120
SLEEP=${STEP_SLEEP:-45}
case $SLEEP in '' | *[!0-9]*) SLEEP=45 ;; esac
bid() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
pst() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
# key form only (a fixed word, never the value): an in-sandbox check, from a descendant of the agent,
# that the agent's environment holds an OpenShell placeholder and not a real key. Never print the
# placeholder itself: a placeholder in a later request BODY is refused by the proxy (403).
# The placeholder prefix is assembled at run time so it never appears literally in a file the agent might
# print (a placeholder-like string in a request body is refused by the proxy).
pp="openshell"; pp="$pp:resolve:"
form() { case $1 in '') echo absent ;; "$pp"*) echo placeholder ;; sk-ant-*) echo REAL-KEY-SHAPE ;; *) echo other ;; esac; }
kf=$(form "${EXP008_ANTHROPIC_KEYREF:-}") ak=$(form "${ANTHROPIC_API_KEY:-}")
pcmd=$(tr '\0' ' ' <"/proc/$PPID/cmdline" 2>/dev/null | sha256sum | cut -c1-12) # hash only: the command text stays local
who="pid=$$ ppid=$PPID pstart=$(pst "$PPID") pcmd=$pcmd kf=$kf ak=$ak"
refuse() { printf 'refused n=%s t=%s reason=%s %s\n' "${N:-?}" "$(now)" "$1" "$who" >>"$D/refusals.log"; echo "REFUSED: $1"; exit 3; }

[ "$#" -eq 2 ] || { N=?; refuse argc; }
N=$1 TOK=$2
case $N in '' | *[!0-9]* | 0*) refuse bad-n ;; esac
case $TOK in '' | *[!a-z0-9]*) refuse bad-token-form ;; esac
[ "$N" -ge 1 ] && [ "$N" -le "$MAX" ] || refuse n-out-of-range

mkdir -p "$S"
# lock: a concurrent step.sh is refused (parallel batching). A lock left by a killed step (its owner pid is
# gone, or alive with a different start time) is broken and logged to locks.log, never silently.
if ! mkdir "$S/lock" 2>/dev/null; then
  op='' ost='' oboot=''
  read -r op ost oboot <"$S/lock/owner" 2>/dev/null || true
  # live owner = same pid, same non-empty /proc start time, same boot: anything else is stale
  if [ -n "$op" ] && [ -n "$ost" ] && [ "$(pst "$op")" = "$ost" ] && [ "$oboot" = "$(bid)" ]; then refuse busy; fi
  # no owner yet: another step may be between mkdir and writing it; busy unless the lock is > 30 s old
  if [ -z "$op" ] && [ $(( $(date +%s) - $(stat -c %Y "$S/lock" 2>/dev/null || date +%s) )) -lt 30 ]; then refuse busy; fi
  printf 'stale-lock-broken n=%s t=%s owner=%s owner_start=%s owner_boot=%s boot=%s %s\n' "$N" "$(now)" "${op:-unknown}" "${ost:-none}" "${oboot:-none}" "$(bid)" "$who" >>"$D/locks.log"
  rm -rf "$S/lock"; mkdir "$S/lock" 2>/dev/null || refuse busy
fi
echo "$$ $(pst $$) $(bid)" >"$S/lock/owner"
# a signal during the step ends it WITHOUT a done line: the C0-C3 trap removed the lock and then let the script
# continue after the killed sleep, so a SIGTERM (e.g. a 1 s-grace pod delete) completed the step at once and the
# next token reached only the dying agent (offline SIGTERM+1s regression, 2026-11-26)
trap 'rm -rf "$S/lock" 2>/dev/null' EXIT
trap 'exit 143' INT TERM HUP

last=$(tail -n 1 "$D/progress.log" 2>/dev/null | sed -n 's/^done n=\([0-9]*\) .*/\1/p')
last=${last:-0}
# .state holds only sha256(expected token): reading it cannot reveal the token.
exp_h=$(cat "$S/next-token.sha256" 2>/dev/null || printf %s start | sha256sum | cut -d' ' -f1)
[ "$N" -eq $((last + 1)) ] || refuse "expected-n=$((last + 1))"
[ "$(printf %s "$TOK" | sha256sum | cut -d' ' -f1)" = "$exp_h" ] || refuse wrong-token

prior=$(grep -c "^attempt n=$N " "$D/attempts.log" 2>/dev/null)
printf 'attempt n=%s t=%s prior_attempts=%s sleep=%s %s\n' "$N" "$(now)" "${prior:-0}" "$SLEEP" "$who" >>"$D/attempts.log"
sleep "$SLEEP"

new=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
prev=$(tail -n 1 "$D/ledger.log" 2>/dev/null | sha256sum | cut -c1-16)
t=$(now)
printf %s "$new" | sha256sum | cut -d' ' -f1 >"$S/next-token.sha256.tmp" && mv "$S/next-token.sha256.tmp" "$S/next-token.sha256"
printf 'done n=%s t=%s %s\n' "$N" "$t" "$who" >>"$D/progress.log"
printf 'n=%s t=%s tokhash=%s prev=%s\n' "$N" "$t" "$(printf %s "$new" | sha256sum | cut -c1-16)" "$prev" >>"$D/ledger.log"
if [ "$N" -lt "$MAX" ]; then
  echo "STEP $N OK. NEXT: ./step.sh $((N + 1)) $new"
else
  echo "STEP $N OK. ALL $MAX STEPS DONE."
fi
