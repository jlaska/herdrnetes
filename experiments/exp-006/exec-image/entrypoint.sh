#!/bin/bash
# EXP-006 execution pod entrypoint (uid 1000, PID 1 is tini).
#   1. copy the host key (to /tmp/ssh) and authorized_keys (to /tmp/home/.ssh) from
#      the Secret mount (owner uid 1000, dirs 0700, files 0600) for sshd's checks;
#   2. write a minimal sshd_config;
#   3. start the tmux server (dedicated socket) running counter.sh;
#   4. exec sshd in the foreground on port 2222.
# Key material is never printed. Everything lives under /tmp (an emptyDir).
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

export TERM=${TERM:-xterm-256color}
tmux -S "$SOCK" -f /dev/null new-session -d -s agent /usr/local/bin/counter.sh "$AGENT_DIR/out"

# Fail fast if the counter did not start (identity is written once, at start).
for _ in $(seq 1 100); do
  [ -s "$AGENT_DIR/out/identity" ] && break
  sleep 0.1
done
[ -s "$AGENT_DIR/out/identity" ] || { log "counter did not start"; exit 1; }
log "counter started: $(tr '\n' ' ' <"$AGENT_DIR/out/identity")"

log "exec sshd on :2222 (StrictModes $STRICT)"
exec /usr/sbin/sshd -D -e -f "$SSH_DIR/sshd_config"
