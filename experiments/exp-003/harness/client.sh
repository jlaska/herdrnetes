#!/usr/bin/env bash
# EXP-003 path B client: run the local Herdr UI client against the bridge socket.
#
#   HERDR_BIN=herdr client.sh <bridge-socket-path>
#
# Reproduces what `herdr --remote` exports for its client, minus ssh: HERDR_CLIENT_SOCKET_PATH
# is the bridge socket, HERDR_SOCKET_PATH is unset (the local API socket is not the target), and
# the keybinding/identity variables match the `--remote` launch. `herdr client` only connects;
# it never starts a server. HERDR_BIN picks the client binary (0.9.4/0.8.0 for version skew).
# Run it in a real terminal; detaching with the Herdr prefix then `q` ends only this client.
set -euo pipefail
sock=${1:?usage: client.sh <bridge-socket-path>}
HERDR_BIN=${HERDR_BIN:-herdr}
[ -S "$sock" ] || { echo "no socket at $sock; start bridge.py first" >&2; exit 3; }
echo "client: $("$HERDR_BIN" --version) via $sock" >&2
unset HERDR_SOCKET_PATH
export HERDR_CLIENT_SOCKET_PATH=$sock
export HERDR_REMOTE_KEYBINDINGS=local
HERDR_REATTACH_COMMAND="$(realpath "$0") $sock"
export HERDR_REATTACH_COMMAND
export HERDR_REMOTE_PREFERENCES_IDENTITY='["k8s","default"]'
exec "$HERDR_BIN" client
