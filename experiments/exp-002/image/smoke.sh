#!/usr/bin/env bash
# Local (podman) smoke test of an EXP-002 image under pod-like constraints:
# non-root, read-only root filesystem, no capabilities, home and workspace as
# volumes, config from a read-only file, tmpfs for runtime data.
#
#   smoke.sh <image> <workdir>
#
# Prints PASS/FAIL lines and leaves evidence in <workdir>/evidence.
set -uo pipefail
img=${1:?image} wd=${2:?workdir}
[ -e "$wd" ] && { echo "refusing to reuse $wd" >&2; exit 1; }
mkdir -p "$wd"/{home,workspace,evidence}
# Rootless podman: map container uid 1000 to the invoking user.
userns=("--userns=keep-id:uid=1000,gid=1000") # one argument; commas are podman syntax
name="exp002-smoke-$$"
ev="$wd/evidence"
pass() { echo "PASS $*" | tee -a "$ev/results.txt"; }
fail() { echo "FAIL $*" | tee -a "$ev/results.txt"; }
x() { podman exec "$name" "$@"; }

podman run -d --name "$name" "${userns[@]}" --read-only --cap-drop=ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,mode=1777 --tmpfs /run/herdr:rw,mode=0700,U \
  -v "$wd/home:/home/herdr:Z" -v "$wd/workspace:/workspace:Z" \
  -e HOME=/home/herdr "$img" >/dev/null || { fail "container start"; exit 1; }

ok=0
for _ in $(seq 1 100); do
  if x herdr status server >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.1
done
podman logs "$name" >"$ev/startup.log" 2>&1
[ "$ok" = 1 ] && pass "server ready (herdr status server) without a client" || fail "server not ready"
x herdr status server >"$ev/status.txt" 2>&1

x sh -c 'ls -la ~ ~/.config/herdr ~/.claude ~/.claude/hooks ~/.codex' >"$ev/home-tree.txt" 2>&1
x test -x /home/herdr/.claude/hooks/herdr-agent-state.sh && pass "claude hook installed in persistent home" || fail "claude hook missing"
x grep -h 'HERDR_INTEGRATION_VERSION' /home/herdr/.claude/hooks/herdr-agent-state.sh /home/herdr/.codex/herdr-agent-state.sh >"$ev/hook-versions.txt" 2>&1
x herdr integration status >"$ev/integration-status.txt" 2>&1
x sh -c 'ls -la "$(dirname "$(herdr session list --json | python3 -c "import json,sys;d=json.load(sys.stdin);d=d.get(\"sessions\",d) if isinstance(d,dict) else d;print([s for s in d if s.get(\"default\")][0][\"socket_path\"])")")"' >"$ev/socket-dir.txt" 2>&1
x herdr session list --json >"$ev/session-list.json" 2>&1

# Server environment as seen by a pane: create a workspace and read env names.
x mkdir -p /workspace/repo-a
x herdr workspace create --cwd /workspace/repo-a --label repo-a >/dev/null 2>&1
sleep 1
x sh -c 'for p in /proc/[0-9]*; do [ "$(readlink $p/cwd)" = /workspace/repo-a ] && tr "\0" "\n" <$p/environ | cut -d= -f1 | sort -u && break; done' >"$ev/pane-env-keys.txt" 2>&1
grep -qE '^(KUBERNETES_|HOSTNAME$)' "$ev/pane-env-keys.txt" && fail "pod env leaked to pane" || pass "pane env is the allowlist (+ Herdr vars)"

# SIGTERM -> exit timing via podman stop (sends SIGTERM to tini -> herdr).
t0=$(date +%s.%N)
podman stop -t 30 "$name" >/dev/null
t1=$(date +%s.%N)
echo "sigterm_to_exit_s=$(echo "$t1 - $t0" | bc)" | tee "$ev/stop-timing.txt"
podman logs "$name" >"$ev/container.log" 2>&1
code=$(podman inspect -f '{{.State.ExitCode}}' "$name")
echo "exit_code=$code" >>"$ev/stop-timing.txt"
[ -s "$wd/home/.config/herdr/session.json" ] && pass "session.json persisted on home volume" || fail "no session.json"
podman rm "$name" >/dev/null
cat "$ev/results.txt"
