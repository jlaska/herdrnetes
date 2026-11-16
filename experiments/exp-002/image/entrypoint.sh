#!/bin/bash
# EXP-002 pod entrypoint (runs under tini as uid 1000).
#
# 1. Prepare the persistent home (a PVC mounted at $HOME) without touching
#    anything a user already owns.
# 2. Reconcile Herdr's version-matched agent integration hooks from the binary
#    in *this* image (EXP-002 hook strategy "R", see docs/experiments/02-*.md).
# 3. exec the headless Herdr server with an explicit, minimal environment:
#    every variable the server sees reaches every pane and agent (FIND-011).
set -euo pipefail

log() { printf '%s herdr-entrypoint: %s\n' "$(date -u +%FT%T.%3NZ)" "$*" >&2; }

: "${HOME:=/home/herdr}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=/run/herdr/state}"
: "${XDG_CACHE_HOME:=/run/herdr/cache}"
: "${HERDR_CONFIG_PATH:=/etc/herdrnetes/config.toml}"
export HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME HERDR_CONFIG_PATH

log "start $(head -4 /usr/share/herdrnetes/manifest.txt | tr '\n' ' ')"

if [ ! -w "$HOME" ]; then
  log "HOME $HOME is not writable (is the home volume mounted?)"
  exit 1
fi
mkdir -p "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$HOME/.claude" "$HOME/.codex"

# Codex: disable startup update checks and keyring use, only on first start.
if [ ! -e "$HOME/.codex/config.toml" ]; then
  printf 'check_for_update_on_startup = false\ncli_auth_credentials_store = "file"\n' >"$HOME/.codex/config.toml"
  log "seeded ~/.codex/config.toml"
fi

# Claude Code: skip first-run onboarding only if no state exists yet.
if [ ! -e "$HOME/.claude.json" ]; then
  printf '{"hasCompletedOnboarding": true, "theme": "dark"}\n' >"$HOME/.claude.json"
  log "seeded ~/.claude.json"
fi

# Hook reconciliation: `herdr integration install` overwrites its own hook
# script, merges only Herdr's entries into settings.json/hooks.json and leaves
# user hooks alone (herdr v0.9.5 src/integration). Running it on every start
# makes the persisted hook match the Herdr binary in this image, including
# after an image rollback. HERDRNETES_HOOKS=skip disables it for comparison.
if [ "${HERDRNETES_HOOKS:-reconcile}" = reconcile ]; then
  for target in claude codex; do
    if out=$(herdr integration install "$target" 2>&1); then
      log "integration install $target: ok"
    else
      log "integration install $target FAILED: $out"
    fi
  done
  herdr integration status 2>&1 | sed 's/^/herdr-entrypoint: integration status: /' >&2 || true
else
  log "hook reconciliation skipped (HERDRNETES_HOOKS=${HERDRNETES_HOOKS})"
fi

# Allowlisted server environment. Credentials, when supplied, are passed by
# name only; their values never appear in logs.
env_args=(
  "HOME=$HOME" "USER=herdr" "LOGNAME=herdr" "SHELL=/usr/local/bin/pane-shell"
  "PATH=/usr/local/bin:/usr/bin:/bin" "LANG=${LANG:-C.UTF-8}" "TERM=xterm-256color"
  "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" "XDG_STATE_HOME=$XDG_STATE_HOME" "XDG_CACHE_HOME=$XDG_CACHE_HOME"
  "TMPDIR=${TMPDIR:-/tmp}" "HERDR_CONFIG_PATH=$HERDR_CONFIG_PATH"
  "DISABLE_AUTOUPDATER=1" "DISABLE_UPDATES=1" "DISABLE_TELEMETRY=1" "DISABLE_ERROR_REPORTING=1"
  "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1"
)
for var in HERDR_SOCKET_PATH CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY TZ; do
  if [ -n "${!var:-}" ]; then
    env_args+=("$var=${!var}")
    log "passing $var to server"
  fi
done

log "exec herdr server"
exec env -i "${env_args[@]}" /usr/local/bin/herdr server
