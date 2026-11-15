# shellcheck shell=bash
# EXP-001 harness: run an isolated Herdr instance without touching the user's
# default Herdr server, config, or shell history.
#
# Isolation model (verified against Herdr v0.9.5 source, src/session.rs and
# src/config.rs): Herdr derives its config/session/socket directory from
# XDG_CONFIG_HOME and its agent-detection/client-shell state from
# XDG_STATE_HOME. HERDR_SOCKET_PATH / HERDR_SESSION / HERDR_PANE_ID would
# redirect the CLI to another server, so they are always unset.
#
# Agents (Claude Code) intentionally keep the real HOME so they can use the
# operator's existing login; their transcripts land under ~/.claude/projects/
# keyed by the disposable repo path, which never collides with real projects.
#
# Usage: source lib.sh; exp_init <run-name> [osc7=0|1] [pane_history=0|1]

# Keep this short: Herdr places herdr.sock under $XDG_CONFIG_HOME/herdr and a
# Unix socket path must fit sockaddr_un.sun_path (108 bytes on Linux).
EXP_SCRATCH=${EXP_SCRATCH:-/tmp/hx1}
HERDR_BIN=${HERDR_BIN:-$(command -v herdr)}

exp_init() {
  local name=$1 osc7=${2:-0} pane_history=${3:-0}
  EXP_ROOT="$EXP_SCRATCH/$name"
  if [ -e "$EXP_ROOT" ]; then
    echo "refusing to reuse existing $EXP_ROOT" >&2
    return 1
  fi
  mkdir -p "$EXP_ROOT"/{config/herdr,state,shellhist,repos,evidence}
  export EXP_ROOT
  exp_use "$name" || return 1
  if [ "${#EXP_ROOT}" -gt 70 ]; then
    echo "EXP_ROOT too long for herdr.sock (sun_path limit)" >&2
    return 1
  fi

  cat >"$EXP_ROOT/config/herdr/config.toml" <<EOF
onboarding = false

[update]
version_check = false
manifest_check = false

[terminal]
default_shell = "$EXP_ROOT/exp-shell"
shell_mode = "non_login"

[experimental]
pane_history = $([ "$pane_history" = 1 ] && echo true || echo false)
EOF

  # Deterministic pane shell: no distro profile hooks, isolated history file,
  # and an explicit switch for OSC 7 cwd reporting.
  cat >"$EXP_ROOT/exp-shell" <<EOF
#!/bin/sh
exec /usr/bin/bash --noprofile --rcfile "$EXP_ROOT/exp-bashrc" -i "\$@"
EOF
  chmod +x "$EXP_ROOT/exp-shell"
  cat >"$EXP_ROOT/exp-bashrc" <<EOF
export HISTFILE="$EXP_ROOT/shellhist/bash_history"
HISTSIZE=1000
HISTFILESIZE=1000
PS1='[\W]\$ '
unset PROMPT_COMMAND
EOF
  # osc7=1: empty URI host (accepted by Herdr 0.9.5, src/pane/osc.rs:665-678).
  # osc7=2: real hostname, as VTE-style shell integrations emit (rejected by Herdr).
  # shellcheck disable=SC2016
  case "$osc7" in
  1) echo 'PROMPT_COMMAND='"'"'printf "\033]7;file://%s\007" "$PWD"'"'" >>"$EXP_ROOT/exp-bashrc" ;;
  2) echo 'PROMPT_COMMAND='"'"'printf "\033]7;file://%s%s\007" "$HOSTNAME" "$PWD"'"'" >>"$EXP_ROOT/exp-bashrc" ;;
  esac
  echo "EXP_ROOT=$EXP_ROOT herdr=$("$HERDR_BIN" --version) osc7=$osc7 pane_history=$pane_history"
}

# Select an existing run (e.g. in a new shell): exp_use <run-name>
exp_use() {
  EXP_ROOT="$EXP_SCRATCH/$1"
  EXP_TMUX_SOCKET="hx1-$1"
  export EXP_ROOT EXP_TMUX_SOCKET
  [ -d "$EXP_ROOT" ]
}

# Minimal allowlisted environment for everything Herdr runs, so nothing from
# the controlling session (HERDR_*, CLAUDE_CODE_*, tokens, SSH_AUTH_SOCK)
# leaks into the server or its panes. This is also closer to a pod.
exp_env() {
  printf '%s\n' env -i "HOME=$HOME" "USER=$USER" "LOGNAME=$USER" "PATH=$PATH" \
    "LANG=${LANG:-C.UTF-8}" "TERM=xterm-256color" "SHELL=/usr/bin/bash" \
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    "XDG_CONFIG_HOME=$EXP_ROOT/config" "XDG_STATE_HOME=$EXP_ROOT/state"
}

# Run any herdr CLI command against the isolated instance only.
h() {
  local -a e
  mapfile -t e < <(exp_env)
  "${e[@]}" "$HERDR_BIN" "$@"
}

# Abort unless the CLI resolves to a socket inside EXP_ROOT.
exp_guard() {
  local sock
  sock=$(h session list --json 2>/dev/null | uv run --no-project python -c \
    'import json,sys; d=json.load(sys.stdin); d=d.get("sessions",d) if isinstance(d,dict) else d; print([s for s in d if s.get("default")][0]["socket_path"])')
  case "$sock" in
    "$EXP_ROOT"/*) return 0 ;;
    *) echo "GUARD: socket '$sock' is outside $EXP_ROOT; aborting" >&2; return 1 ;;
  esac
}

# PID of the isolated server, matched by its environment (never by name).
exp_server_pid() {
  local pid
  for pid in $(pgrep -u "$(id -u)" -f 'herdr.* server$'); do
    if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null |
      grep -qx "XDG_CONFIG_HOME=$EXP_ROOT/config"; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

# Attach a real TUI client inside a private tmux server (fixed geometry).
exp_client_start() {
  local -a e
  mapfile -t e < <(exp_env)
  tmux -L "$EXP_TMUX_SOCKET" -f /dev/null new-session -d -s client -x 200 -y 50 -c "$EXP_ROOT/repos" \
    "$(printf '%q ' "${e[@]}" "$HERDR_BIN")"

  for _ in $(seq 1 100); do
    exp_server_pid >/dev/null && h status server >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "server did not start" >&2
  return 1
}

# Detach the client without stopping the server (ctrl+b q).
exp_client_detach() {
  tmux -L "$EXP_TMUX_SOCKET" send-keys -t client C-b q 2>/dev/null || return 0
  sleep 1
  tmux -L "$EXP_TMUX_SOCKET" kill-server 2>/dev/null || true
}

exp_client_screen() {
  tmux -L "$EXP_TMUX_SOCKET" capture-pane -p -t client
}

exp_stop_clean() {
  exp_guard || return 1
  h server stop || return 1
  exp_wait_gone
}

exp_kill() {
  local sig=$1 pid
  pid=$(exp_server_pid) || { echo "no isolated server" >&2; return 1; }
  echo "kill -$sig $pid"
  kill "-$sig" "$pid"
  exp_wait_gone
}

exp_wait_gone() {

  for _ in $(seq 1 200); do
    exp_server_pid >/dev/null || return 0
    sleep 0.1
  done
  echo "server still running" >&2
  return 1
}

# Capture observable state for later comparison.
exp_capture() {
  local label=$1 out="$EXP_ROOT/evidence/$1"
  mkdir -p "$out"
  cp -a "$EXP_ROOT/config/herdr/session.json" "$out/" 2>/dev/null || true
  (cd "$EXP_ROOT" && find config state shellhist -printf '%M %s %TY-%Tm-%Td %TH:%TM:%TS %p\n' | sort -k5) >"$out/tree.txt"
  if exp_server_pid >/dev/null; then
    h api snapshot >"$out/api-snapshot.json" 2>&1 || true
    h pane list >"$out/panes.json" 2>&1 || true
    ps -o pid,ppid,stat,lstart,args --ppid "$(exp_server_pid)" >"$out/children.txt" 2>&1 || true
  fi
  echo "captured $label -> $out"
}
