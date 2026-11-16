#!/bin/bash
# EXP-003 Ovis container entrypoint (under tini, uid 1000, read-only rootfs).
# Fails closed: Ovis treats an empty OVIS_TOKEN as "no token" and, from loopback,
# lets everyone in (server/access.ts decideAccess), so refuse to start without one.
set -euo pipefail
log() { printf '%s ovis-entrypoint: %s\n' "$(date -u +%FT%T.%3NZ)" "$*" >&2; }

[ "${#OVIS_TOKEN}" -ge 24 ] || { log "OVIS_TOKEN missing or shorter than 24 characters; refusing to start"; exit 1; }
case "${HOST:-127.0.0.1}" in
127.0.0.1 | localhost | ::1) ;;
*) [ "${OVIS_ALLOW_NON_LOOPBACK:-}" = 1 ] || { log "HOST=${HOST} is not loopback; refusing to start"; exit 1; } ;;
esac
[ "${OVIS_TELEMETRY:-}" = 0 ] || { log "OVIS_TELEMETRY must be 0; refusing to start"; exit 1; }
[ -d "$HOME" ] && [ -w "$HOME" ] || { log "HOME=$HOME must be a writable private directory (Ovis writes \$HOME/.config/herdr-web-ui/bridges)"; exit 1; }
log "start ovis $(grep '^ovis=' /usr/share/herdrnetes/ovis-manifest.txt) host=${HOST:-127.0.0.1} port=${PORT:-7317} socket=${HERDR_SOCKET:-unset}"
exec /opt/ovis/ovis-server serve
