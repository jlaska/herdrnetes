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
# - Leaves OpenShell's placeholder in ANTHROPIC_API_KEY, which Claude Code sends ONLY as X-Api-Key, the one
#   placement the provider profile permits. Run 1125-2153 used an apiKeyHelper instead; Claude Code 2.1.323
#   also sends a helper's value as "Authorization: Bearer" (static review of the pinned binary), and OpenShell
#   v0.1.9 refused all 12 model requests with credential_placement_mismatch.
# - Pre-approves that key for Claude Code's interactive "Detected a custom API key ... use this API key?"
#   check (EXP-008 D6) the way Claude Code itself records an approval: customApiKeyResponses.approved holds
#   key.trim().slice(-20) (pinned binary, static review). The 20 characters are the TAIL OF THE PLACEHOLDER,
#   not of the real key, which never enters the sandbox; they are not a resolvable placeholder.
set -eu
B=/sandbox/c
P=$B/pkg
umask 077
[ ! -e "$B/repo" ] || { echo "exp008c-launch: $B/repo exists; refusing to reuse state" >&2; exit 1; }
mkdir -p "$B/repo" "$B/claude" "$B/home" "$B/launch" "$B/tmp" "$B/xdg/config" "$B/xdg/state" "$B/xdg/cache" "$B/xdg/data"
install -m 0755 "$P/step.sh" "$B/repo/step.sh"
cp "$P/prompt.txt" "$B/repo/TASK.txt"
cp "$P/settings.json" "$B/settings.json"
pp="openshell"; pp="$pp:resolve:" # assembled: never literal in an agent-readable file
case ${ANTHROPIC_API_KEY:-} in
'') KF=absent ;;
"$pp"*) KF=placeholder ;;
sk-ant-*) KF=REAL-KEY-SHAPE ;;
*) KF=other ;;
esac
# No Bearer-capable credential source may reach claude (security review 2026-11-26): only the placeholder above.
unset CLAUDE_API_KEY EXP008_ANTHROPIC_KEYREF ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
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
# Approval tail: Claude Code trims and keeps the last 20 characters. Refuse anything that is not a plain
# token, so trimming cannot change the tail and the tail is JSON-safe without escaping.
case $ANTHROPIC_API_KEY in *[!A-Za-z0-9:_.-]*) echo "exp008c-launch: placeholder has unexpected characters; not starting the agent" >&2; exit 1 ;; esac
AT=$(printf %s "$ANTHROPIC_API_KEY" | tail -c 20)
[ "${#AT}" -eq 20 ] || { echo "exp008c-launch: placeholder shorter than 20 characters; not starting the agent" >&2; exit 1; }
# First-run state (EXP-006 entrypoint-agent.sh:98 pattern): onboarding done, folder trust accepted, key approved.
printf '{"hasCompletedOnboarding": true, "theme": "dark", "customApiKeyResponses": {"approved": ["%s"], "rejected": []}, "projects": {"%s": {"hasTrustDialogAccepted": true}, "%s": {"hasTrustDialogAccepted": true}}}\n' "$AT" "$B/repo" "$B" >"$B/claude/.claude.json"
cp "$B/claude/.claude.json" "$B/home/.claude.json"
unset AT

export EXP008_NONCE="$NONCE" HOME="$B/home" CLAUDE_CONFIG_DIR="$B/claude" TMPDIR="$B/tmp" \
  XDG_CONFIG_HOME="$B/xdg/config" XDG_STATE_HOME="$B/xdg/state" XDG_CACHE_HOME="$B/xdg/cache" XDG_DATA_HOME="$B/xdg/data" \
  SHELL=/bin/bash LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
  DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
cd "$B/repo"
exec /usr/local/bin/claude --bare --settings "$B/settings.json" --strict-mcp-config --tools Bash \
  --model claude-haiku-5-5 --effort medium --session-id "$SID" "$(cat "$P/prompt.txt")"
