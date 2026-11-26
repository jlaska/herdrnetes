#!/bin/sh
# EXP-008 Stage C4 launcher (state-aware): the sandbox's canonical main process; execs Claude Code.
# Started by the bootstrap argv in ../launcher4.sh after the package's sha256 was verified. OpenShell
# relaunches the SAME canonical command on `sandbox start` (OpenShell v0.1.9 driver.rs:4426, 6414-6424), so
# this launcher chooses its mode from the state it finds (proposal STAGE-C4-PROPOSAL.md section 5.2):
#
#   Fresh   neither /sandbox/c/repo nor /sandbox/c/state-id exists: as the C0-C3 launcher
#           (../../stage-c/task/launch.sh), plus a random state id and the session id recorded on the PVC.
#   Resume  both exist: verify the state, freeze a copy of it (launch/pre-<k>/) and a summary
#           (launch/precheck-<k>), then exec `claude --resume <sid>` with the same flags, NO --session-id,
#           NO positional prompt, the same CLAUDE_CONFIG_DIR, HOME and cwd.
#   Refuse  exactly one of them exists (a partial first launch), or the state is unreadable, missing or
#           inconsistent: exit nonzero WITHOUT starting Claude Code. Never falls back to a fresh session.
#
# Credential handling is the C0-C3 launcher's, unchanged: the OpenShell placeholder stays in ANTHROPIC_API_KEY
# (sent only as X-Api-Key); Bearer-capable sources are unset; the interactive custom-key check is
# pre-answered with key.trim().slice(-20) of the PLACEHOLDER (never the real key, which never enters the
# sandbox). Values are never printed or stored; only fixed form words are recorded.
# Resume also unsets Claude Code's auto-continue variables (approved design: plain --resume is measured) and
# records the NAMES (never values) of all CLAUDE_CODE_* variables present.
set -eu
B=/sandbox/c
P=$B/pkg
umask 077
STEP_SLEEP=45
refuse() { echo "exp008c4-launch: $*; not starting the agent" >&2; [ -d "$B/launch" ] && printf 'refused=%s\nutc=%s\n' "$*" "$(date -u +%FT%T.%3NZ)" >>"$B/launch/refusals"; exit 1; }
h() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo absent; fi; }

if [ ! -e "$B/repo" ] && [ ! -e "$B/state-id" ]; then MODE=fresh
elif [ -d "$B/repo" ] && [ -f "$B/state-id" ]; then MODE=resume
else mkdir -p "$B/launch"; refuse "partial state (repo=$([ -e "$B/repo" ] && echo present || echo absent) state-id=$([ -e "$B/state-id" ] && echo present || echo absent))"; fi

pp="openshell"; pp="$pp:resolve:" # assembled: never literal in an agent-readable file
case ${ANTHROPIC_API_KEY:-} in
'') KF=absent ;;
"$pp"*) KF=placeholder ;;
sk-ant-*) KF=REAL-KEY-SHAPE ;;
*) KF=other ;;
esac
# names (never values) of the CLAUDE_CODE_* variables as received, before anything is unset
CCV=$(env | sed -n 's/^\(CLAUDE_CODE_[A-Z0-9_]*\)=.*/\1/p' | sort | tr '\n' ',' | sed 's/,$//')
# No Bearer-capable credential source may reach claude (Stage C security review 2026-11-26): only the placeholder.
unset CLAUDE_API_KEY EXP008_ANTHROPIC_KEYREF ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
# Plain --resume is what is measured: no automatic resubmission of the interrupted turn (proposal CR4), and no
# other resume knob of 2.1.323 (every CLAUDE_CODE_RESUME_* variable is removed; names recorded above).
unset CLAUDE_CODE_RESUME_INTERRUPTED_TURN CLAUDE_CODE_RESUME_PROMPT CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS
for v in $(env | sed -n 's/^\(CLAUDE_CODE_RESUME_[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
START=$(sed 's/.*) //' /proc/$$/stat | awk '{print $20}')
CA=$( [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && [ -r "${NODE_EXTRA_CA_CERTS:-/nonexistent}" ] && echo readable || echo missing)
mkdir -p "$B/launch"
K=1; for f in "$B"/launch/identity-*; do [ -e "$f" ] && K=$((K + 1)); done

if [ "$MODE" = fresh ]; then
  mkdir -p "$B/repo" "$B/claude" "$B/home" "$B/tmp" "$B/xdg/config" "$B/xdg/state" "$B/xdg/cache" "$B/xdg/data"
  install -m 0755 "$P/step.sh" "$B/repo/step.sh"
  cp "$P/prompt.txt" "$B/repo/TASK.txt"
  cp "$P/settings.json" "$B/settings.json"
  SID=$(cat /proc/sys/kernel/random/uuid)
  printf '%s\n' "$SID" >"$B/launch/sid"
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$B/state-id.tmp" && mv "$B/state-id.tmp" "$B/state-id"
else
  SID=$(cat "$B/launch/sid" 2>/dev/null || true)
  case $SID in [0-9a-f]*-*-*-*-*) ;; *) refuse "session id missing or malformed" ;; esac
  [ "${#SID}" -eq 36 ] || refuse "session id malformed"
fi
SIDF=$(h "$B/state-id")
case $(cat "$B/state-id" 2>/dev/null) in *[!0-9a-f]* | '') refuse "state id unreadable or malformed" ;; esac
[ "$(wc -c <"$B/state-id" | tr -d ' ')" -eq 32 ] || refuse "state id malformed"

{
  echo "mode=$MODE"; echo "launch=$K"; echo "pid=$$"; echo "start=$START"; echo "nonce=$NONCE"
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"; echo "utc=$(date -u +%FT%T.%3NZ)"; echo "uid=$(id -u)"
  echo "sid=$SID"; echo "state_id_sha256=$SIDF"; echo "key_form=$KF"; echo "node_extra_ca=$CA"
  echo "claude_sha256=$(h /usr/local/bin/claude)"; echo "pkg_sha256=$(cat "$B/pkg.sha256")"; echo "step_sleep=$STEP_SLEEP"
  echo "claude_code_env_names=${CCV:-none}"
} >"$B/launch/identity.tmp"
cp "$B/launch/identity.tmp" "$B/launch/identity-$K"
mv "$B/launch/identity.tmp" "$B/launch/identity"

if [ "$MODE" = resume ]; then
  # ---- resume: verify, freeze, summarize BEFORE the credential checks, so the state is measured even if the
  # credential path then fails. Nothing here repairs state.
  T=$(ls "$B"/claude/projects/*/"$SID".jsonl 2>/dev/null || true)
  [ -n "$T" ] && [ "$(printf '%s\n' "$T" | grep -c .)" -eq 1 ] && [ -f "$T" ] || refuse "transcript for the recorded session is missing or not unique"
  [ "$(h "$B/settings.json")" = "$(h "$P/settings.json")" ] || refuse "settings.json differs from the package"
  [ "$(h "$B/repo/step.sh")" = "$(h "$P/step.sh")" ] || refuse "step.sh differs from the package"
  # ledger hash chain (each line carries the first 16 hex of sha256(previous line + newline))
  if [ -f "$B/repo/ledger.log" ]; then
    prev='' n=0
    while IFS= read -r l || [ -n "$l" ]; do # an unterminated (torn) last line is checked too
      if [ "$n" -eq 0 ]; then want=$(printf '' | sha256sum | cut -c1-16); else want=$(printf '%s\n' "$prev" | sha256sum | cut -c1-16); fi
      case $l in *" prev=$want") ;; *) refuse "ledger chain broken at line $((n + 1))" ;; esac
      prev=$l n=$((n + 1))
    done <"$B/repo/ledger.log"
  fi
  F=$B/launch/pre-$K
  [ ! -e "$F" ] || refuse "freeze directory exists already"
  mkdir -p "$F"
  for f in attempts progress refusals ledger locks; do if [ -f "$B/repo/$f.log" ]; then cp "$B/repo/$f.log" "$F/$f.log"; fi; done
  if [ -f "$B/repo/.state/next-token.sha256" ]; then cp "$B/repo/.state/next-token.sha256" "$F/next-token.sha256"; fi
  if [ -f "$B/repo/.state/lock/owner" ]; then cp "$B/repo/.state/lock/owner" "$F/lock-owner"; fi
  cp "$T" "$F/transcript.jsonl"
  {
    echo "mode=resume"; echo "launch=$K"; echo "utc=$(date -u +%FT%T.%3NZ)"; echo "sid=$SID"; echo "state_id_sha256=$SIDF"
    echo "transcript=${T#"$B"/claude/projects/}"; echo "transcript_bytes=$(wc -c <"$F/transcript.jsonl" | tr -d ' ')"; echo "transcript_sha256=$(h "$F/transcript.jsonl")"
    for f in attempts progress refusals ledger locks; do echo "$f=$(lines "$F/$f.log") sha256=$(h "$F/$f.log")"; done
    echo "next_token_hash_file_sha256=$(h "$F/next-token.sha256")"
    echo "lock=$([ -d "$B/repo/.state/lock" ] && echo held || echo free) owner=$(tr ' ' ':' <"$F/lock-owner" 2>/dev/null || echo none)"
    echo "ledger_chain=ok"; echo "step_sh_sha256=$(h "$B/repo/step.sh")"; echo "settings_sha256=$(h "$B/settings.json")"
    echo "claude_code_env_names=${CCV:-none}"
  } >"$B/launch/precheck-$K.tmp"
  mv "$B/launch/precheck-$K.tmp" "$B/launch/precheck-$K"
fi
[ "$KF" = placeholder ] || refuse "ANTHROPIC_API_KEY is $KF, not an OpenShell placeholder"
# Approval tail: Claude Code trims and keeps the last 20 characters. Refuse anything that is not a plain
# token, so trimming cannot change the tail and the tail is JSON-safe without escaping.
case $ANTHROPIC_API_KEY in *[!A-Za-z0-9:_.-]*) refuse "placeholder has unexpected characters" ;; esac
AT=$(printf %s "$ANTHROPIC_API_KEY" | tail -c 20)
[ "${#AT}" -eq 20 ] || refuse "placeholder shorter than 20 characters"

if [ "$MODE" = fresh ]; then
  # First-run state (EXP-006 entrypoint-agent.sh:98 pattern): onboarding done, folder trust accepted, key approved.
  printf '{"hasCompletedOnboarding": true, "theme": "dark", "customApiKeyResponses": {"approved": ["%s"], "rejected": []}, "projects": {"%s": {"hasTrustDialogAccepted": true}, "%s": {"hasTrustDialogAccepted": true}}}\n' "$AT" "$B/repo" "$B" >"$B/claude/.claude.json"
  cp "$B/claude/.claude.json" "$B/home/.claude.json"
else
  # resume: add the current approval tail to BOTH copies if it is missing (a new provider revision changes the
  # placeholder's tail; an unmatched approval would block the TUI with the custom-key dialog). A structured
  # JSON edit; nothing else in the files changes. Refuse if either copy is not valid JSON.
  CJ1=$(h "$B/claude/.claude.json") CJ2=$(h "$B/home/.claude.json")
  AP=$(AT="$AT" python3 -I -c '
import json, os, sys
at = os.environ["AT"]; out = []
docs = []
for p in sys.argv[1:]:  # read and validate BOTH copies before writing either
    with open(p) as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise SystemExit(1)
    docs.append((p, d))
for p, d in docs:
    r = d.setdefault("customApiKeyResponses", {"approved": [], "rejected": []})
    a = r.setdefault("approved", [])
    if at in a:
        out.append("same")
        continue
    a.append(at)
    with open(p + ".tmp", "w") as f:
        json.dump(d, f)
    os.replace(p + ".tmp", p)
    out.append("added")
print(",".join(out))' "$B/claude/.claude.json" "$B/home/.claude.json") || refuse "a .claude.json copy is unreadable or not JSON"
  { echo "claude_json_before=$CJ1,$CJ2"; echo "claude_json_after=$(h "$B/claude/.claude.json"),$(h "$B/home/.claude.json")"; echo "approval_tail=$AP"; } >>"$B/launch/precheck-$K"
fi
unset AT 2>/dev/null || true

export EXP008_NONCE="$NONCE" HOME="$B/home" CLAUDE_CONFIG_DIR="$B/claude" TMPDIR="$B/tmp" \
  XDG_CONFIG_HOME="$B/xdg/config" XDG_STATE_HOME="$B/xdg/state" XDG_CACHE_HOME="$B/xdg/cache" XDG_DATA_HOME="$B/xdg/data" \
  SHELL=/bin/bash LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 STEP_SLEEP \
  DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
cd "$B/repo"
if [ "$MODE" = fresh ]; then
  exec /usr/local/bin/claude --bare --settings "$B/settings.json" --strict-mcp-config --tools Bash \
    --model claude-haiku-5-5 --effort medium --session-id "$SID" "$(cat "$P/prompt.txt")"
fi
exec /usr/local/bin/claude --bare --settings "$B/settings.json" --strict-mcp-config --tools Bash \
  --model claude-haiku-5-5 --effort medium --resume "$SID"
