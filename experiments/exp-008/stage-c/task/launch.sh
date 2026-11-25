#!/bin/sh
# EXP-008 Stage C launcher: becomes the sandbox's canonical main process and execs Claude Code.
# Started by the bootstrap argv in ../launcher.sh after the package's sha256 was verified.
#
# - Keeps the environment OpenShell gives the main process (provider placeholder, CA bundle variables
#   such as NODE_EXTRA_CA_CERTS/SSL_CERT_FILE, SANDBOX, USER, TERM); it only ADDS variables. Using
#   `env -i` here would remove the proxy CA trust and the placeholder (OpenShell v0.1.9
#   crates/openshell-sandbox/src/child_env.rs, process.rs).
# - Writes /sandbox/c/launch/identity (pid, /proc start, boot id, nonce, uid, placeholder FORM only),
#   then execs claude with the same PID.
# - Never prints, stores or inspects a credential value. The key form is a fixed word.
# - Moves OpenShell's placeholder from ANTHROPIC_API_KEY to EXP008_ANTHROPIC_KEYREF and serves it through
#   the settings' apiKeyHelper. Claude Code 2.1.323 shows a blocking "Detected a custom API key ... use
#   this API key?" dialog for an unapproved ANTHROPIC_API_KEY even under --bare (static strings review);
#   with the env var unset and an apiKeyHelper, no dialog appeared in EXP-006 s3b. The proxy substitutes
#   by placeholder VALUE in the x-api-key header, so the variable name does not matter to OpenShell.
set -eu
B=/sandbox/c
P=$B/pkg
umask 077
[ ! -e "$B/repo" ] || { echo "exp008c-launch: $B/repo exists; refusing to reuse state" >&2; exit 1; }
mkdir -p "$B/repo" "$B/claude" "$B/home" "$B/launch" "$B/tmp" "$B/xdg/config" "$B/xdg/state" "$B/xdg/cache" "$B/xdg/data"
install -m 0755 "$P/step.sh" "$B/repo/step.sh"
cp "$P/prompt.txt" "$B/repo/TASK.txt"
cp "$P/settings.json" "$B/settings.json"
# First-run state (EXP-006 entrypoint-agent.sh:98 pattern): onboarding done, folder trust accepted.
# Trust must be seeded: apiKeyHelper refuses to run before workspace trust is confirmed.
printf '{"hasCompletedOnboarding": true, "theme": "dark", "projects": {"%s": {"hasTrustDialogAccepted": true}, "%s": {"hasTrustDialogAccepted": true}}}\n' "$B/repo" "$B" >"$B/claude/.claude.json"
cp "$B/claude/.claude.json" "$B/home/.claude.json"

pp="openshell"; pp="$pp:resolve:" # assembled: never literal in an agent-readable file
case ${ANTHROPIC_API_KEY:-} in
'') KF=absent ;;
"$pp"*) KF=placeholder ;;
sk-ant-*) KF=REAL-KEY-SHAPE ;;
*) KF=other ;;
esac
EXP008_ANTHROPIC_KEYREF=${ANTHROPIC_API_KEY:-}
unset ANTHROPIC_API_KEY CLAUDE_API_KEY
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
SID=$(cat /proc/sys/kernel/random/uuid)
START=$(sed 's/.*) //' /proc/$$/stat | awk '{print $20}')
CA=$( [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && [ -r "${NODE_EXTRA_CA_CERTS:-/nonexistent}" ] && echo readable || echo missing)
{
  echo "pid=$$"; echo "start=$START"; echo "nonce=$NONCE"; echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
  echo "utc=$(date -u +%FT%T.%3NZ)"; echo "uid=$(id -u)"; echo "sid=$SID"; echo "key_form=$KF"; echo "node_extra_ca=$CA"
  echo "claude_sha256=$(sha256sum /usr/local/bin/claude | cut -d' ' -f1)"; echo "pkg_sha256=$(cat "$B/pkg.sha256")"
} >"$B/launch/identity.tmp"
mv "$B/launch/identity.tmp" "$B/launch/identity"
[ "$KF" = placeholder ] || { echo "exp008c-launch: ANTHROPIC_API_KEY is $KF, not an OpenShell placeholder; not starting the agent" >&2; exit 1; }

export EXP008_ANTHROPIC_KEYREF EXP008_NONCE="$NONCE" HOME="$B/home" CLAUDE_CONFIG_DIR="$B/claude" TMPDIR="$B/tmp" \
  XDG_CONFIG_HOME="$B/xdg/config" XDG_STATE_HOME="$B/xdg/state" XDG_CACHE_HOME="$B/xdg/cache" XDG_DATA_HOME="$B/xdg/data" \
  SHELL=/bin/bash LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
  DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
cd "$B/repo"
exec /usr/local/bin/claude --bare --settings "$B/settings.json" --strict-mcp-config --tools Bash \
  --model claude-haiku-5-5 --effort medium --session-id "$SID" "$(cat "$P/prompt.txt")"
