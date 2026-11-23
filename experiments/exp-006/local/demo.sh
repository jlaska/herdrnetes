#!/usr/bin/env bash
# EXP-006 local prototype: a process owned by tmux (dedicated socket) runs
# independently of Herdr; Herdr panes are disposable `tmux attach` clients.
#
#   experiments/exp-006/local/demo.sh [run-id]
#
# Everything runs in a disposable Herdr 0.9.5 (own XDG dirs/socket) and a
# tmux server on its own socket, both under /tmp/hx6/<run-id>. Nothing here
# addresses the operator's live Herdr or default tmux server. No git/GPG/SSH.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
RUN=${1:-$(date +%m%d-%H%M%S)}
SCRATCH=/tmp/hx6
ROOT=$SCRATCH/$RUN
HERDR_BIN=${HERDR_BIN:-$(command -v herdr)}
EVID=$HERE/evidence/$RUN
SOCK=$ROOT/tmux.sock
OUT=$ROOT/out # counter identity + log (written by the counter itself)
PANES=$ROOT/panes
SNAPS=$ROOT/snaps
RESULTS=$ROOT/results.tsv

if [ -e "$ROOT" ]; then echo "refusing to reuse existing $ROOT" >&2; exit 2; fi
if [ "${#ROOT}" -gt 60 ]; then echo "ROOT too long for sockets (sun_path)" >&2; exit 2; fi
mkdir -p "$ROOT"/{config/herdr,state,out,panes,snaps}
: >"$RESULTS"
TIMELINE=$ROOT/timeline.log

# ---------------------------------------------------------------- scrubbing
# Allowlisted environment for EVERYTHING we launch (herdr, tmux, counter,
# panes). No HERDR_*, no SSH_AUTH_SOCK, no TMUX, nothing from the controller.
cenv() {
  env -i "HOME=$HOME" "USER=${USER:-user}" "LOGNAME=${USER:-user}" "PATH=$PATH" \
    "LANG=C.UTF-8" "TERM=xterm-256color" "SHELL=/usr/bin/bash" \
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    "XDG_CONFIG_HOME=$ROOT/config" "XDG_STATE_HOME=$ROOT/state" "$@"
}
GUARD_OK=0
# Read-only herdr call, allowed before the guard has passed.
Hraw() { cenv "$HERDR_BIN" "$@"; }
# Every other herdr call: refuse unless the guard verified our socket.
H() {
  if [ "$GUARD_OK" != 1 ]; then echo "GUARD not verified; refusing herdr $*" >&2; return 99; fi
  Hraw "$@"
}
# tmux: always an explicit socket and no user config.
T() { cenv tmux -S "$SOCK" -f /dev/null "$@"; }

guard() {
  local sock
  GUARD_OK=0
  sock=$(Hraw session list --json 2>/dev/null | jq -r '.sessions[]|select(.default)|.socket_path')
  case "$sock" in
  "$ROOT"/*) GUARD_OK=1 ;;
  *) echo "GUARD: herdr socket '$sock' is outside $ROOT; aborting" >&2; return 1 ;;
  esac
}

# ------------------------------------------------------------------ helpers
log() { printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$*" | tee -a "$TIMELINE"; }

# wait_for <timeout-seconds> <cmd...>: poll every 0.1 s.
wait_for() {
  local t=$1 i
  shift
  for ((i = 0; i < t * 10; i++)); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

proc_start() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
alive_same() { [ "$(proc_start "$1")" = "$2" ] && [ -n "$2" ]; } # pid, starttime
gone() { # pid, starttime: gone, or the pid was recycled
  local s
  s=$(proc_start "$1")
  [ -z "$s" ] || [ "$s" != "$2" ]
}
idfield() { sed -n "s/^$1=//p" "$OUT/identity"; }
last_n() { grep ' COUNT n=' "$OUT/counter.log" | tail -1 | sed 's/.*n=//'; }
ack_line() { grep " ACK $1 pid=" "$OUT/counter.log" | tail -1; }
ackf() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; } # <line> <field>

PIDS=() # "label:pid:starttime" for every process we must verify gone at exit
track() { PIDS+=("$1:$2:$(proc_start "$2")"); }

record() { # record <id> <PASS|FAIL> <detail>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RESULTS"
  log "RESULT $1 $2 $3"
}

snap() { # process-tree snapshot with the requested ps columns
  local f=$SNAPS/$1.txt l=() e p
  for e in "${PIDS[@]}"; do p=${e#*:}; p=${p%%:*}; [ -d "/proc/$p" ] && l+=("$p"); done
  {
    echo "# $1 $(date -u +%FT%TZ)"
    if [ "${#l[@]}" -gt 0 ]; then ps -o pid,ppid,sid,lstart,cmd -p "$(IFS=,; echo "${l[*]}")"; fi
    echo "# children of tmux server $TMUX_PID"
    ps -o pid,ppid,sid,lstart,cmd --ppid "$TMUX_PID" 2>&1
    if [ -n "${HPID:-}" ] && [ -d "/proc/$HPID" ]; then
      echo "# children of herdr server $HPID"
      ps -o pid,ppid,sid,lstart,cmd --ppid "$HPID" 2>&1
    fi
    echo "# tmux clients: $(T list-clients -F '#{client_pid}' 2>/dev/null | tr '\n' ' ')"
  } >"$f"
}

clients() { T list-clients -F '#{client_pid}' 2>/dev/null | grep -c .; }
clients_eq() { [ "$(clients)" -eq "$1" ]; }
clients_ge() { [ "$(clients)" -ge "$1" ]; }

# ------------------------------------------------------------------ cleanup
cleanup() {
  local rc=$? e label pid st bad=0
  trap - EXIT INT TERM
  log "cleanup start (exit=$rc)"
  # 1) tmux via its own socket
  [ -S "$SOCK" ] && T kill-server 2>/dev/null
  # 2) disposable herdr via its own socket, only if the guard still holds
  if [ -n "${HPID:-}" ] && [ -d "/proc/$HPID" ]; then
    guard && H server stop >/dev/null 2>&1
    wait_for 8 bash -c "[ ! -d /proc/$HPID ]" || true
  fi
  # 3) fallback: only the recorded PIDs whose starttime still matches
  for e in "${PIDS[@]}"; do
    IFS=: read -r label pid st <<<"$e"
    if [ -d "/proc/$pid" ] && [ "$(proc_start "$pid")" = "$st" ]; then
      echo "fallback SIGTERM $label pid=$pid" | tee -a "$TIMELINE"
      kill "$pid" 2>/dev/null
    fi
  done
  sleep 0.5
  for e in "${PIDS[@]}"; do
    IFS=: read -r label pid st <<<"$e"
    if [ -d "/proc/$pid" ] && [ "$(proc_start "$pid")" = "$st" ]; then
      echo "fallback SIGKILL $label pid=$pid" | tee -a "$TIMELINE"
      kill -9 "$pid" 2>/dev/null
    fi
  done
  # 4) positively verify every recorded PID is gone
  wait_for 5 bash -c 'true'
  for e in "${PIDS[@]}"; do
    IFS=: read -r label pid st <<<"$e"
    if wait_for 5 gone "$pid" "$st"; then
      echo "verified gone: $label pid=$pid" >>"$ROOT/cleanup.txt"
    else
      echo "STILL ALIVE: $label pid=$pid" | tee -a "$ROOT/cleanup.txt"
      bad=1
    fi
  done
  # 5) sweep: nothing may still carry this run's XDG_CONFIG_HOME
  local p
  for p in /proc/[0-9]*; do
    if { tr '\0' '\n' <"$p/environ" | grep -qx "XDG_CONFIG_HOME=$ROOT/config"; } 2>/dev/null; then
      echo "STRAY process ${p#/proc/}: $(tr '\0' ' ' <"$p/cmdline")" | tee -a "$ROOT/cleanup.txt"
      bad=1
    fi
  done
  [ "$bad" = 0 ] && echo "cleanup verified: all recorded PIDs gone, no stray processes" | tee -a "$ROOT/cleanup.txt"
  collect_evidence
  [ "$bad" = 1 ] && [ "$rc" = 0 ] && rc=3
  exit "$rc"
}
trap cleanup EXIT INT TERM

collect_evidence() {
  mkdir -p "$EVID"
  {
    echo "run-id: $RUN"
    echo "date-utc: $(date -u +%FT%TZ)"
    echo "herdr: $(cenv "$HERDR_BIN" --version)"
    echo "tmux: $(cenv tmux -V)"
    echo "bash: ${BASH_VERSION}"
    echo "kernel: $(uname -sr)"
    echo "herdr sha256: $(sha256sum "$(readlink -f "$HERDR_BIN")" | cut -d' ' -f1)"
    echo "tmux sha256: $(sha256sum "$(readlink -f "$(command -v tmux)")" | cut -d' ' -f1)"
    echo "counter.sh sha256: $(sha256sum "$HERE/counter.sh" | cut -d' ' -f1)"
  } >"$ROOT/versions.txt"
  [ -f "$ROOT/cleanup.txt" ] || : >"$ROOT/cleanup.txt"
  local host
  host=$(hostname 2>/dev/null)
  rm -rf "$EVID"
  mkdir -p "$EVID"
  # Copy text evidence with $HOME -> ~, user and host names scrubbed. Env
  # dumps are never captured; server-env-keys.txt holds variable NAMES only.
  local f rel
  while IFS= read -r f; do
    rel=${f#"$ROOT"/}
    mkdir -p "$EVID/$(dirname "$rel")"
    sed -e "s#$HOME#~#g" -e "s#${USER:-user}#USER#g" ${host:+-e "s#$host#HOST#g"} "$f" >"$EVID/$rel"
  done < <(find "$ROOT" -type f \( -path "$ROOT/out/*" -o -path "$ROOT/panes/*" -o -path "$ROOT/snaps/*" \
    -o -name results.tsv -o -name timeline.log -o -name versions.txt -o -name cleanup.txt -o -name 'server-env-keys*.txt' \
    -o -name 'restored-*.txt' -o -name setup-lineage.txt -o -name 'herdr-server-tail-*.txt' \))
  echo "evidence: $EVID"
}

# --------------------------------------------------------- environment setup
# Deterministic pane shell (no distro profile, no hostname in the prompt).
cat >"$ROOT/config/herdr/config.toml" <<EOF
onboarding = false

[update]
version_check = false
manifest_check = false

[terminal]
default_shell = "$ROOT/pane-shell"
shell_mode = "non_login"
EOF
cat >"$ROOT/pane-shell" <<EOF
#!/bin/sh
exec /usr/bin/bash --noprofile --rcfile "$ROOT/pane-bashrc" -i "\$@"
EOF
chmod +x "$ROOT/pane-shell"
cat >"$ROOT/pane-bashrc" <<EOF
export HISTFILE=/dev/null
PS1='\$ '
unset PROMPT_COMMAND
EOF

for tool in "$HERDR_BIN" tmux jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done
guard || exit 2
log "run $RUN root=$ROOT herdr=$(cenv "$HERDR_BIN" --version) $(cenv tmux -V)"

# -------------------------------------------------------- start the "agent"
# Started from here, not from a Herdr pane. The tmux server daemonizes and is
# reparented away from this script; the counter is its child on a PTY it owns.
cenv tmux -S "$SOCK" -f /dev/null new-session -d -s agent -x 120 -y 30 "$HERE/counter.sh $OUT" || { echo "tmux failed to start" >&2; exit 2; }
T set-option -t agent status off # status line would print the hostname
wait_for 10 test -s "$OUT/identity" || { echo "counter did not start" >&2; exit 2; }
TMUX_PID=$(T display-message -p '#{pid}')
CPID=$(idfield pid)
CSTART=$(idfield start)
CNONCE=$(idfield nonce)
track tmux-server "$TMUX_PID"
track counter "$CPID"
if [ "$(proc_start "$CPID")" != "$CSTART" ]; then
  record SETUP FAIL "identity starttime ($CSTART) != /proc ($(proc_start "$CPID"))"
  exit 1
fi
tr '\0' '\n' <"/proc/$TMUX_PID/environ" | cut -d= -f1 | sort >"$ROOT/server-env-keys-tmux.txt"
if grep -qE '^(HERDR_|SSH_AUTH_SOCK|TMUX$|CLAUDE)' "$ROOT/server-env-keys-tmux.txt"; then
  record SETUP FAIL "controller variables leaked into tmux server"; exit 1
fi
log "tmux server pid=$TMUX_PID ppid=$(sed 's/.*) //' /proc/$TMUX_PID/stat | awk '{print $2}') sid=$(sed 's/.*) //' /proc/$TMUX_PID/stat | awk '{print $4}')"
log "counter pid=$CPID start=$CSTART nonce=$CNONCE (parent=$(sed 's/.*) //' /proc/$CPID/stat | awk '{print $2}'), tmux server=$TMUX_PID)"
{
  echo "controller (this script) pid=$$ ppid=$PPID"
  echo "tmux server pid=$TMUX_PID, its ppid=$(sed 's/.*) //' /proc/$TMUX_PID/stat | awk '{print $2}')"
  echo "counter pid=$CPID, its ppid=$(sed 's/.*) //' /proc/$CPID/stat | awk '{print $2}')"
} >"$ROOT/setup-lineage.txt"

# ------------------------------------------------------------ herdr server
HPID=
start_herdr() {
  # Headless server as a pod entrypoint would run it; own session/process group.
  # shellcheck disable=SC2046
  setsid env -i "HOME=$HOME" "USER=${USER:-user}" "PATH=$PATH" "LANG=C.UTF-8" "TERM=xterm-256color" \
    "SHELL=/usr/bin/bash" "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    "XDG_CONFIG_HOME=$ROOT/config" "XDG_STATE_HOME=$ROOT/state" \
    "$HERDR_BIN" server >>"$ROOT/herdr-stdout.log" 2>&1 </dev/null &
  HPID=$!
  wait_for 15 Hraw status server >/dev/null 2>&1 || { echo "herdr server did not start" >&2; return 1; }
  guard || return 1
  # $! must really be the server: exec chain setsid->env->herdr keeps the PID.
  tr '\0' ' ' <"/proc/$HPID/cmdline" | grep -q 'herdr.* server' || { echo "recorded PID $HPID is not herdr server" >&2; return 1; }
  tr '\0' '\n' <"/proc/$HPID/environ" | grep -qx "XDG_CONFIG_HOME=$ROOT/config" || { echo "PID $HPID is not our server" >&2; return 1; }
  track "herdr-server-$1" "$HPID"
  tr '\0' '\n' <"/proc/$HPID/environ" | cut -d= -f1 | sort >"$ROOT/server-env-keys-$1.txt"
  if grep -qE '^(HERDR_(SOCKET_PATH|SESSION|PANE_ID|ENV|TAB_ID|WORKSPACE_ID|BIN_PATH)$|SSH_AUTH_SOCK|TMUX$|CLAUDE)' "$ROOT/server-env-keys-$1.txt"; then
    echo "controller variables leaked into herdr server" >&2; return 1
  fi
  log "herdr server ($1) pid=$HPID start=$(proc_start "$HPID")"
}
stop_herdr_clean() {
  guard || return 1
  H server stop >/dev/null
}

# ------------------------------------------------------------- pane driver
pane_attach() { # pane_attach <label> -> sets PANE; opens a NEW pane running tmux attach
  local label=$1 plist base
  plist=$(H pane list | jq -r '.result.panes[].pane_id')
  if [ -z "$plist" ]; then
    PANE=$(H workspace create --cwd "$ROOT" --label demo --no-focus | jq -r '.result.root_pane.pane_id')
  else
    base=$(head -1 <<<"$plist")
    PANE=$(H pane split "$base" --direction right --cwd "$ROOT" --no-focus | jq -r '.result.pane.pane_id')
  fi
  [ -n "$PANE" ] && [ "$PANE" != null ] || { echo "could not create pane" >&2; return 1; }
  local want=$(($(clients) + 1))
  H pane run "$PANE" "tmux -S $SOCK -f /dev/null attach -t agent" >/dev/null
  wait_for 15 clients_ge "$want" || { echo "tmux client did not attach in $PANE" >&2; return 1; }
  log "pane $PANE ($label): tmux client attached (clients=$(clients))"
}

mark() { # mark <word>: type "mark <word>" in $PANE; wait for ACK in pane and log
  local w=$1
  H pane send-text "$PANE" "mark $w" >/dev/null
  H pane send-keys "$PANE" Enter >/dev/null
  wait_for 15 bash -c "grep -q ' ACK $w pid=' '$OUT/counter.log'" || return 1
  H pane wait-output "$PANE" --match "ACK $w pid=$CPID" --source visible --timeout 10000 >/dev/null || return 2
  H pane read "$PANE" --source visible --lines 40 >"$PANES/$w.txt" 2>&1
  return 0
}

# verify_ack <word> <min-n-exclusive> -> sets ACKN, returns 0 if pid/start/nonce match
verify_ack() {
  local line pid start nonce
  line=$(ack_line "$1")
  pid=$(ackf "$line" pid)
  start=$(ackf "$line" start)
  nonce=$(ackf "$line" nonce)
  ACKN=$(ackf "$line" n)
  [ "$pid" = "$CPID" ] && [ "$start" = "$CSTART" ] && [ "$nonce" = "$CNONCE" ] && [ "${ACKN:-0}" -gt "$2" ] &&
    grep -q "ACK $1 pid=$CPID start=$CSTART nonce=$CNONCE" "$PANES/$1.txt"
}

counter_unchanged() { alive_same "$CPID" "$CSTART" && [ "$(idfield nonce)" = "$CNONCE" ] && [ "$(idfield pid)" = "$CPID" ]; }
counter_past() { [ "$(last_n)" -ge "$1" ]; }

# ------------------------------------------------------------------- tests
start_herdr initial || { record SETUP FAIL "herdr start"; exit 1; }
snap 00-initial

# T1 -----------------------------------------------------------------------
if pane_attach t1 && mark t1; then
  N1=$(last_n)
  if verify_ack t1 0; then
    record T1-attach PASS "ACK in log and pane read: pid=$CPID start=$CSTART nonce=$CNONCE n=$ACKN"
  else
    record T1-attach FAIL "ACK identity mismatch: $(ack_line t1)"
  fi
else
  record T1-attach FAIL "could not attach or ACK did not appear"
fi
snap 01-attached
P_T1=$PANE

# T2 -----------------------------------------------------------------------
N_DISC=$(last_n)
T_DISC=$(date +%s.%N)
H pane close "$P_T1" >/dev/null
# the tmux client dies via SIGHUP on PTY close (not via a tmux detach command)
CL_GONE=no
wait_for 10 clients_eq 0 && CL_GONE=yes
wait_for 15 counter_past $((N_DISC + 5)) # ~5 s with no client attached
GAP=$(awk -v t="$T_DISC" '$1 > t && /COUNT/' "$OUT/counter.log" | wc -l)
FIRST_GAP=$(awk -v t="$T_DISC" '$1 > t && /COUNT/ {print $1; exit}' "$OUT/counter.log")
LAST_GAP=$(grep ' COUNT ' "$OUT/counter.log" | tail -1 | cut -d' ' -f1)
SPAN=$(awk -v a="$FIRST_GAP" -v b="$LAST_GAP" 'BEGIN{printf "%.1f", b-a}')
snap 02-disconnected
if [ "$CL_GONE" = yes ] && counter_unchanged && [ "$GAP" -ge 5 ]; then
  record T2-disconnect PASS "pane closed, clients=0, counter pid=$CPID start=$CSTART nonce=$CNONCE unchanged; n at disconnect=$N_DISC, now $(last_n), $GAP counter lines over ${SPAN}s with no client"
else
  record T2-disconnect FAIL "clients_gone=$CL_GONE unchanged=$(counter_unchanged && echo y || echo n) gap_lines=$GAP"
fi

# T3 -----------------------------------------------------------------------
if pane_attach t3 && mark t3; then
  if verify_ack t3 "$N_DISC"; then
    record T3-reconnect PASS "ACK pid=$CPID start=$CSTART nonce=$CNONCE n=$ACKN (> n at disconnect $N_DISC)"
  else
    record T3-reconnect FAIL "identity/n mismatch: $(ack_line t3) (n at disconnect $N_DISC)"
  fi
else
  record T3-reconnect FAIL "could not attach or ACK did not appear"
fi
snap 03-reconnected

# T4: restart tests (a = clean stop, b = SIGKILL) ---------------------------
restart_test() { # restart_test <id> <clean|kill>
  local id=$1 mode=$2 label n_stop old_hpid hstart_old
  label=T${id}
  # a pane attached right now (the T3 pane for T4a; the T4a pane for T4b)
  [ "$(clients)" -ge 1 ] || pane_attach "$label-pre"
  local npre
  npre=$(clients)
  n_stop=$(last_n)
  old_hpid=$HPID
  hstart_old=$(proc_start "$old_hpid")
  snap "04$id-before-restart"
  H pane list | jq -c '[.result.panes[].pane_id]' >"$ROOT/restored-$id-before.txt"
  if [ "$mode" = clean ]; then
    stop_herdr_clean || { record "$label" FAIL "server stop failed"; return; }
  else
    # SIGKILL exactly the recorded PID, after re-verifying it is ours.
    tr '\0' '\n' <"/proc/$old_hpid/environ" | grep -qx "XDG_CONFIG_HOME=$ROOT/config" &&
      [ "$(proc_start "$old_hpid")" = "$hstart_old" ] || { record "$label" FAIL "refusing to kill unverified pid $old_hpid"; return; }
    kill -9 "$old_hpid"
  fi
  GUARD_OK=0
  local gone_ok=no
  wait_for 10 gone "$old_hpid" "$hstart_old" && gone_ok=yes
  # With the server gone the PTY masters are closed -> client must be gone.
  local cl_gone=no
  wait_for 10 clients_eq 0 && cl_gone=yes
  # counter must keep progressing without Herdr and without any client
  local keep=no
  wait_for 15 counter_past $((n_stop + 3)) && keep=yes
  local n_down
  n_down=$(last_n)
  snap "04$id-herdr-down"
  local unchanged=no
  counter_unchanged && unchanged=yes

  start_herdr "restart-$id" || { record "$label" FAIL "herdr did not restart"; return; }
  snap "04$id-herdr-restarted"
  # What did Herdr restore? (panes exist as plain shells? any tmux client back?)
  {
    echo "pane ids before stop: $(cat "$ROOT/restored-$id-before.txt")"
    echo "tmux clients after herdr restart (before new pane): $(clients)"
    H pane list | jq -r '.result.panes[]|.pane_id' | while read -r rp; do
      echo "--- restored pane $rp process-info:"
      H pane process-info --pane "$rp" | jq -c '.result.process_info|{shell_pid,fg:[.foreground_processes[]|.cmdline]}'
      echo "--- restored pane $rp visible text (non-empty lines):"
      H pane read "$rp" --source visible --lines 40 | grep -v '^$' | head -8
    done
  } >"$ROOT/restored-$id.txt" 2>&1
  local rclients
  rclients=$(clients)

  local acked=no
  pane_attach "$label" && mark "t$id" && acked=yes
  local acki=no
  [ "$acked" = yes ] && verify_ack "t$id" "$n_stop" && acki=yes
  snap "04$id-reattached"
  if [ "$gone_ok" = yes ] && [ "$cl_gone" = yes ] && [ "$unchanged" = yes ] && [ "$keep" = yes ] && [ "$acki" = yes ]; then
    record "$label" PASS "$mode: old server pid $old_hpid gone, clients dropped to 0 (was $npre), counter unchanged and advanced n=$n_stop->$n_down while Herdr down; after restart (new server pid $HPID, restored-pane tmux clients=$rclients) new pane ACK pid=$CPID start=$CSTART nonce=$CNONCE n=$ACKN"
  else
    record "$label" FAIL "$mode: server_gone=$gone_ok clients_dropped=$cl_gone unchanged=$unchanged progressed=$keep ack_ok=$acki"
  fi
}

restart_test 4a clean
restart_test 4b kill

# ------------------------------------------------------------------ summary
echo
printf '%-18s %-5s %s\n' TEST RESULT DETAIL
FAILS=0
while IFS=$'\t' read -r id res detail; do
  printf '%-18s %-5s %s\n' "$id" "$res" "$detail"
  [ "$res" = PASS ] || FAILS=$((FAILS + 1))
done <"$RESULTS"
echo
echo "identity: pid=$CPID start=$CSTART nonce=$CNONCE  tmux-server=$TMUX_PID"
if [ "$FAILS" -gt 0 ]; then
  [ -n "${HPID:-}" ] && tail -n 30 "$ROOT/herdr-stdout.log" >"$ROOT/herdr-server-tail-fail.txt" 2>/dev/null
  echo "OVERALL: FAIL ($FAILS)"
  exit 1
fi
echo "OVERALL: PASS"
exit 0
