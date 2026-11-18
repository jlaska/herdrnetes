#!/usr/bin/env bash
# EXP-004 quick live check (owner-run, option A). Replaces the L00-L17 issuer session.
#
#   quick-check.sh <app-id> <installation-id> <private-key.pem> <owner> <repo-a> <repo-b>
#
# Observes real GitHub behaviour for App installation tokens, with no issuer, systemd unit or
# installer. Run it in your own terminal with every agent on this account stopped. It never
# prints a token: tokens live only in shell variables and reach git through a credential helper
# that reads the environment, and reach curl through a config on stdin (never argv or URLs).
# The global Git config is ignored, so no signing key, YubiKey or credential store is touched.
#
# Expected App setup: installed on <repo-a> only; Contents read/write, Metadata read; no
# Workflows or Issues permission. It pushes one probe branch to <repo-a> and deletes it again.
# Exit 0 if every check matched its expectation, otherwise 1.

set -euo pipefail
set +x
[ $# -eq 6 ] || { sed -n '4p' "$0"; exit 2; }
APP_ID=$1 INST=$2 KEY=$3 OWNER=$4 REPO_A=$5 REPO_B=$6
API=https://api.github.com
BRANCH=exp004-probe-$(date +%s)

if pgrep -u "$(id -u)" -x 'claude|codex|herdr|opencode' >/dev/null; then
  echo "refusing: agent processes are running under this account (claude, codex, herdr, opencode)" >&2
  exit 2
fi

WORK=$(mktemp -d)
chmod 700 "$WORK"
T_RO="" T_RW=""
FAILS=0

redact() { sed -E -f "$(dirname "$0")/redact.sed"; }

# api METHOD PATH BEARER [JSON] -> prints HTTP status; body in $WORK/body
api() {
  local data=()
  [ $# -ge 4 ] && data=(--data "$4")
  printf 'header = "Authorization: Bearer %s"\n' "$3" |
    curl -sS -o "$WORK/body" -w '%{http_code}' -K - -X "$1" \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
      "${data[@]}" "$API$2"
}

jwt() {
  local now h p s
  now=$(date +%s)
  b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
  p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$KEY" -binary | b64)
  printf '%s.%s.%s' "$h" "$p" "$s"
}

# mint JSON -> sets MINT_CODE, MINT_TOKEN
mint() {
  MINT_TOKEN=""
  MINT_CODE=$(api POST "/app/installations/$INST/access_tokens" "$(jwt)" "$1")
  [ "$MINT_CODE" = 201 ] && MINT_TOKEN=$(jq -r .token "$WORK/body")
  return 0
}

revoke() { [ -n "$1" ] && api DELETE /installation/token "$1"; }

cleanup() {
  [ -n "$T_RW" ] && git_t "$T_RW" -C "$WORK/a" push -q origin --delete "$BRANCH" >/dev/null 2>&1 || true
  [ -n "$T_RW" ] && revoke "$T_RW" >/dev/null || true
  [ -n "$T_RO" ] && revoke "$T_RO" >/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# git_t TOKEN git-args... : git with only this token, no global/system config, no prompts
git_t() {
  local tok=$1; shift
  T="$tok" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= \
        -c credential.helper='!f() { echo username=x-access-token; echo "password=$T"; }; f' \
        -c user.name=exp004-probe -c user.email=exp004-probe@invalid -c commit.gpgsign=false \
        "$@"
}

# check ID DESCRIPTION EXPECTED OBSERVED
check() {
  local r=PASS
  [ "$3" = "$4" ] || { r=FAIL; FAILS=$((FAILS + 1)); }
  printf '%-4s %-4s %-58s expected=%-8s observed=%s\n' "$1" "$r" "$2" "$3" "$4"
}

ok() { if "$@" >"$WORK/err" 2>&1; then echo ok; else echo refused; fi; }

URL_A=https://github.com/$OWNER/$REPO_A.git
URL_B=https://github.com/$OWNER/$REPO_B.git

echo "EXP-004 quick check  $(date -u +%FT%TZ)  git $(git --version | cut -d' ' -f3)"

mint '{"repositories":["'"$REPO_A"'"],"permissions":{"contents":"read","metadata":"read"}}'
check Q01 "mint read-only token for repo a" 201 "$MINT_CODE"
T_RO=$MINT_TOKEN
mint '{"repositories":["'"$REPO_A"'"],"permissions":{"contents":"write","metadata":"read"}}'
check Q02 "mint read-write token for repo a" 201 "$MINT_CODE"
T_RW=$MINT_TOKEN
[ -n "$T_RO" ] && [ -n "$T_RW" ] || { echo "cannot continue without both tokens" >&2; exit 1; }
echo "     token length: ro=${#T_RO} rw=${#T_RW} (prefix ${T_RW:0:4})"

mint '{"repositories":["'"$REPO_B"'"],"permissions":{"contents":"read"}}'
check Q03 "mint for repo b (App not installed there) is refused" 422 "$MINT_CODE"
revoke "$MINT_TOKEN" >/dev/null || true
mint '{"repositories":["'"$REPO_A"'"],"permissions":{"contents":"read","issues":"write"}}'
check Q04 "mint with a permission the App lacks is refused" 422 "$MINT_CODE"
revoke "$MINT_TOKEN" >/dev/null || true

check Q05 "read-only token clones repo a" ok "$(ok git_t "$T_RO" clone -q "$URL_A" "$WORK/ro")"
check Q06 "read-write token clones repo a" ok "$(ok git_t "$T_RW" clone -q "$URL_A" "$WORK/a")"
check Q07 "read-write token cannot clone repo b" refused "$(ok git_t "$T_RW" clone -q "$URL_B" "$WORK/b")"
redact <"$WORK/err" | head -2 | sed 's/^/     /'

git_t "$T_RW" -C "$WORK/a" switch -q -c "$BRANCH"
date -u +%FT%TZ >"$WORK/a/exp004-probe.txt"
git_t "$T_RW" -C "$WORK/a" add exp004-probe.txt
git_t "$T_RW" -C "$WORK/a" commit -q -m "exp-004 probe (deleted by quick-check.sh)"
check Q08 "read-write token pushes a probe branch to repo a" ok \
  "$(ok git_t "$T_RW" -C "$WORK/a" push -q origin "$BRANCH")"

git -C "$WORK/ro" fetch -q "$WORK/a" "$BRANCH:$BRANCH" 2>/dev/null
git -C "$WORK/ro" switch -q "$BRANCH"
date -u +%FT%TZ >>"$WORK/ro/exp004-probe.txt"
GIT_CONFIG_GLOBAL=/dev/null git -C "$WORK/ro" -c user.name=exp004-probe -c user.email=exp004-probe@invalid \
  -c commit.gpgsign=false commit -qam "exp-004 probe (read-only)"
check Q09 "read-only token cannot push" refused "$(ok git_t "$T_RO" -C "$WORK/ro" push -q origin "$BRANCH")"
redact <"$WORK/err" | head -2 | sed 's/^/     /'

mkdir -p "$WORK/a/.github/workflows"
printf 'on: workflow_dispatch\njobs: {}\n' >"$WORK/a/.github/workflows/exp004-probe.yml"
git_t "$T_RW" -C "$WORK/a" add .github
git_t "$T_RW" -C "$WORK/a" commit -q -m "exp-004 probe workflow (must be refused)"
check Q10 "read-write token cannot push a workflow file" refused \
  "$(ok git_t "$T_RW" -C "$WORK/a" push -q origin "$BRANCH")"
redact <"$WORK/err" | head -2 | sed 's/^/     /'

code=$(api GET "/repos/$OWNER/$REPO_A/activity?ref=refs/heads/$BRANCH&per_page=1" "$T_RW")
actor=$( [ "$code" = 200 ] && jq -r '.[0].actor.login // "none"' "$WORK/body" || echo "http-$code")
echo "     Q11 info: push recorded as actor: $actor"

check Q12 "delete probe branch" ok "$(ok git_t "$T_RW" -C "$WORK/a" push -q origin --delete "$BRANCH")"

check Q13 "revoke read-write token" 204 "$(revoke "$T_RW")"
start=$(date +%s); code=""
for _ in $(seq 1 30); do
  code=$(api GET /installation/repositories "$T_RW")
  [ "$code" = 401 ] && break
  sleep 1
done
check Q14 "revoked token is rejected by the API" 401 "$code"
echo "     rejected after $(( $(date +%s) - start ))s"
check Q15 "revoked token cannot clone repo a" refused "$(ok git_t "$T_RW" ls-remote "$URL_A")"
T_RW=""

check Q16 "revoke read-only token" 204 "$(revoke "$T_RO")"
T_RO=""

echo "failures: $FAILS"
[ "$FAILS" -eq 0 ]
