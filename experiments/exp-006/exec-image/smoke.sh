#!/usr/bin/env bash
# EXP-006 stage 2: disposable SSH/PTY smoke test for the execution image.
#   smoke.sh <exec-image-ref> <client-image-ref>
# Runs in CI after the build and BEFORE any registry login or push. It has never
# been executed outside CI; the first CI run is its first execution.
#
# Starts the exec image on a throwaway docker network with flags that only APPROXIMATE
# PSA restricted (uid 1000, read-only rootfs, no caps, no-new-privileges, default
# seccomp, tmpfs /tmp), then drives the real stage-2 client (`ssh` from the EXP-002
# Herdr image) through it:
#   A  positive: PTY + forced tmux attach + host-key verification; the ACK must carry
#      the counter's original pid/start/nonce.
#   B  `ssh ... id` must not run `id` (forced command cannot be bypassed).
#   C  a key that is not in authorized_keys must be rejected.
#   D  the counter identity is unchanged after A and the counter is still advancing.
# All keys are throwaway, generated here, readable by uid 1000 without being owned by
# it (like a root-owned, fsGroup-readable Kubernetes Secret), and never printed.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <exec-image-ref> <client-image-ref>" >&2; exit 2; }
EXEC_IMAGE=$1
CLIENT_IMAGE=$2

# Key files are 0644 and must NOT be owned by uid 1000, or ssh rejects the client key.
if [ "$(id -u)" -eq 1000 ]; then
  echo "smoke.sh: runner uid is 1000; the key files would be owned by the container user." >&2
  echo "smoke.sh: run as another uid (GitHub-hosted runners use 1001)." >&2
  exit 2
fi

NET=exp006-smoke-$$
EXEC=exp006-exec
CLIENTS=(exp006-client-a exp006-client-b exp006-client-c)
WORK=$(mktemp -d)

cleanup() {
  local c
  for c in "${CLIENTS[@]}" "$EXEC"; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cleanup_early() { for c in "${CLIENTS[@]}" "$EXEC"; do docker rm -f "$c" >/dev/null 2>&1 || true; done; }
cleanup_early

declare -a NAMES=() STATUS=() DETAIL=()
FAILED=0
record() { # record <PASS|FAIL> <name> <detail>
  STATUS+=("$1"); NAMES+=("$2"); DETAIL+=("$3")
  [ "$1" = PASS ] || FAILED=1
}

die() { # die <message>: print the table so far plus the exec logs, then fail
  echo "smoke.sh: $*" >&2
  echo "--- docker logs $EXEC (no key material) ---" >&2
  docker logs --tail 80 "$EXEC" >&2 2>&1 || true
  exit 1
}

# --- throwaway keys (never printed) -----------------------------------------
mkdir -p "$WORK/host" "$WORK/client" "$WORK/client2"
chmod 0755 "$WORK" "$WORK/host" "$WORK/client" "$WORK/client2"
keygen() { env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -C exp006-smoke -f "$1"; }
keygen "$WORK/host/ssh_host_ed25519_key"
keygen "$WORK/client/id_ed25519"
keygen "$WORK/client2/id_ed25519"
hostpub=$(cut -d' ' -f1,2 "$WORK/host/ssh_host_ed25519_key.pub")
clientpub=$(cut -d' ' -f1,2 "$WORK/client/id_ed25519.pub")
printf 'restrict,pty,command="tmux -S /tmp/agent/tmux.sock -f /dev/null attach -t agent" %s\n' \
  "$clientpub" >"$WORK/host/authorized_keys"
printf 'exp006-exec %s\n' "$hostpub" >"$WORK/client/known_hosts"
cp "$WORK/client/known_hosts" "$WORK/client2/known_hosts"
rm -f "$WORK"/host/*.pub "$WORK"/client/*.pub "$WORK"/client2/*.pub
chmod 0644 "$WORK"/host/* "$WORK"/client/* "$WORK"/client2/*

docker network create "$NET" >/dev/null

HARDEN=(--user 1000:1000 --read-only --cap-drop ALL --security-opt no-new-privileges)

# --- exec container ---------------------------------------------------------
docker run -d --name "$EXEC" --network "$NET" --network-alias exp006-exec \
  "${HARDEN[@]}" --tmpfs /tmp:rw,mode=1777 \
  -v "$WORK/host:/run/exp006/ssh:ro" "$EXEC_IMAGE" >/dev/null

ready=0
for _ in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$EXEC" 2>/dev/null)" != true ]; then
    die "exec container exited during startup"
  fi
  if docker logs "$EXEC" 2>&1 | grep -q 'exp006-entrypoint: exec sshd' \
    && docker logs "$EXEC" 2>&1 | grep -q 'Server listening on' \
    && timeout 10 docker exec "$EXEC" test -s /tmp/agent/out/identity 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || die "exec container not ready within 30 s"

dx() { timeout 20 docker exec "$EXEC" "$@"; }
ident=$(dx cat /tmp/agent/out/identity)
pid=$(printf '%s\n' "$ident" | sed -n 's/^pid=//p')
start=$(printf '%s\n' "$ident" | sed -n 's/^start=//p')
nonce=$(printf '%s\n' "$ident" | sed -n 's/^nonce=//p')
[[ $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $nonce =~ ^[0-9a-f]{16}$ ]] \
  || die "unparseable counter identity"
echo "counter identity: pid=$pid start=$start nonce=$nonce"

# client <container-name> <client-dir> <ssh args...>; stdin is passed through.
client() {
  local name=$1 dir=$2
  shift 2
  timeout 30 docker run --rm -i --name "$name" --network "$NET" \
    "${HARDEN[@]}" -e TERM=xterm-256color \
    --tmpfs /tmp:rw,mode=1777 --tmpfs /home/herdr:rw,mode=0700,uid=1000,gid=1000 \
    -v "$dir:/run/exp006/client:ro" --entrypoint ssh "$CLIENT_IMAGE" \
    -i /run/exp006/client/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=/run/exp006/client/known_hosts \
    -o HostKeyAlias=exp006-exec -o UpdateHostKeys=no -p 2222 "$@" herdr@exp006-exec
}

# --- Test A: PTY + forced command + host-key verification -------------------
rc=0
{ sleep 3; printf 'mark smoke\r'; sleep 3; printf '\002d'; } \
  | client exp006-client-a "$WORK/client" -tt >"$WORK/out-a" 2>&1 || rc=$?
if dx grep -F "ACK smoke pid=$pid start=$start nonce=$nonce" /tmp/agent/out/counter.log >/dev/null 2>&1; then
  record PASS "A pty+forced tmux attach, ACK from original process" "ssh rc=$rc pid=$pid start=$start nonce=$nonce"
else
  record FAIL "A pty+forced tmux attach, ACK from original process" "no matching ACK; ssh rc=$rc"
  echo "--- client A output (terminal text, no key material) ---" >&2
  tail -n 30 "$WORK/out-a" >&2 || true
fi

# --- Test B: the forced command cannot be bypassed --------------------------
rc=0
client exp006-client-b "$WORK/client" -T id </dev/null >"$WORK/out-b" 2>&1 || rc=$?
accepted=$(docker logs "$EXEC" 2>&1 | grep -c 'Accepted publickey' || true)
if grep -q 'uid=' "$WORK/out-b"; then
  record FAIL "B remote command 'id' not executed" "output contains uid= (ssh rc=$rc)"
elif [ "$accepted" -lt 2 ]; then
  # Without a second accepted login the absence of uid= proves nothing.
  record FAIL "B remote command 'id' not executed" "login B was not accepted (accepted=$accepted)"
  tail -n 10 "$WORK/out-b" >&2 || true
else
  record PASS "B remote command 'id' not executed" "no uid= in output; ssh rc=$rc (nonzero is expected); accepted logins=$accepted"
fi

# --- Test C: unauthorized key rejected --------------------------------------
rc=0
printf 'mark unauth\r' | client exp006-client-c "$WORK/client2" -T >"$WORK/out-c" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && ! dx grep -F 'ACK unauth' /tmp/agent/out/counter.log >/dev/null 2>&1; then
  record PASS "C unauthorized key rejected" "ssh rc=$rc; no ACK unauth"
else
  record FAIL "C unauthorized key rejected" "ssh rc=$rc or an ACK appeared"
  tail -n 10 "$WORK/out-c" >&2 || true
fi

# --- Test D: identity unchanged and the counter still advancing -------------
last_n() { dx grep COUNT /tmp/agent/out/counter.log | tail -n 1 | sed 's/.*n=//'; }
pid2=$(dx cat /tmp/agent/out/identity | sed -n 's/^pid=//p')
start2=$(dx cat /tmp/agent/out/identity | sed -n 's/^start=//p')
# shellcheck disable=SC2016 # $1 expands inside the container's bash, not here
live_start=$(dx bash -c 'sed "s/.*) //" "/proc/$1/stat" | awk "{print \$20}"' _ "$pid" 2>/dev/null || true)
n1=$(last_n)
sleep 2
n2=$(last_n)
if [ "$pid2" = "$pid" ] && [ "$start2" = "$start" ] && [ "$live_start" = "$start" ] \
  && [[ $n1 =~ ^[0-9]+$ && $n2 =~ ^[0-9]+$ ]] && [ "$n2" -gt "$n1" ]; then
  record PASS "D identity unchanged, counter advancing" "pid=$pid2 start=$start2 live_start=$live_start n $n1 -> $n2"
else
  record FAIL "D identity unchanged, counter advancing" "pid=$pid2 start=$start2 live_start=${live_start:-?} n ${n1:-?} -> ${n2:-?}"
fi

# --- table ------------------------------------------------------------------
table() {
  local i
  echo '| Result | Test | Detail (non-secret) |'
  echo '|---|---|---|'
  for i in "${!NAMES[@]}"; do
    printf '| %s | %s | %s |\n' "${STATUS[$i]}" "${NAMES[$i]}" "${DETAIL[$i]}"
  done
}
table
if [ -n "${SMOKE_TABLE_FILE:-}" ]; then table >"$SMOKE_TABLE_FILE"; fi

if [ "$FAILED" -ne 0 ]; then
  echo "smoke.sh: FAIL" >&2
  echo "--- docker logs $EXEC (no key material) ---" >&2
  docker logs --tail 80 "$EXEC" >&2 2>&1 || true
  exit 1
fi
echo "smoke.sh: PASS"
