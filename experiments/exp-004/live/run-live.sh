#!/usr/bin/env bash
# EXP-004 live matrix against GitHub: client side, OWNER-RUN ONLY (see live/RUNBOOK.md).
# Talks to the owner-run issuer (separate OS user) through the credential helper. Never prints a
# token, never calls sudo: every admin step is a prompt for the owner to run from root-owned paths.
#
#   live/run-live.sh <github-owner> <run-id> [--expiry] [--manual-scope]
#
# Env: EXP004_ISSUER_SOCK (default /run/exp004-issuer/issuer.sock), EXP004_LIVE_CLIENTS (client
# files, default ~/.config/exp004-live), EXP004_LIVE_EVIDENCE (default $XDG_DATA_HOME/exp004-live).
# shellcheck disable=SC2015 # `cond && rec PASS || rec FAIL`: rec always returns 0
set -euo pipefail
set +x
unset GIT_TRACE GIT_TRACE_CURL GIT_TRACE_PACKET GIT_TRACE_REDACT GIT_CURL_VERBOSE

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
die() { echo "run-live: $*" >&2; exit 3; }

[ $# -ge 2 ] || die "usage: $0 <github-owner> <run-id> [--expiry] [--manual-scope]"
OWNER=$1 RUN=$2; shift 2
EXPIRY=0 MANUAL_SCOPE=0
for a in "$@"; do case $a in --expiry) EXPIRY=1 ;; --manual-scope) MANUAL_SCOPE=1 ;; *) die "unknown option $a" ;; esac; done
[[ $OWNER =~ ^[A-Za-z0-9-]+$ ]] || die "bad owner"
[[ $RUN =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "bad run id"
# Owner condition (#5): every autonomous agent stays stopped for the whole live-issuer session.
if pgrep -fa '(^|/)(claude|codex)( |$)|claude-code|@anthropic-ai|@openai/codex' >/dev/null; then
    die "an agent process is running (pgrep -fa 'claude|codex'); stop all agents before live tests"
fi

# Only these two repositories, ever (G1).
A=herdrnetes-exp004-a B=herdrnetes-exp004-b
URL_A="https://github.com/$OWNER/$A.git" URL_B="https://github.com/$OWNER/$B.git"
CTL='sudo -u exp004-issuer /usr/bin/python3 /usr/local/libexec/exp004/harness/issuer-ctl.py /run/exp004-issuer/issuer.sock --admin-secret /var/lib/exp004-issuer/admin.secret'

export EXP004_ISSUER_SOCK=${EXP004_ISSUER_SOCK:-/run/exp004-issuer/issuer.sock} EXP004_HOST=github.com
CLIENTS=${EXP004_LIVE_CLIENTS:-$HOME/.config/exp004-live}
EVID=${EXP004_LIVE_EVIDENCE:-${XDG_DATA_HOME:-$HOME/.local/share}/exp004-live}/$RUN
case "$(realpath -m "$EVID")/" in "$REPO_ROOT"/*) die "evidence dir must be outside the repository" ;; esac
mkdir -p "$EVID"; chmod 700 "$EVID"
T=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/e4l.XXXXXX")   # isolated HOME, worktrees, captured tokens
trap 'rm -rf "$T"' EXIT
# The owner's gh (read-only repo/ruleset/activity queries) keeps the real HOME and Git config.
REAL_HOME=$HOME
gh() { env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM HOME="$REAL_HOME" gh "$@"; }
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/home/.gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false
unset SSH_ASKPASS SSH_AUTH_SOCK GH_TOKEN GITHUB_TOKEN
mkdir -p "$HOME" "$T/sec" "$T/out"; chmod 700 "$T/sec"
cat >"$GIT_CONFIG_GLOBAL" <<EOF
[user]
	name = EXP-004 live agent
	email = exp004-agent@example.invalid
[credential]
	helper =
	helper = $HERE/harness/git-credential-exp004
	useHttpPath = true
EOF
cat >"$T/replay" <<'EOF'
#!/bin/sh
[ "$1" = get ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$(cat "$REPLAY_FILE")"
EOF
chmod 700 "$T/replay"

RES=$EVID/results.tsv
printf 'id\toutcome\texpected\tobserved\telapsed_s\n' >"$RES"
# Strip anything token-, JWT- or base64-shaped, incl. ~520-char stateless tokens (commit SHAs too;
# record those deliberately). Same expressions are tested offline (tests/run-github-offline.sh G36).
redact() { sed -E -f "$HERE/live/redact.sed"; }
rec() { # rec <id> <outcome> <expected> <observed>
    local obs; obs=$(printf %s "$4" | tr '\n\t' '  ' | redact | cut -c1-300)
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$obs" "${EL:-}" >>"$RES"
    printf '%-10s %-5s %s — %s\n' "$2" "$1" "$3" "$obs"
}
pause() { printf '\n>>> %s\n    Press Enter when done (or type skip): ' "$1" >/dev/tty; read -r REPLY </dev/tty; [ "$REPLY" != skip ]; }
cf() { [ -f "$CLIENTS/$1.json" ] || die "missing client file $CLIENTS/$1.json"; echo "$CLIENTS/$1.json"; }
# run <id> <client> <access> <cmd...>: git as an agent; RC, EL, ERR (sanitized remote/fatal lines)
run() {
    local id=$1 c=$2 acc=$3 t0; shift 3
    t0=$(date +%s.%N)
    set +e
    EXP004_CLIENT_FILE=$(cf "$c") EXP004_ACCESS=$acc timeout 90 "$@" >"$T/out/$id.out" 2>"$T/out/$id.err" </dev/null
    RC=$?; set -e
    EL=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}')
    ERR=$(grep -E 'remote:|fatal:|error:|exp004:|denied|rule|GH0' "$T/out/$id.err" | head -6 | redact || true)
}
# capture <client> <access> <owner/repo>: mint through the helper; token only into $T/sec/tok
capture() {
    EXP004_CLIENT_FILE=$(cf "$1") EXP004_ACCESS=$2 "$HERE/harness/git-credential-exp004" get \
        <<<"$(printf 'protocol=https\nhost=github.com\npath=%s.git\n' "$3")" 2>"$T/out/capture.err" |
        sed -n 's/^password=//p' >"$T/sec/tok"
    [ -s "$T/sec/tok" ]
}
replay() { # replay <url>: ls-remote with the captured token only
    set +e
    REPLAY_FILE=$T/sec/tok timeout 30 git -c credential.helper= -c "credential.helper=$T/replay" ls-remote "$1" >/dev/null 2>"$T/out/replay.err"
    RC=$?; set -e
}

echo "run-live $RUN: $(sha256sum "$0" | cut -c1-16) run-live.sh, $(sha256sum "$HERE/harness/git-credential-exp004" | cut -c1-16) helper; git $(git --version | cut -d' ' -f3)"
[ -S "$EXP004_ISSUER_SOCK" ] || die "issuer socket $EXP004_ISSUER_SOCK not found (RUNBOOK phase 3)"

# --- L00: repository identity and visibility (owner's gh, read-only) ---
for r in $A $B; do
    v=$(gh repo view "$OWNER/$r" --json visibility,isEmpty --jq '.visibility' 2>/dev/null) || die "cannot view $OWNER/$r"
    [ "$v" = PRIVATE ] || die "$OWNER/$r is $v, not PRIVATE"
done
rec L00 PASS "both test repos exist and are PRIVATE" "$A, $B private"

# --- L01-L04: read and write on the in-scope repository ---
run L01 agent-ro read git clone -q "$URL_A" "$T/ro"
[ $RC -eq 0 ] && rec L01 PASS "clone a with read client" "exit 0" || rec L01 FAIL "clone a with read client" "exit $RC $ERR"
run L02 agent-ro read git -C "$T/ro" fetch -q
[ $RC -eq 0 ] && rec L02 PASS "fetch a" "exit 0" || rec L02 FAIL "fetch a" "exit $RC $ERR"

git clone -q "$T/ro" "$T/rw" 2>/dev/null; git -C "$T/rw" remote set-url origin "$URL_A"
date -u +%FT%TZ >"$T/rw/live-$RUN.txt"; git -C "$T/rw" add . ; git -C "$T/rw" commit -qm "exp004 live $RUN"
run L03 agent-rw write git -C "$T/rw" push -q origin "HEAD:refs/heads/exp004/live-$RUN"
[ $RC -eq 0 ] && rec L03 PASS "push exp004/live-$RUN with write client" "exit 0, commit $(git -C "$T/rw" rev-parse --short HEAD)" ||
    rec L03 FAIL "push with write client" "exit $RC $ERR"
run L04 agent-ro read git -C "$T/rw" push -q origin "HEAD:refs/heads/exp004/ro-$RUN"
[ $RC -ne 0 ] && rec L04 PASS "push with read-only token rejected by GitHub" "exit $RC $ERR" || rec L04 FAIL "push with read-only token" "unexpectedly succeeded"

# --- L05-L08: scope ---
run L05 agent-rw write git clone -q "$URL_B" "$T/b"
[ $RC -ne 0 ] && grep -q 'not in policy' "$T/out/L05.err" && rec L05 PASS "repo b refused by issuer policy" "exit $RC $ERR" ||
    rec L05 FAIL "repo b refused by issuer policy" "exit $RC $ERR"
run L06 probe-b probe git ls-remote "$URL_B"
[ $RC -ne 0 ] && rec L06 PASS "GitHub refuses a mint for a repo outside the installation" "exit $RC $ERR" ||
    rec L06 FAIL "mint for repo b" "unexpectedly succeeded"
run L07 probe-perm probe git ls-remote "$URL_A"
[ $RC -ne 0 ] && rec L07 PASS "GitHub refuses permissions beyond the installation (workflows)" "exit $RC $ERR" ||
    rec L07 FAIL "over-requested permissions" "unexpectedly succeeded"
if capture agent-ro read "$OWNER/$A"; then
    replay "$URL_B"; e=$(grep -E 'fatal|not found' "$T/out/replay.err" | head -2 | redact)
    [ $RC -ne 0 ] && rec L08 PASS "token for a replayed against b" "exit $RC $e" || rec L08 FAIL "token for a against b" "unexpectedly succeeded"
else rec L08 FAIL "capture token" "$(redact <"$T/out/capture.err")"; fi

# --- L09: token revocation latency (DELETE /installation/token via the helper's erase) ---
if capture agent-ro read "$OWNER/$A"; then
    replay "$URL_A"; before=$RC
    printf 'protocol=https\nhost=github.com\npath=%s.git\npassword=%s\n' "$OWNER/$A" "$(cat "$T/sec/tok")" |
        EXP004_CLIENT_FILE=$(cf agent-ro) "$HERE/harness/git-credential-exp004" erase
    t0=$(date +%s); n=0
    while [ $n -lt 60 ]; do replay "$URL_A"; [ $RC -ne 0 ] && break; sleep 1; n=$((n + 1)); done
    EL=$(( $(date +%s) - t0 ))
    [ "$before" -eq 0 ] && [ $RC -ne 0 ] && rec L09 PASS "revoked token rejected" "valid before; rejected after ${EL}s ($(grep -m1 -E 'fatal' "$T/out/replay.err" | redact))" ||
        rec L09 FAIL "revoked token rejected" "before=$before after=$RC (${EL}s)"
fi
EL=

# --- L10: issuer client revocation vs. outstanding GitHub tokens ---
if capture agent-rw write "$OWNER/$A" && pause "In ANOTHER terminal run: $CTL revoke_client --client agent-rw"; then
    replay "$URL_A"; old=$RC
    run L10 agent-rw write git -C "$T/rw" fetch -q
    { [ $RC -ne 0 ] && [ $old -ne 0 ]; } && rec L10 PASS "revoke_client refuses new mints AND revoked the outstanding token at GitHub" "new: $ERR; old token exit $old" ||
        rec L10 FAIL "revoke_client" "new mint exit $RC; outstanding token exit $old (0 = still valid at GitHub)"
    pause "Now run: $CTL reinstate_client --client agent-rw" || true
else rec L10 UNTESTED "revoke_client" "skipped by owner"; fi

# --- L11: issuer down (revoke-on-exit) ---
if capture agent-ro read "$OWNER/$A" && pause "In ANOTHER terminal run: sudo systemctl stop exp004-issuer; sudo journalctl -u exp004-issuer -n 3
    A CRITICAL line / non-zero status means revocation is INCOMPLETE: follow RUNBOOK 'Revocation fallback'"; then
    run L11 agent-ro read git -C "$T/ro" fetch -q
    replay "$URL_A"
    { [ $RC -ne 0 ] && grep -q 'issuer unavailable' "$T/out/L11.err"; } &&
        rec L11 PASS "issuer stopped: fetch fails closed and outstanding token revoked on exit" "fetch: $ERR; old token exit $RC" ||
        rec L11 FAIL "issuer stopped" "fetch: $ERR; outstanding token exit $RC (0 = still valid)"
    pause "Restart the issuer: sudo /usr/local/libexec/exp004/live/issuer-start.sh" || die "issuer needed for remaining tests"
else rec L11 UNTESTED "issuer down" "skipped by owner"; fi

# --- L12-L13: GitHub-side policy (rulesets, workflows permission) ---
if n=$(gh api "repos/$OWNER/$A/rulesets" --jq length 2>/dev/null) && [ "${n:-0}" -ge 2 ]; then
    git -C "$T/rw" commit -q --allow-empty -m "exp004 main attempt $RUN"
    run L12a agent-rw write git -C "$T/rw" push -q origin HEAD:refs/heads/main
    [ $RC -ne 0 ] && rec L12a PASS "push to main blocked by ruleset (no App bypass)" "exit $RC $ERR" || rec L12a FAIL "push to main" "unexpectedly succeeded"
    run L12b agent-rw write git -C "$T/rw" push -q origin "HEAD:refs/heads/signed/live-$RUN"
    [ $RC -ne 0 ] && rec L12b PASS "unsigned push to signed/** blocked by ruleset" "exit $RC $ERR" || rec L12b FAIL "unsigned push to signed/**" "unexpectedly succeeded"
else rec L12 BLOCKED "rulesets on a" "no rulesets visible (plan may not support rulesets on private repos)"; fi
mkdir -p "$T/rw/.github/workflows"
printf 'name: exp004-noop\non: workflow_dispatch\njobs: {noop: {runs-on: ubuntu-latest, steps: [{run: "true"}]}}\n' >"$T/rw/.github/workflows/exp004-noop.yml"
git -C "$T/rw" add . && git -C "$T/rw" commit -qm "exp004 workflow attempt $RUN"
run L13 agent-rw write git -C "$T/rw" push -q origin "HEAD:refs/heads/exp004/wf-$RUN"
[ $RC -ne 0 ] && rec L13 PASS "workflow file push refused without workflows permission" "exit $RC $ERR" ||
    rec L13 FAIL "workflow file push" "accepted (workflow is workflow_dispatch only; delete branch exp004/wf-$RUN)"
git -C "$T/rw" reset -q --hard HEAD~1

# --- L14: who GitHub says pushed (owner's gh, read-only) ---
act=$(gh api "repos/$OWNER/$A/activity?ref=refs/heads/exp004/live-$RUN" --jq '.[0] | "\(.activity_type) by \(.actor.login)"' 2>/dev/null || echo unavailable)
rec L14 NOTE "push attribution for exp004/live-$RUN" "$act"

# --- L15: leak scan (counts only) ---
GIT_TRACE=1 GIT_TRACE_CURL=1 EXP004_CLIENT_FILE=$(cf agent-ro) git -C "$T/ro" fetch -q 2>"$T/trace.log" || true
hits=$(grep -rlE 'gh[a-z]_[A-Za-z0-9_]{8,}|eyJ[A-Za-z0-9_-]{20,}' "$HOME" "$T/ro" "$T/rw" "$T/trace.log" "$EVID" 2>/dev/null | wc -l)
url=$(git -C "$T/ro" remote get-url origin; git -C "$T/rw" remote get-url origin)
rm -f "$T/trace.log"
{ [ "$hits" -eq 0 ] && ! grep -q @ <<<"$url"; } && rec L15 PASS "no token/JWT in HOME, worktrees, .git/config, default curl trace, evidence; remotes credential-free" "0 files" ||
    rec L15 FAIL "leak scan" "$hits files matched (inspect privately)"
echo "    also check the issuer journal yourself: sudo journalctl -u exp004-issuer | grep -cE 'gh[a-z]_|eyJ'  (expect 0)"

# --- L16: real one-hour expiry (optional) ---
if [ $EXPIRY = 1 ] && capture agent-ro read "$OWNER/$A"; then
    echo "    waiting 61 minutes for real token expiry..."; sleep 3660; replay "$URL_A"
    [ $RC -ne 0 ] && rec L16 PASS "token rejected after expiry (~1 h)" "exit $RC" || rec L16 FAIL "token after 61 min" "still valid"
else rec L16 UNTESTED "real 1 h expiry" "not run (--expiry)"; fi

# --- L17: removing the repo from the installation (optional, manual) ---
if [ $MANUAL_SCOPE = 1 ] && capture agent-ro read "$OWNER/$A" &&
    pause "In GitHub: App installation settings -> remove $A from the installation"; then
    replay "$URL_A"; rec L17 NOTE "outstanding token after repo removed from installation" "exit $RC (0 = still valid)"
    pause "Re-add $A to the installation (or skip if cleaning up)" || true
else rec L17 UNTESTED "repo removal vs outstanding token" "not run (--manual-scope)"; fi

echo; echo "results: $RES (sanitized; review before sharing)"
grep -c $'\tFAIL\t' "$RES" >/dev/null && exit 1 || exit 0
