#!/bin/sh
# EXP-004 live issuer launcher. ROOT-RUN, from the root-owned copy in /usr/local/libexec/exp004/
# (never from the agent-writable repository). Starts the issuer as the exp004-issuer user in a
# hardened transient systemd unit: no access to /home, read-only system, private /tmp.
# Stop with `systemctl stop exp004-issuer` (SIGTERM -> the issuer revokes outstanding tokens).
set -eu
L=/var/lib/exp004-issuer
exec systemd-run --unit=exp004-issuer --uid=exp004-issuer --gid=exp004-issuer \
    -p RuntimeDirectory=exp004-issuer -p RuntimeDirectoryMode=0755 -p UMask=0077 \
    -p ProtectHome=yes -p ProtectSystem=strict -p ReadWritePaths=$L -p PrivateTmp=yes \
    -p NoNewPrivileges=yes -p CapabilityBoundingSet= -p PrivateDevices=yes \
    -p RestrictAddressFamilies="AF_UNIX AF_INET AF_INET6" -p TimeoutStopSec=60 \
    /usr/bin/python3 -I /usr/local/libexec/exp004/issuer.py /run/exp004-issuer/issuer.sock \
    --backend github --policy $L/policy.json --admin-secret $L/admin.secret \
    --state $L/revoked-clients.json --socket-mode 0666
