#!/bin/sh
# EXP-004 live issuer launcher. ROOT-RUN, from the root-owned copy in /usr/local/libexec/exp004/
# (never from the agent-writable repository). Starts the issuer as the exp004-issuer user in a
# hardened transient systemd unit: no access to /home, read-only system, private /tmp.
# Stop with `systemctl stop exp004-issuer`: SIGTERM -> refuse new mints, drain in-flight ones for up
# to --drain-seconds (45; TimeoutStopSec=120 leaves room for the parallel DELETEs), DELETE every outstanding token. Exit status 2
# (unit shown as failed, CRITICAL in the journal) means revocation is incomplete: use the RUNBOOK
# fallback. SIGKILL, a crash or power loss skips all of this; tokens then live until GitHub expiry.
set -eu
L=/var/lib/exp004-issuer
[ -f $L/revoked-clients.json ] || { echo "missing $L/revoked-clients.json (RUNBOOK phase 3: initialize it)" >&2; exit 1; }
exec systemd-run --unit=exp004-issuer --uid=exp004-issuer --gid=exp004-issuer \
    -p RuntimeDirectory=exp004-issuer -p RuntimeDirectoryMode=0755 -p UMask=0077 \
    -p ProtectHome=yes -p ProtectSystem=strict -p ReadWritePaths=$L -p PrivateTmp=yes \
    -p NoNewPrivileges=yes -p CapabilityBoundingSet= -p PrivateDevices=yes \
    -p RestrictAddressFamilies="AF_UNIX AF_INET AF_INET6" -p TimeoutStopSec=120 \
    /usr/bin/python3 -I /usr/local/libexec/exp004/harness/issuer.py /run/exp004-issuer/issuer.sock \
    --backend github --policy $L/policy.json --admin-secret $L/admin.secret \
    --state $L/revoked-clients.json --socket-mode 0666 --drain-seconds 45
