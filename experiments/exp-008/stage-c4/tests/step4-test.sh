#!/usr/bin/env bash
# Offline test of stage-c4/task/step.sh: the token chain and refusals (unchanged from C0-C3), the recorded 45 s
# pacing, and the C4 stale-lock rules (empty start time, other boot, dead owner, a new PID namespace).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
D=$T/repo; mkdir -p "$D"; install -m 0755 "$HERE/task/step.sh" "$D/step.sh"
st() { (cd "$D" && STEP_SLEEP=${SL:-0} ./step.sh "$@"); }
next() { sed -n 's/.*NEXT: .\/step.sh [0-9]* //p' <<<"$1"; }

grep -q '^SLEEP=${STEP_SLEEP:-45}$' "$HERE/task/step.sh" && ok "default sleep is 45 s" || no "default sleep"
o=$(st 1 start); t2=$(next "$o"); [ -n "$t2" ] && ok "step 1 accepted, token printed" || no "step 1: $o"
grep -q '^attempt n=1 .* sleep=0 ' "$D/attempts.log" && ok "attempt line records sleep=" || no "sleep not recorded"
o=$(st 1 start); [[ $o == REFUSED:* ]] && grep -q 'reason=expected-n=2' "$D/refusals.log" && ok "repeated step refused (expected-n)" || no "repeat not refused"
o=$(st 3 "$t2"); [[ $o == REFUSED:* ]] && ok "skip refused" || no "skip accepted"
o=$(st 2 deadbeef0000); [[ $o == REFUSED:* ]] && grep -q 'reason=wrong-token' "$D/refusals.log" && ok "wrong token refused" || no "wrong token accepted"
o=$(st 2 "$t2"); t3=$(next "$o"); [ -n "$t3" ] && ok "step 2 accepted with the chained token" || no "step 2: $o"
[ "$(grep -c '^attempt n=2 ' "$D/attempts.log")" = 1 ] && ok "refused calls leave no attempt line" || no "attempt lines"
python3 -I "$HERE/../stage-c/metrics.py" ledger "$D" | grep -q '"chain_ok": true' && ok "ledger chain verifies (C0-C3 checker)" || no "ledger chain"

# a SIGTERM during the sleep ends the step without done, token rotation or ledger line (the 1 s-grace kill case)
cp "$D"/*.log "$T/" ; tokh=$(cat "$D/.state/next-token.sha256")
( cd "$D" && STEP_SLEEP=30 exec ./step.sh 3 "$t3" >/dev/null 2>&1 ) & sp=$!
for _ in $(seq 1 50); do grep -q '^attempt n=3 ' "$D/attempts.log" && break; sleep 0.1; done; sleep 0.3
pkill -TERM -P "$sp" sleep 2>/dev/null; kill -TERM "$sp" 2>/dev/null; wait "$sp"; rc=$?
[ "$rc" = 143 ] && ! grep -q '^done n=3 ' "$D/progress.log" && [ "$(cat "$D/.state/next-token.sha256")" = "$tokh" ] && cmp -s "$T/ledger.log" "$D/ledger.log" && [ ! -d "$D/.state/lock" ] \
  && ok "SIGTERM during the sleep: exit 143, no done, token and ledger unchanged, lock released" || no "SIGTERM: rc=$rc done3=$(grep -c '^done n=3 ' "$D/progress.log") tok_same=$([ "$(cat "$D/.state/next-token.sha256")" = "$tokh" ] && echo y || echo n)"
cp "$T/attempts.log" "$D/attempts.log"  # restore the pre-attempt state for the lock cases below
S=$D/.state; boot=$(cat /proc/sys/kernel/random/boot_id)
lockcase() { # lockcase <name> <owner line> <expect busy|broken>
  rm -rf "$S/lock"; mkdir -p "$S/lock"; printf '%s\n' "$2" >"$S/lock/owner"; touch -d '1 hour ago' "$S/lock"
  local before; before=$(grep -c . "$D/locks.log" 2>/dev/null || true)
  o=$(st 3 "$t3")
  if [ "$3" = busy ]; then [[ $o == "REFUSED: busy" ]] && ok "$1: busy" || no "$1: expected busy, got: ${o:0:40}"
  else
    [[ $o == "STEP 3 OK."* ]] && [ "$(grep -c . "$D/locks.log")" -gt "${before:-0}" ] && ok "$1: stale lock broken and logged" || no "$1: expected break, got: ${o:0:40}"
    t3=$(next "$o"); rm -f "$D"/progress.log.bak
    # roll the chain back one step so the next case can run step 3 again: rebuild from a copy taken earlier
    cp "$T/snap/"* "$D/" 2>/dev/null; cp "$T/snap/.state/next-token.sha256" "$S/" 2>/dev/null; t3=$(cat "$T/snap/t3")
  fi
}
mkdir -p "$T/snap/.state"; cp "$D"/*.log "$T/snap/"; cp "$S/next-token.sha256" "$T/snap/.state/"; echo "$t3" >"$T/snap/t3"
sleep 60 & live=$!; lst=$(sed 's/.*) //' "/proc/$live/stat" | awk '{print $20}')
lockcase "live owner (pid, start, boot match)" "$live $lst $boot" busy
lockcase "owner with an empty start time (torn write)" "$live" broken
lockcase "owner from another boot" "$live $lst 00000000-0000-0000-0000-000000000000" broken
lockcase "dead owner pid" "999999 12345 $boot" broken
lockcase "pid reused with another start time" "$live 1 $boot" broken
kill "$live" 2>/dev/null
grep -q 'owner_start=none owner_boot=none' "$D/locks.log" && grep -q "boot=$boot" "$D/locks.log" && ok "locks.log records owner start/boot and the current boot" || no "locks.log fields"

# a lock left by a process in another PID namespace (the killed pod's step) is broken by a new namespace's step
if unshare -rpf --mount-proc true 2>/dev/null; then
  rm -rf "$S/lock"; cp "$T/snap/"*.log "$D/"; cp "$T/snap/.state/next-token.sha256" "$S/"
  unshare -rpf --mount-proc sh -c "cd '$D' && (STEP_SLEEP=30 ./step.sh 3 $t3 >/dev/null 2>&1 &) ; sleep 1; kill -9 -1 2>/dev/null; true"
  [ -d "$S/lock" ] && grep -q "^attempt n=3 " "$D/attempts.log" && ok "pid-namespace run left a held lock and an attempt without done (simulated pod loss)" || no "setup: no stale lock from the killed namespace"
  o=$(unshare -rpf --mount-proc sh -c "cd '$D' && STEP_SLEEP=0 ./step.sh 3 $t3")
  [[ $o == "STEP 3 OK."* ]] && ok "a step in a new PID namespace breaks the stale lock and re-runs the in-flight step" || no "new namespace: ${o:0:60}"
  grep -q '^attempt n=3 .*prior_attempts=1 ' "$D/attempts.log" && ok "the re-attempt records prior_attempts=1" || no "prior_attempts not 1"
else
  echo "NOT RUN - unprivileged PID namespaces unavailable (pid-namespace lock case)"
fi
echo "failures=$fails"; [ "$fails" = 0 ]
