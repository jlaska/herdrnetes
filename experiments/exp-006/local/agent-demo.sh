#!/usr/bin/env bash
# EXP-006 stage 3: a REAL Claude Code session owned by tmux (dedicated socket)
# keeps working while Herdr panes (disposable `tmux attach` clients) and the
# disposable Herdr server come and go. See STAGE3.md. NOT RUN yet.
#
#   EXP006_KEY_FILE=<path> experiments/exp-006/local/agent-demo.sh [run-id]
#
# Everything lives under /tmp/hx6a/<run-id>: disposable Herdr 0.9.5 (own XDG
# dirs/socket), a tmux server on its own socket, the agent's own HOME and a
# throwaway git repo. The API key file is never read by this script except by
# the final leak scan; claude reads it through apiKeyHelper. No git push/GPG/SSH.
# shellcheck disable=SC2329 # wait_for and the exit trap call these functions indirectly
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
RUN=${1:-$(date +%m%d-%H%M%S)}
SCRATCH=/tmp/hx6a
ROOT=$SCRATCH/$RUN
HERDR_BIN=${HERDR_BIN:-$(command -v herdr)}
EVID=$HERE/evidence/agent-$RUN
SOCK=$ROOT/tmux.sock
PANES=$ROOT/panes
SNAPS=$ROOT/snaps
RESULTS=$ROOT/results.tsv
AHOME=$ROOT/home # the agent's HOME, config and transcripts
CCD=$AHOME/.claude
REPO=$ROOT/repo # the agent's working directory
PLOG=$REPO/progress.log # appended by check.py, not by the agent
AGENT_PATH=/usr/local/bin:/usr/bin:/bin
MODEL=${EXP006_MODEL:-claude-sonnet-5-5}
EFFORT=${EXP006_EFFORT:-medium}
WANT_VER=${EXP006_CLAUDE_VERSION:-2.1.323 (Claude Code)}
MAX_SECONDS=${EXP006_MAX_SECONDS:-1500}
# The interactive shell has a `claude` function; resolve the binary without it.
CLAUDE_BIN=${CLAUDE_BIN:-$(readlink -f "$(env -i PATH="$PATH" sh -c 'command -v claude')")}
SID=$(cat /proc/sys/kernel/random/uuid) # fresh session id; never --resume/--continue
CODE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n') # 12 hex chars: memory, P1 and evidence only
DIALOG_RX='log ?in|sign ?in|api key|trust|onboarding|theme|select|choose'
PROMPT_RX='\? for shortcuts|^( |│)*(>|❯)'
RESUME_RX='(^| )(--resume|--continue|-r|-c)( |$)'
# Prompts: single line, ASCII. Only P1 carries the codeword.
P1_T='Session codeword is @CODE@. Do not write it to any file. Task: in kata.py implement f01, f02, f03, f04 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f04 passes, reply with exactly: DONE-A @CODE@'
PB='Task: in kata.py implement f05, f06, f07, f08 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f08 passes, reply with exactly: DONE-B'
PC='Task: in kata.py implement f09, f10, f11, f12 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f12 passes, reply with exactly: DONE-C'
Q_T='Reply with exactly one line: Q@K@ CODEWORD=<the session codeword from my first message> DONE=<number of functions passing per your last check>'
P1=${P1_T//@CODE@/$CODE}

die() { echo "$*" >&2; exit 2; }
[[ $RUN =~ ^[A-Za-z0-9-]+$ ]] || die "run-id must match [A-Za-z0-9-]+"
[ -e "$ROOT" ] && die "refusing to reuse existing $ROOT"
[ -e "$EVID" ] && die "refusing to reuse existing evidence dir $EVID"
[ "${#ROOT}" -gt 60 ] && die "ROOT too long for sockets (sun_path)"

# ------------------------------------------------------------ preconditions
# The key file: only its path and metadata are inspected here.
[ -n "${EXP006_KEY_FILE:-}" ] || die "EXP006_KEY_FILE is not set"
KF=$(readlink -f "$EXP006_KEY_FILE")
[[ $KF =~ ^/[A-Za-z0-9_./-]+$ ]] || die "key file path must be absolute, only [A-Za-z0-9_./-]"
{ [ -f "$KF" ] && [ -s "$KF" ] && [ -r "$KF" ] && [ -O "$KF" ]; } || die "key file must be a non-empty regular file you own"
case $(stat -c %a "$KF") in 600 | 400) ;; *) die "key file mode must be 0600 or 0400" ;; esac
TOP=$(git -C "$HERE" rev-parse --show-toplevel) || die "not inside a git repo"
case "$KF" in "$TOP"/* | "$ROOT"/*) die "key file must not be inside the git repo or the run root" ;; esac

for tool in "$HERDR_BIN" tmux jq git python3 pgrep; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[ -x "$CLAUDE_BIN" ] || die "claude binary not found"
CLAUDE_VER=$(env -i PATH="$PATH" HOME=/nonexistent "$CLAUDE_BIN" --version 2>&1)
[ "$CLAUDE_VER" = "$WANT_VER" ] || die "claude version '$CLAUDE_VER' != '$WANT_VER'"
CLAUDE_SHA=$(sha256sum "$CLAUDE_BIN" | cut -d' ' -f1)
[ -d "$HERE/agent-task/repo" ] || die "missing $HERE/agent-task/repo"

mkdir -p "$ROOT"/{config/herdr,state,panes,snaps,tmp} "$AHOME" "$ROOT"/agent-xdg/{config,state,cache,data,run}
chmod 700 "$AHOME" "$ROOT/agent-xdg/run"
: >"$RESULTS"
TIMELINE=$ROOT/timeline.log
APID=
ASTART=
AWHO=
WD=
WDS=
CHECK_SHA=
README_SHA=
AGENT_BAD= # accumulated violations of the one-process / no-resume invariants
TJ=

# ---------------------------------------------------------------- scrubbing
# Allowlisted environment for EVERYTHING we launch (herdr, tmux, panes). No
# HERDR_*, no SSH_AUTH_SOCK, no TMUX, nothing from the controller. The agent
# itself gets its own, even smaller environment (see AGENT_CMD below).
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
# git for the agent repo: no global/system config, fixed identity, no signing.
AG() {
  cenv GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$REPO" \
    -c user.name=exp006 -c user.email=exp006@invalid -c commit.gpgsign=false "$@"
}

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

# wait_for <timeout-seconds> <cmd...>: poll every 0.1 s. Gives up at once if
# the wall-clock watchdog fired.
wait_for() {
  local t=$1 i
  shift
  for ((i = 0; i < t * 10; i++)); do
    "$@" && return 0
    [ -e "$ROOT/overrun" ] && return 1
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

PIDS=() # "label:pid:starttime" for every process we must verify gone at exit
track() { # never store an empty starttime: cleanup would treat it as a match
  local st
  st=$(proc_start "$2")
  if [ -z "$st" ]; then echo "TRACK FAIL: $1 pid=$2 has no starttime" | tee -a "$ROOT/cleanup.txt"; return 1; fi
  PIDS+=("$1:$2:$st")
}

record() { # record <id> <PASS|FAIL> <detail>; a PASS is downgraded once files-bad.txt is non-empty
  local id=$1 res=$2 detail=$3
  if [ "$res" = PASS ] && [ -s "$ROOT/files-bad.txt" ]; then
    res=FAIL
    detail="$detail; INTEGRITY: $(tr '\n' ' ' <"$ROOT/files-bad.txt")"
  fi
  printf '%s\t%s\t%s\n' "$id" "$res" "$detail" >>"$RESULTS"
  log "RESULT $id $res $detail"
}

# Processes whose environ has HOME=$AHOME and whose exe is the claude binary.
agent_count() {
  local p n=0
  for p in /proc/[0-9]*; do
    [ "$(readlink "$p/exe" 2>/dev/null)" = "$CLAUDE_BIN" ] || continue
    { tr '\0' '\n' <"$p/environ" | grep -qx "HOME=$AHOME"; } 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}
agent_unchanged() { alive_same "$APID" "$ASTART" && [ "$(readlink "/proc/$APID/exe" 2>/dev/null)" = "$CLAUDE_BIN" ]; }

snap() { # process-tree snapshot with the requested ps columns
  local f=$SNAPS/$1.txt l=() e p ac
  for e in "${PIDS[@]}"; do p=${e#*:}; p=${p%%:*}; [ -d "/proc/$p" ] && l+=("$p"); done
  ac=$(agent_count)
  [ "$ac" = 1 ] || AGENT_BAD+="snap $1: $ac agent processes; "
  if [ -n "$APID" ] && tr '\0' ' ' <"/proc/$APID/cmdline" 2>/dev/null | grep -qE -- "$RESUME_RX"; then
    AGENT_BAD+="snap $1: cmdline has --resume/--continue; "
  fi
  {
    echo "# $1 $(date -u +%FT%TZ)"
    echo "# agent processes (HOME=$AHOME, exe=claude): $ac"
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

# progress.log is written by check.py (the tool the agent runs): "<epoch> check k/12 passing=..."
prog_lines() { local n; n=$(awk 'END{print NR}' "$PLOG" 2>/dev/null); echo "${n:-0}"; }
prog_after() { awk -v t="$1" '$1 > t' "$PLOG" 2>/dev/null | wc -l; }
progress_past() { [ "$(prog_lines)" -gt "$1" ]; }
advanced() { [ "$(npass)" -gt "$1" ] && [ "$(prog_after "$2")" -ge 1 ]; } # count at stop, time of stop
# check.py/README.md must stay as copied and every progress.log line must have check.py's format.
PLOG_RX='^[0-9]+\.[0-9]+ check [0-9]+/12 passing=(f[0-9]{2}(,f[0-9]{2})*)?$'
note_bad() { grep -qxF "$1" "$ROOT/files-bad.txt" 2>/dev/null || echo "$1" >>"$ROOT/files-bad.txt"; }
files_ok() {
  [ "$(sha256sum "$REPO/check.py" | cut -d' ' -f1)" = "$CHECK_SHA" ] || note_bad "check.py changed"
  [ "$(sha256sum "$REPO/README.md" | cut -d' ' -f1)" = "$README_SHA" ] || note_bad "README.md changed"
  if [ -f "$PLOG" ] && grep -qvE "$PLOG_RX" "$PLOG"; then note_bad "progress.log has a line not in check.py format"; fi
}
# check.py run by the harness: 20 s cap, minimal env, never logs; stderr is the caller's to route.
agent_check() {
  (cd "$REPO" && timeout -k 2 20 env -i "HOME=$AHOME" "PATH=$AGENT_PATH" LANG=C.UTF-8 "TMPDIR=$ROOT/tmp" PYTHONDONTWRITEBYTECODE=1 python3 check.py --nolog)
}
# Passing count measured by the harness itself; a timeout counts as 0 and is logged.
npass() {
  local out rc n
  files_ok
  out=$(agent_check 2>/dev/null)
  rc=$?
  [ "$rc" = 124 ] && echo "$(date +%H:%M:%S.%3N) npass: check.py timed out after 20 s, counted as 0" >>"$TIMELINE"
  n=$(sed -n 's|^TOTAL \([0-9]*\)/12$|\1|p' <<<"$out" | tail -1)
  echo "${n:-0}"
}

# Transcript: exactly one *.jsonl under $CCD/projects, and it is $SID.jsonl.
tj_rec() { { date +%T; find "$CCD/projects" -name '*.jsonl' 2>/dev/null; } >>"$ROOT/transcript-files.txt"; }
tj_ok() {
  local l
  l=$(find "$CCD/projects" -name '*.jsonl' 2>/dev/null)
  [ "$(grep -c . <<<"$l")" = 1 ] && [[ $l == */"$SID.jsonl" ]] && TJ=$l
}
JQEP='def ep: (sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) + (((try (capture("\\.(?<f>[0-9]+)Z$")|.f)) // "0")|("0."+.)|tonumber);'
atext() { tj_ok && jq -r 'select(.type=="assistant")|.message.content|arrays|.[]|select(.type=="text")|.text' "$TJ" 2>/dev/null; }
said() { atext | grep -qE "$1"; } # assistant text (never the user's) matches
tj_rows() { # one line per entry: epoch type tool_use-count
  tj_ok && jq -r "$JQEP"' select(.timestamp != null)|[(.timestamp|ep), .type, ([.message.content?|arrays|.[]|select(.type=="tool_use")]|length)]|@tsv' "$TJ" 2>/dev/null
}

# Everything that must be taken from the repo/transcript before $ROOT goes away.
final_artifacts() {
  [ -d "$REPO" ] || return 0
  { echo "# python3 check.py --nolog (harness, after the agent was stopped)"; agent_check; echo "# exit=$?"; } >"$ROOT/final-check.txt" 2>&1
  cp "$PLOG" "$ROOT/progress.log" 2>/dev/null
  cp "$REPO/kata.py" "$ROOT/kata-final.py"
  AG diff -- kata.py >"$ROOT/kata.diff" 2>&1
  sed "s#$KF#<key-file>#g" "$ROOT/settings.json" >"$ROOT/settings-evidence.json" # path only, never the key
  tj_ok || return 0
  jq -c '{timestamp, type, role: (.message.role? // null),
    tools: [.message.content?|arrays|.[]|select(.type=="tool_use")|.name],
    text: ((if (.message.content?|type) == "string" then .message.content
            else ([.message.content?|arrays|.[]|select(.type=="text")|.text]|join(" ")) end) // "" | .[0:300])}' "$TJ" >"$ROOT/transcript-summary.jsonl" 2>/dev/null
  # one usage record per message id (streamed entries repeat it); sums only, no prices
  jq -rs '[.[]|select(.type=="assistant" and ((.message.usage?|type) == "object"))]|group_by(.message.id)|map(last) as $m
    | "assistant_messages=\($m|length)",
      "input_tokens=\([$m[].message.usage.input_tokens // 0]|add // 0)",
      "output_tokens=\([$m[].message.usage.output_tokens // 0]|add // 0)",
      "cache_creation_input_tokens=\([$m[].message.usage.cache_creation_input_tokens // 0]|add // 0)",
      "cache_read_input_tokens=\([$m[].message.usage.cache_read_input_tokens // 0]|add // 0)"' "$TJ" >"$ROOT/usage.txt" 2>&1
}

collect_evidence() {
  final_artifacts
  {
    echo "run-id: $RUN"
    echo "date-utc: $(date -u +%FT%TZ)"
    echo "claude: $CLAUDE_VER"
    echo "claude sha256: $CLAUDE_SHA"
    echo "model: $MODEL"
    echo "effort: $EFFORT"
    echo "session-id: $SID"
    echo "codeword: $CODE"
    echo "herdr: $(cenv "$HERDR_BIN" --version)"
    echo "tmux: $(cenv tmux -V)"
    echo "bash: ${BASH_VERSION}"
    echo "kernel: $(uname -sr)"
    echo "herdr sha256: $(sha256sum "$(readlink -f "$HERDR_BIN")" | cut -d' ' -f1)"
    echo "tmux sha256: $(sha256sum "$(readlink -f "$(command -v tmux)")" | cut -d' ' -f1)"
    echo "agent-demo.sh sha256: $(sha256sum "$HERE/agent-demo.sh" | cut -d' ' -f1)"
    echo "task template sha256:"
    (cd "$HERE/agent-task" && sha256sum repo/kata.py repo/check.py repo/README.md)
    echo "P1: $P1"
    echo "PB: $PB"
    echo "PC: $PC"
    echo "Q: $Q_T"
  } >"$ROOT/versions.txt"
  [ -f "$ROOT/cleanup.txt" ] || : >"$ROOT/cleanup.txt"
  local host
  host=$(hostname 2>/dev/null)
  rm -rf "$EVID"
  mkdir -p "$EVID"
  # Copy text evidence with $HOME -> ~, user and host names scrubbed. Env
  # dumps are never captured; env-keys-*.txt hold variable NAMES only.
  local f rel
  while IFS= read -r f; do
    rel=${f#"$ROOT"/}
    mkdir -p "$EVID/$(dirname "$rel")"
    sed -e "s#$HOME#~#g" -e "s#${USER:-user}#USER#g" ${host:+-e "s#$host#HOST#g"} "$f" >"$EVID/$rel"
  done < <(find "$ROOT" -type f \( -path "$ROOT/panes/*" -o -path "$ROOT/snaps/*" \
    -o -name results.tsv -o -name timeline.log -o -name versions.txt -o -name cleanup.txt -o -name 'env-keys-*.txt' \
    -o -name 'server-env-keys*.txt' -o -name 'restored-*.txt' -o -name setup-lineage.txt -o -name 'herdr-server-tail-*.txt' \
    -o -name progress.log -o -name final-check.txt -o -name kata-final.py -o -name kata.diff -o -name settings-evidence.json \
    -o -name transcript-summary.jsonl -o -name usage.txt -o -name transcript-files.txt -o -name files-bad.txt \) -not -path "$REPO/*")
  echo "evidence: $EVID"
}

# ------------------------------------------------------------------ cleanup
cleanup() {
  local rc=$? e label pid st bad=0 p
  trap - EXIT INT TERM
  [ -n "${WDS:-}" ] && alive_same "$WD" "$WDS" && kill "$WD" 2>/dev/null
  rm -f "$ROOT/overrun" # so the waits below work
  log "cleanup start (exit=$rc)"
  # 1) tmux via its own socket (this ends claude)
  [ -S "$SOCK" ] && T kill-server 2>/dev/null
  # 2) disposable herdr via its own socket, only if the guard still holds
  if [ -n "${HPID:-}" ] && [ -d "/proc/$HPID" ]; then
    guard && H server stop >/dev/null 2>&1
    wait_for 8 bash -c "[ ! -d /proc/$HPID ]" || true
  fi
  # 3) fallback: only the recorded PIDs whose starttime still matches
  for e in "${PIDS[@]}"; do
    IFS=: read -r label pid st <<<"$e"
    if alive_same "$pid" "$st"; then
      echo "fallback SIGTERM $label pid=$pid" | tee -a "$TIMELINE"
      kill "$pid" 2>/dev/null
    fi
  done
  sleep 0.5
  for e in "${PIDS[@]}"; do
    IFS=: read -r label pid st <<<"$e"
    if alive_same "$pid" "$st"; then
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
  # 5) sweep: nothing may still carry this run's XDG_CONFIG_HOME or the agent HOME
  for p in /proc/[0-9]*; do
    if { tr '\0' '\n' <"$p/environ" | grep -qxF -e "XDG_CONFIG_HOME=$ROOT/config" -e "HOME=$AHOME"; } 2>/dev/null; then
      echo "STRAY process ${p#/proc/}: $(tr '\0' ' ' <"$p/cmdline")" | tee -a "$ROOT/cleanup.txt"
      bad=1
    fi
  done
  [ "$bad" = 0 ] && echo "cleanup verified: all recorded PIDs gone, no stray processes" | tee -a "$ROOT/cleanup.txt"
  collect_evidence
  # 6) key leak scan over the evidence (the key is read here, never echoed)
  if grep -rqF -f "$KF" "$EVID" 2>/dev/null || grep -rqE 'sk-ant-[A-Za-z0-9_-]{8,}' "$EVID" 2>/dev/null; then
    rm -rf "$EVID"
    echo "KEY LEAK SCAN FAILED: evidence deleted" >&2
    bad=1
  else
    echo "key leak scan: clean" | tee -a "$EVID/cleanup.txt"
  fi
  # 7) the task repo, agent HOME and transcripts go with $ROOT
  if [[ $ROOT =~ ^/tmp/hx6a/[A-Za-z0-9-]+$ ]]; then
    rm -rf "$ROOT"
    if [ ! -e "$ROOT" ] && [ -d "$EVID" ]; then echo "run root removed: $ROOT" | tee -a "$EVID/cleanup.txt"; fi
  fi
  [ "$bad" = 1 ] && [ "$rc" = 0 ] && rc=3
  exit "$rc"
}
trap cleanup EXIT INT TERM

# Wall-clock cap: on overrun kill the tmux server (and so claude); wait_for
# then gives up at once and the run ends FAIL.
( for ((i = 0; i < MAX_SECONDS; i++)); do sleep 1; [ -d "$ROOT" ] || exit 0; done
  touch "$ROOT/overrun"; T kill-server 2>/dev/null ) &
WD=$!
WDS=$(proc_start "$WD")

# --------------------------------------------------------------- environment
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

# Agent settings hold the key PATH only (rule matching is an untested assumption: ./ = project dir,
# // = absolute path). Telemetry/autoupdate are turned off by env vars.
KFDIR=${KF%/*} # the key directory, denied to the agent
cat >"$ROOT/settings.json" <<EOF
{"apiKeyHelper": "cat $KF", "permissions": {"defaultMode": "dontAsk",
 "allow": ["Read(./kata.py)", "Read(./README.md)", "Read(./check.py)", "Edit(./kata.py)", "Bash(python3 check.py)"],
 "deny": ["Edit(./check.py)", "Edit(./progress.log)", "Edit(./README.md)", "Edit(./.git/**)", "Read(//${KFDIR#/}/**)", "Read(//home/**)", "Read(./.git/**)"]}}
EOF
# Skip first-run dialogs (key names are an untested assumption; wait_ready detects a blocking dialog).
cat >"$AHOME/.claude.json" <<EOF
{"hasCompletedOnboarding": true, "theme": "dark", "projects": {"$REPO": {"hasTrustDialogAccepted": true}}}
EOF
mkdir -p "$CCD"
cp "$AHOME/.claude.json" "$CCD/.claude.json" # in case CLAUDE_CONFIG_DIR relocates it

cp -r "$HERE/agent-task/repo" "$REPO"
rm -rf "$REPO/__pycache__"
CHECK_SHA=$(sha256sum "$REPO/check.py" | cut -d' ' -f1)
README_SHA=$(sha256sum "$REPO/README.md" | cut -d' ' -f1)
{ AG init -q -b main && AG add kata.py check.py README.md && AG commit -q -m "exp-006 task template"; } || die "git init of the task repo failed"
log "run $RUN root=$ROOT herdr=$(cenv "$HERDR_BIN" --version) $(cenv tmux -V) claude=$CLAUDE_VER model=$MODEL effort=$EFFORT sid=$SID baseline=$(npass)/12"
guard || exit 2

# -------------------------------------------------------- start the "agent"
# Started from here, not from a Herdr pane. The tmux server daemonizes and is
# reparented away from this script; claude is its child on a PTY it owns, with
# its own tiny environment (nothing from the controller, no key, no TMUX).
AGENT_CMD=(env -i "HOME=$AHOME" "USER=${USER:-user}" "LOGNAME=${USER:-user}" "PATH=$AGENT_PATH"
  "LANG=C.UTF-8" "TERM=xterm-256color" "SHELL=/usr/bin/bash" "TMPDIR=$ROOT/tmp"
  "XDG_CONFIG_HOME=$ROOT/agent-xdg/config" "XDG_STATE_HOME=$ROOT/agent-xdg/state"
  "XDG_CACHE_HOME=$ROOT/agent-xdg/cache" "XDG_DATA_HOME=$ROOT/agent-xdg/data" "XDG_RUNTIME_DIR=$ROOT/agent-xdg/run"
  "CLAUDE_CONFIG_DIR=$CCD" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  "$CLAUDE_BIN" --bare --settings "$ROOT/settings.json" --strict-mcp-config --tools "Read,Edit,Bash"
  --model "$MODEL" --effort "$EFFORT" --session-id "$SID")
cenv tmux -S "$SOCK" -f /dev/null new-session -d -s agent -x 160 -y 45 -c "$REPO" "${AGENT_CMD[@]}" || die "tmux failed to start"
T set-option -t agent status off # status line would print the hostname
TMUX_PID=$(T display-message -p '#{pid}')
track tmux-server "$TMUX_PID" || { record SETUP FAIL "cannot track tmux server pid $TMUX_PID"; exit 1; }

# Identity: the pane pid itself if it is claude, else its single claude child.
find_agent() {
  local p c n=0
  p=$(T display-message -p -t agent '#{pane_pid}') && [ -n "$p" ] || return 1
  if [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$CLAUDE_BIN" ]; then APID=$p; AWHO="pane_pid $p is claude"; return 0; fi
  while read -r c; do
    [ "$(readlink "/proc/$c/exe" 2>/dev/null)" = "$CLAUDE_BIN" ] && { APID=$c; n=$((n + 1)); }
  done < <(pgrep -P "$p")
  AWHO="single claude child of pane_pid $p"
  [ "$n" = 1 ]
}
wait_for 10 find_agent || { record SETUP FAIL "no single claude process under the tmux pane (pane_pid exe=$(readlink "/proc/$(T display-message -p -t agent '#{pane_pid}')/exe"))"; exit 1; }
ASTART=$(proc_start "$APID")
track claude "$APID" || { record SETUP FAIL "cannot track agent pid $APID"; exit 1; }
tr '\0' '\n' <"/proc/$APID/environ" | cut -d= -f1 | sort >"$ROOT/env-keys-agent.txt"
tr '\0' '\n' <"/proc/$TMUX_PID/environ" | cut -d= -f1 | sort >"$ROOT/server-env-keys-tmux.txt"
{
  echo "controller (this script) pid=$$ ppid=$PPID"
  echo "tmux server pid=$TMUX_PID, its ppid=$(sed 's/.*) //' /proc/"$TMUX_PID"/stat | awk '{print $2}')"
  echo "agent pid=$APID ($AWHO), its ppid=$(sed 's/.*) //' /proc/"$APID"/stat | awk '{print $2}'), start=$ASTART"
  echo "agent exe=$(readlink "/proc/$APID/exe")"
  echo "agent cmdline=$(tr '\0' ' ' <"/proc/$APID/cmdline")"
} >"$ROOT/setup-lineage.txt"
if ! tr '\0' '\n' <"/proc/$APID/environ" | grep -qx "HOME=$AHOME" ||
  ! tr '\0' '\n' <"/proc/$APID/environ" | grep -qx "CLAUDE_CONFIG_DIR=$CCD"; then
  record SETUP FAIL "agent environ lacks HOME=$AHOME or CLAUDE_CONFIG_DIR"; exit 1
fi
# Stricter reading of the spec: any CLAUDE* name other than the two allowed ones also fails.
if grep -qE '^(ANTHROPIC_|HERDR_|SSH_AUTH_SOCK$|GNUPGHOME$|TMUX$|GPG_|CLAUDECODE$|CLAUDE_CODE_ENTRYPOINT$|CLAUDE_CODE_SESSION)' "$ROOT/env-keys-agent.txt" ||
  grep '^CLAUDE' "$ROOT/env-keys-agent.txt" | grep -qvxE 'CLAUDE_CONFIG_DIR|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'; then
  record SETUP FAIL "controller/credential variable names in the agent environment (see env-keys-agent.txt)"; exit 1
fi
if grep -qE '^(HERDR_|SSH_AUTH_SOCK|TMUX$|CLAUDE)' "$ROOT/server-env-keys-tmux.txt"; then
  record SETUP FAIL "controller variables leaked into tmux server"; exit 1
fi
log "tmux server pid=$TMUX_PID; agent pid=$APID start=$ASTART ($AWHO)"

# Ready / dialog detection: never click through a dialog, never send anything blind.
wait_ready() { # 0 = TUI prompt seen, 1 = blocking dialog text, 2 = nothing recognisable within 60 s
  local i s
  for ((i = 0; i < 60; i++)); do
    s=$PANES/ready-$i.txt
    T capture-pane -p -t agent >"$s" 2>&1
    grep -qiE "$DIALOG_RX" "$s" && return 1
    grep -qE "$PROMPT_RX" "$s" && return 0
    sleep 1
  done
  return 2
}
wait_ready
case $? in
0) ;;
1) record SETUP FAIL "blocking dialog on the first screen (see panes/ready-*.txt); nothing was sent"; exit 1 ;;
*) record SETUP FAIL "no TUI input prompt within 60 s (see panes/ready-*.txt); nothing was sent"; exit 1 ;;
esac
record SETUP PASS "claude pid=$APID start=$ASTART exe=$CLAUDE_BIN ($AWHO); env names ok; TUI prompt visible; session $SID"

# ------------------------------------------------------------ herdr server
HPID=
start_herdr() {
  # Headless server as a pod entrypoint would run it; own session/process group.
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
  track "herdr-server-$1" "$HPID" || return 1
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
    PANE=$(H workspace create --cwd "$ROOT" --label agent --no-focus | jq -r '.result.root_pane.pane_id')
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

send_prompt() { # send_prompt <text>: type it into $PANE like demo.sh mark(), then Enter
  H pane send-text "$PANE" "$1" >/dev/null
  H pane send-keys "$PANE" Enter >/dev/null
}

# ask_q <k>: the codeword is not in the question, so only a session that
# remembers P1 can answer. 0 = codeword in transcript AND pane; sets QDONE, QMEAS.
ask_q() {
  local k=$1 rx="Q$1 CODEWORD=$CODE"
  send_prompt "${Q_T//@K@/$k}"
  wait_for 120 said "$rx" || return 1
  H pane wait-output "$PANE" --match "$rx" --source visible --timeout 10000 >/dev/null || return 2
  H pane read "$PANE" --source visible --lines 45 >"$PANES/q$k.txt" 2>&1
  QDONE=$(atext | sed -n "s/.*$rx.*DONE=\([0-9]*\).*/\1/p" | tail -1)
  QMEAS=$(npass)
  return 0
}

# ------------------------------------------------------------------- tests
start_herdr initial || { record SETUP FAIL "herdr start"; exit 1; }
snap 00-initial

# A1 -----------------------------------------------------------------------
PL0=$(prog_lines)
if pane_attach a1; then
  P_A1=$PANE
  send_prompt "$P1"
  if wait_for 240 progress_past "$PL0"; then
    H pane read "$PANE" --source visible --lines 45 >"$PANES/a1-visible.txt" 2>&1
    if agent_unchanged; then
      record A1-attach PASS "P1 sent via pane $PANE; first new progress.log line after it (lines $PL0->$(prog_lines)); agent pid=$APID start=$ASTART unchanged"
    else
      record A1-attach FAIL "agent identity changed"
    fi
  else
    record A1-attach FAIL "no new progress.log line within 240 s of P1"
  fi
else
  P_A1=
  record A1-attach FAIL "could not attach"
fi
snap 01-attached

# A2 -----------------------------------------------------------------------
H pane close "$P_A1" >/dev/null
CL_GONE=no
wait_for 10 clients_eq 0 && CL_GONE=yes
T_CLOSE=$(date +%s.%N) # taken once clients=0 is confirmed (the stricter bound)
N_CLOSE=$(npass)
snap 02-disconnected
DONE_A=no
wait_for 300 said "^[[:space:]]*DONE-A ${CODE}[[:space:][:punct:]]*\$" && DONE_A=yes
N_AFTER=$(npass)
tj_rec
ROWS=$(tj_rows)
P_AFTER=$(prog_after "$T_CLOSE")
E_AFTER=$(awk -v t="$T_CLOSE" '$1 > t' <<<"$ROWS" | wc -l)
TU_AFTER=$(awk -v t="$T_CLOSE" '$1 > t && $3 > 0' <<<"$ROWS" | wc -l)
TU_SPAN=$(awk -v t="$T_CLOSE" '$1 > t && $3 > 0 {if (!a) a = $1; b = $1} END {printf "%.1f", b - a}' <<<"$ROWS")
TOOLS_ALL=$(awk '{s += $3} END {print s + 0}' <<<"$ROWS")
snap 02-detached-done
if [ "$CL_GONE" = yes ] && agent_unchanged && tj_ok && [ "$P_AFTER" -ge 1 ] && [ "$N_AFTER" -gt "$N_CLOSE" ] && [ "$TU_AFTER" -ge 1 ]; then
  record A2-disconnect PASS "clients=0, agent pid=$APID start=$ASTART unchanged, one transcript; with no client: passing $N_CLOSE->$N_AFTER, $P_AFTER progress.log lines, $E_AFTER transcript entries ($TU_AFTER with tool_use, span ${TU_SPAN}s, $TOOLS_ALL tool_use in total) after T_CLOSE=$T_CLOSE; DONE-A seen=$DONE_A"
else
  record A2-disconnect FAIL "clients_gone=$CL_GONE unchanged=$(agent_unchanged && echo y || echo n) one_transcript=$(tj_ok && echo y || echo n) progress_lines_after=$P_AFTER passing $N_CLOSE->$N_AFTER tool_use_entries_after=$TU_AFTER DONE-A=$DONE_A"
fi

# A3 -----------------------------------------------------------------------
if pane_attach a3 && ask_q 1; then
  if agent_unchanged; then
    record A3-reconnect PASS "Q1 answered with the codeword in transcript and pane; agent pid=$APID start=$ASTART unchanged; DONE=${QDONE:-?} vs harness-measured $QMEAS (informational)"
  else
    record A3-reconnect FAIL "codeword ok but agent identity changed"
  fi
else
  record A3-reconnect FAIL "could not attach, or no 'Q1 CODEWORD=<codeword>' in transcript and pane"
fi
snap 03-reconnected

# A4: restart tests (a = clean stop, b = SIGKILL) ---------------------------
restart_test() { # restart_test <a|b> <clean|forced> <prompt> <k> <done-marker>
  local id=$1 mode=$2 prompt=$3 k=$4 marker=$5 label n_stop n_down t_stop old_hpid hstart_old pl0 prog=no
  label=A4$id-$mode-restart
  # a pane attached right now (the A3 pane for A4a; the A4a pane for A4b)
  [ "$(clients)" -ge 1 ] || pane_attach "$label-pre"
  local npre
  npre=$(clients)
  pl0=$(prog_lines)
  send_prompt "$prompt"
  wait_for 240 progress_past "$pl0" && prog=yes
  n_stop=$(npass)
  t_stop=$(date +%s.%N)
  old_hpid=$HPID
  hstart_old=$(proc_start "$old_hpid")
  snap "04$id-before-restart"
  H pane list | jq -c '[.result.panes[].pane_id]' >"$ROOT/restored-$id-before.txt"
  if [ "$mode" = clean ]; then
    stop_herdr_clean || { record "$label" FAIL "server stop failed"; return; }
  else
    # SIGKILL exactly the recorded PID, after re-verifying it is ours.
    { tr '\0' '\n' <"/proc/$old_hpid/environ" | grep -qx "XDG_CONFIG_HOME=$ROOT/config" &&
      alive_same "$old_hpid" "$hstart_old"; } || { record "$label" FAIL "refusing to kill unverified pid $old_hpid"; return; }
    kill -9 "$old_hpid"
  fi
  GUARD_OK=0
  local gone_ok=no cl_gone=no adv=no unchanged=no
  wait_for 10 gone "$old_hpid" "$hstart_old" && gone_ok=yes
  # With the server gone the PTY masters are closed -> client must be gone.
  wait_for 10 clients_eq 0 && cl_gone=yes
  # the agent must keep working without Herdr and without any client
  wait_for 300 advanced "$n_stop" "$t_stop" && adv=yes
  n_down=$(npass)
  snap "04$id-herdr-down"
  agent_unchanged && unchanged=yes

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
  local rclients qok=no fin=no
  rclients=$(clients)
  pane_attach "$label" && ask_q "$k" && qok=yes
  wait_for 300 said "^[[:space:]]*${marker}[[:space:][:punct:]]*\$" && fin=yes
  snap "04$id-reattached"
  agent_unchanged || unchanged=no
  if [ "$prog" = yes ] && [ "$gone_ok" = yes ] && [ "$cl_gone" = yes ] && [ "$unchanged" = yes ] && [ "$adv" = yes ] && [ "$qok" = yes ]; then
    record "$label" PASS "$mode: old server pid $old_hpid gone, clients dropped to 0 (was $npre), agent pid=$APID start=$ASTART unchanged and advanced passing $n_stop->$n_down with a new progress.log line while Herdr was down; after restart (new server pid $HPID, restored-pane tmux clients=$rclients) Q$k answered with the codeword; DONE=${QDONE:-?} vs measured ${QMEAS:-?} (informational); $marker seen=$fin"
  else
    record "$label" FAIL "$mode: progress_before_stop=$prog server_gone=$gone_ok clients_dropped=$cl_gone unchanged=$unchanged advanced_while_down=$adv codeword_ok=$qok $marker=$fin"
  fi
}

restart_test a clean "$PB" 2 DONE-B
restart_test b forced "$PC" 3 DONE-C

# A5 -----------------------------------------------------------------------
snap 05-final
NFINAL=$(npass)
tj_rec
A5=
agent_unchanged || A5+="agent identity changed since SETUP; "
tj_ok || A5+="not exactly one session jsonl ($SID.jsonl); "
A5+=$AGENT_BAD
[ -s "$ROOT/files-bad.txt" ] && A5+="INTEGRITY: $(tr '\n' ' ' <"$ROOT/files-bad.txt"); "
grep -rqF -e "$CODE" "$REPO" && A5+="codeword found in repo files; "
if [ -z "$A5" ]; then
  record A5-final PASS "agent pid=$APID start=$ASTART unchanged since SETUP; one session jsonl; exactly 1 claude process at every snap; no --resume/--continue; codeword not in repo files; final passing=$NFINAL/12 (informational, expected 12)"
else
  record A5-final FAIL "${A5}final passing=$NFINAL/12"
fi

# ------------------------------------------------------------------ summary
[ -e "$ROOT/overrun" ] && record WATCHDOG FAIL "wall-clock cap of ${MAX_SECONDS}s exceeded; tmux server killed"
echo
printf '%-22s %-5s %s\n' TEST RESULT DETAIL
FAILS=0
while IFS=$'\t' read -r id res detail; do
  printf '%-22s %-5s %s\n' "$id" "$res" "$detail"
  [ "$res" = PASS ] || FAILS=$((FAILS + 1))
done <"$RESULTS"
echo
echo "identity: claude pid=$APID start=$ASTART  tmux-server=$TMUX_PID  session=$SID"
if [ "$FAILS" -gt 0 ]; then
  [ -n "${HPID:-}" ] && tail -n 30 "$ROOT/herdr-stdout.log" >"$ROOT/herdr-server-tail-fail.txt" 2>/dev/null
  echo "OVERALL: FAIL ($FAILS)"
  exit 1
fi
echo "OVERALL: PASS"
exit 0
