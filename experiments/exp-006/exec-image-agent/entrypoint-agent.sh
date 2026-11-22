#!/bin/bash
# EXP-006 stage 3 execution pod entrypoint (uid 1000, PID 1 is tini).
#   1. sshd setup, reproduced from the stage-2 entrypoint (../exec-image/entrypoint.sh): host key and
#      authorized_keys copied from the Secret mount, minimal sshd_config, sshd -t;
#   2. agent setup: HOME, CLAUDE_CONFIG_DIR, a writable copy of the task repo, settings.json, first-run seed;
#   3. start (not exec) one Claude Code process in a tmux server on a dedicated socket, in a cleared environment;
#   4. write /tmp/agent/out/identity, then exec sshd in the foreground on port 2222.
# The API key is a file (EXP006_KEY_PATH) read only by the apiKeyHelper; it is never printed or put in an
# environment variable. Everything lives under /tmp (an emptyDir).
set -euo pipefail

log() { printf '%s exp006-entrypoint: %s\n' "$(date -u +%FT%T.%3NZ)" "$*" >&2; }

SECRET_DIR=/run/exp006/ssh
SSH_DIR=/tmp/ssh
AGENT_DIR=/tmp/agent
SOCK=$AGENT_DIR/tmux.sock
HOME_DIR=/tmp/home # passwd home; StrictModes checks up to here, not /tmp
# StrictModes stays on; EXP006_STRICT_MODES=no is a reviewed fallback only.
STRICT=${EXP006_STRICT_MODES:-yes}
case $STRICT in yes | no) ;; *) log "EXP006_STRICT_MODES must be yes or no"; exit 2 ;; esac

KEY_PATH=${EXP006_KEY_PATH:-/run/exp006/anthropic/api-key}
MODEL=${EXP006_MODEL:-claude-sonnet-5-5}
EFFORT=${EXP006_EFFORT:-medium}
case $KEY_PATH in *[!A-Za-z0-9_./-]*) log "EXP006_KEY_PATH has unsupported characters"; exit 2 ;; esac
case $MODEL in '' | *[!A-Za-z0-9._-]*) log "EXP006_MODEL has unsupported characters"; exit 2 ;; esac
case $EFFORT in '' | *[!a-z]*) log "EXP006_EFFORT must be lower-case letters"; exit 2 ;; esac

umask 077
for f in ssh_host_ed25519_key authorized_keys; do
  [ -r "$SECRET_DIR/$f" ] || { log "missing or unreadable $SECRET_DIR/$f"; exit 1; }
done

mkdir -p "$SSH_DIR" "$AGENT_DIR" "$HOME_DIR/.ssh"
chmod 0700 "$SSH_DIR" "$AGENT_DIR" "$HOME_DIR" "$HOME_DIR/.ssh"
install -m 0600 "$SECRET_DIR/ssh_host_ed25519_key" "$SSH_DIR/ssh_host_ed25519_key"
install -m 0600 "$SECRET_DIR/authorized_keys" "$HOME_DIR/.ssh/authorized_keys"

cat >"$SSH_DIR/sshd_config" <<CONF
Port 2222
ListenAddress 0.0.0.0
HostKey $SSH_DIR/ssh_host_ed25519_key
AuthorizedKeysFile $HOME_DIR/.ssh/authorized_keys
PidFile $SSH_DIR/sshd.pid
StrictModes $STRICT
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers herdr
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
AllowStreamLocalForwarding no
PermitTunnel no
PermitUserEnvironment no
LogLevel VERBOSE
CONF

/usr/sbin/sshd -t -f "$SSH_DIR/sshd_config" || { log "sshd config test failed"; exit 1; }

# --- agent setup --------------------------------------------------------------
CCD=$HOME_DIR/.claude
REPO=/tmp/work/repo
ATMP=$AGENT_DIR/tmp
AXDG=$AGENT_DIR/xdg
SETTINGS=$AGENT_DIR/settings.json
OUT=$AGENT_DIR/out

if [ -r "$KEY_PATH" ] && [ -s "$KEY_PATH" ]; then
  KEY_PRESENT=yes
elif [ "${EXP006_ALLOW_NO_KEY:-}" = 1 ]; then
  KEY_PRESENT=no
  log "no API key at $KEY_PATH; continuing because EXP006_ALLOW_NO_KEY=1 (CI smoke only)"
else
  log "no readable API key at $KEY_PATH and EXP006_ALLOW_NO_KEY is not 1"
  exit 1
fi

mkdir -p "$CCD" "$OUT" "$ATMP" "$AXDG"/{config,state,cache,data,run} /tmp/work
chmod 0700 "$CCD" "$OUT" "$ATMP" "$AXDG" "$AXDG"/{config,state,cache,data,run} /tmp/work
[ ! -e "$REPO" ] || { log "$REPO already exists; refusing to reuse it"; exit 1; }
cp -r /usr/share/exp006/agent-task/repo "$REPO"
chmod -R u+rwX "$REPO"

key_helper=
[ "$KEY_PRESENT" = yes ] && key_helper="\"apiKeyHelper\": \"cat $KEY_PATH\", "
cat >"$SETTINGS" <<CONF
{${key_helper}"permissions": {"defaultMode": "dontAsk",
 "allow": ["Read(./kata.py)", "Read(./README.md)", "Read(./check.py)", "Edit(./kata.py)", "Bash(python3 check.py)"],
 "deny": ["Edit(./check.py)", "Edit(./progress.log)", "Edit(./README.md)", "Read(//run/exp006/**)"]}}
CONF

# Skip first-run dialogs (key names are an untested assumption; the runbook stops if a dialog shows).
cat >"$HOME_DIR/.claude.json" <<CONF
{"hasCompletedOnboarding": true, "theme": "dark", "projects": {"$REPO": {"hasTrustDialogAccepted": true}}}
CONF
cp "$HOME_DIR/.claude.json" "$CCD/.claude.json" # in case CLAUDE_CONFIG_DIR relocates it

SID=$(cat /proc/sys/kernel/random/uuid)
export TERM=${TERM:-xterm-256color}
tmux -S "$SOCK" -f /dev/null new-session -d -s agent -x 160 -y 45 -c "$REPO" env -i \
  HOME="$HOME_DIR" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 TERM=xterm-256color SHELL=/bin/bash \
  TMPDIR="$ATMP" XDG_CONFIG_HOME="$AXDG/config" XDG_STATE_HOME="$AXDG/state" XDG_CACHE_HOME="$AXDG/cache" \
  XDG_DATA_HOME="$AXDG/data" XDG_RUNTIME_DIR="$AXDG/run" CLAUDE_CONFIG_DIR="$CCD" \
  DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  PYTHONDONTWRITEBYTECODE=1 \
  /usr/local/bin/claude --bare --settings "$SETTINGS" --strict-mcp-config --tools Read,Edit,Bash \
  --model "$MODEL" --effort "$EFFORT" --session-id "$SID"
tmux -S "$SOCK" set-option -t agent status off

# pane_pid is `env` until it execs claude (same pid); wait until /proc/<pid>/exe is the claude binary.
PID=
for _ in $(seq 1 100); do
  PID=$(tmux -S "$SOCK" display-message -p -t agent '#{pane_pid}' 2>/dev/null || true)
  if [ -n "$PID" ] && [ "$(readlink "/proc/$PID/exe" 2>/dev/null || true)" = /usr/local/bin/claude ]; then
    break
  fi
  PID=
  sleep 0.1
done
[ -n "$PID" ] || { log "the tmux pane did not become /usr/local/bin/claude within 10 s"; exit 1; }
START=$(sed 's/.*) //' "/proc/$PID/stat" | awk '{print $20}')
CLAUDE_VERSION=$(sed -n 's/^claude version=\([^ ]*\) .*/\1/p' /usr/share/exp006-manifest.txt)
printf 'pid=%s\nstart=%s\nsid=%s\nmodel=%s\neffort=%s\nclaude_version=%s\nkey_present=%s\n' \
  "$PID" "$START" "$SID" "$MODEL" "$EFFORT" "$CLAUDE_VERSION" "$KEY_PRESENT" >"$OUT/identity.tmp"
mv "$OUT/identity.tmp" "$OUT/identity"
log "agent started: $(tr '\n' ' ' <"$OUT/identity")"

log "exec sshd on :2222 (StrictModes $STRICT)"
exec /usr/sbin/sshd -D -e -f "$SSH_DIR/sshd_config"
