#!/usr/bin/env bash
# EXP-006 stage 3: disposable SSH/PTY smoke test for the agent execution image (NO API key, NO egress).
#   smoke-agent.sh <exec-image-ref> <client-image-ref>
# Adapted from ../exec-image/smoke.sh. Runs in CI after the build and BEFORE any registry login or push. It has
# never been executed; the first CI run is its first execution.
#
# Starts the image on a `docker network create --internal` network (no route out) with flags that only
# APPROXIMATE PSA restricted (uid 1000, read-only rootfs, no caps, no-new-privileges, default seccomp, tmpfs /tmp)
# and EXP006_ALLOW_NO_KEY=1, then drives the real stage-2 client (`ssh` from the EXP-002 Herdr image):
#   A  PTY + forced tmux attach works (detach with C-b d, rc 0) and the tmux session `agent` still exists.
#   B  `ssh ... id` does not run `id`.
#   C  a key that is not in authorized_keys is rejected.
#   D  exp006-status: agent alive, identity stable across two calls 5 s apart, nothing sent to the agent, no key,
#      hashes ok; `claude --version` is the pinned version.
#   E  process tree: claude's parent is the tmux server, whose parent is tini (pid 1).
# All keys are throwaway, generated here, and never printed. No Anthropic key exists in this test.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <exec-image-ref> <client-image-ref>" >&2; exit 2; }
EXEC_IMAGE=$1
CLIENT_IMAGE=$2
WANT_VERSION='2.1.323 (Claude Code)'

# Key files are 0644 and must NOT be owned by uid 1000, or ssh rejects the client key.
if [ "$(id -u)" -eq 1000 ]; then
  echo "smoke-agent.sh: runner uid is 1000; the key files would be owned by the container user." >&2
  echo "smoke-agent.sh: run as another uid (GitHub-hosted runners use 1001)." >&2
  exit 2
fi

NET=exp006-smoke-agent-$$
EXEC=exp006-agent-exec
CLIENTS=(exp006-agent-client-a exp006-agent-client-b exp006-agent-client-c)
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

die() { # die <message>: print the exec logs, then fail
  echo "smoke-agent.sh: $*" >&2
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

# --internal: no route to the outside, so nothing in this test can reach any API.
docker network create --internal "$NET" >/dev/null

HARDEN=(--user 1000:1000 --read-only --cap-drop ALL --security-opt no-new-privileges)

# --- exec container ---------------------------------------------------------
docker run -d --name "$EXEC" --network "$NET" --network-alias exp006-exec \
  "${HARDEN[@]}" --tmpfs /tmp:rw,mode=1777 -e EXP006_ALLOW_NO_KEY=1 \
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
[[ $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ ]] || die "unparseable agent identity"
echo "agent identity: pid=$pid start=$start"

# client <container-name> <client-dir> <tty-flag> [remote-command...]; stdin is passed through.
# ssh options and the tty flag go before the destination; the optional remote command goes after it.
client() {
  local name=$1 dir=$2 tty_flag=$3
  shift 3
  timeout 30 docker run --rm -i --name "$name" --network "$NET" \
    "${HARDEN[@]}" -e TERM=xterm-256color \
    --tmpfs /tmp:rw,mode=1777 --tmpfs /home/herdr:rw,mode=0700,uid=1000,gid=1000 \
    -v "$dir:/run/exp006/client:ro" --entrypoint ssh "$CLIENT_IMAGE" \
    -i /run/exp006/client/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=/run/exp006/client/known_hosts \
    -o HostKeyAlias=exp006-exec -o UpdateHostKeys=no -p 2222 "$tty_flag" herdr@exp006-exec "$@"
}

# --- Test A: PTY + forced command + host-key verification -------------------
rc=0
{ sleep 4; printf '\002d'; sleep 1; } \
  | client exp006-agent-client-a "$WORK/client" -tt >"$WORK/out-a" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && dx tmux -S /tmp/agent/tmux.sock has-session -t agent >/dev/null 2>&1; then
  record PASS "A pty+forced tmux attach, detach, session still exists" "ssh rc=$rc; session agent exists"
else
  record FAIL "A pty+forced tmux attach, detach, session still exists" "ssh rc=$rc or no tmux session agent"
  echo "--- client A output (terminal text, no key material) ---" >&2
  tail -n 30 "$WORK/out-a" >&2 || true
fi

# --- Test B: the forced command cannot be bypassed --------------------------
rc=0
client exp006-agent-client-b "$WORK/client" -T id </dev/null >"$WORK/out-b" 2>&1 || rc=$?
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
printf 'x\r' | client exp006-agent-client-c "$WORK/client2" -T >"$WORK/out-c" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ "$(docker logs "$EXEC" 2>&1 | grep -c 'Accepted publickey' || true)" = "$accepted" ]; then
  record PASS "C unauthorized key rejected" "ssh rc=$rc; no new accepted login"
else
  record FAIL "C unauthorized key rejected" "ssh rc=$rc or an extra login was accepted"
  tail -n 10 "$WORK/out-c" >&2 || true
fi

# --- Test D: status, identity stability, version ----------------------------
kv() { sed -n "s/^$1=//p" <<<"$2" | head -n 1; }
s1=$(dx exp006-status || true)
sleep 5
s2=$(dx exp006-status || true)
d_bad=
[ "$(kv pid "$s1")" = "$pid" ] && [ "$(kv start "$s1")" = "$start" ] || d_bad+="s1 identity differs from the identity file; "
[ "$(kv pid "$s2")" = "$(kv pid "$s1")" ] && [ "$(kv start "$s2")" = "$(kv start "$s1")" ] || d_bad+="pid/start changed in 5 s; "
for s in "$s1" "$s2"; do
  [ "$(kv alive "$s")" = yes ] || d_bad+="alive!=yes; "
  [ "$(kv passing "$s")" = 0 ] || d_bad+="passing!=0; "
  [ "$(kv check_sha_ok "$s")" = yes ] && [ "$(kv readme_sha_ok "$s")" = yes ] || d_bad+="hash mismatch; "
  [ "$(kv key_present "$s")" = no ] || d_bad+="key_present!=no; "
  [ "$(kv resume_flag "$s")" = no ] || d_bad+="resume_flag!=no; "
  jc=$(kv jsonl_count "$s")
  [[ $jc =~ ^[0-9]+$ ]] && [ "$jc" -le 1 ] || d_bad+="jsonl_count not <=1; "
done
# HOME is set only so a --version call has a writable place if it wants one; DISABLE_AUTOUPDATER avoids any update check.
ver=$(timeout 20 docker exec -e HOME=/tmp/home -e DISABLE_AUTOUPDATER=1 "$EXEC" /usr/local/bin/claude --version 2>&1 | head -n 1 || true)
[ "$ver" = "$WANT_VERSION" ] || d_bad+="claude --version is '$ver'; "
if [ -z "$d_bad" ]; then
  record PASS "D agent alive and stable, no key, hashes ok, version" "pid=$pid start=$start alive=yes x2 passing=0 jsonl_count=$(kv jsonl_count "$s2") version=$ver"
else
  record FAIL "D agent alive and stable, no key, hashes ok, version" "$d_bad"
  printf '%s\n' "$s2" >&2
fi

# --- Test E: process tree ---------------------------------------------------
ppid=$(dx ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
pcomm=$(dx ps -o comm= -p "${ppid:-0}" 2>/dev/null || true)
pppid=$(dx ps -o ppid= -p "${ppid:-0}" 2>/dev/null | tr -d ' ' || true)
rcomm=$(dx ps -o comm= -p 1 2>/dev/null || true)
if [[ $pcomm == tmux* ]] && [ "$pppid" = 1 ] && [ "$rcomm" = tini ]; then
  record PASS "E claude <- tmux server <- tini (pid 1)" "claude pid=$pid ppid=$ppid ($pcomm) -> ppid=$pppid ($rcomm)"
else
  record FAIL "E claude <- tmux server <- tini (pid 1)" "claude ppid=${ppid:-?} comm='${pcomm:-?}' its ppid=${pppid:-?} pid1 comm='${rcomm:-?}'"
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
  echo "smoke-agent.sh: FAIL" >&2
  echo "--- docker logs $EXEC (no key material) ---" >&2
  docker logs --tail 80 "$EXEC" >&2 2>&1 || true
  exit 1
fi
echo "smoke-agent.sh: PASS"
