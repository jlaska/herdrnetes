#!/usr/bin/env bash
# Offline test of the Stage C4 package, bootstrap and state-aware launcher (no cluster, no network, no model,
# no credential). /sandbox/c is remapped to a temp dir and /usr/local/bin/claude to a stub that records its argv
# and the FORM of key-related variables. Placeholders are made-up strings of the documented shape.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "ok   - $1"; }; no() { echo "FAIL - $1"; fails=$((fails + 1)); }
PH1=openshell:resolve:env:v1_ANTHROPIC_API_KEY
PH2=openshell:resolve:env:v2_ANTHROPIC_API_KEY

cat >"$T/fakeclaude" <<'EOF'
#!/bin/sh
f() { case $1 in '') echo absent ;; openshell:resolve:*) echo placeholder ;; *) echo other ;; esac; }
{ echo "pid=$$"; echo "ak=$(f "${ANTHROPIC_API_KEY:-}")"; echo "at=$(f "${ANTHROPIC_AUTH_TOKEN:-}")"; echo "ot=$(f "${CLAUDE_CODE_OAUTH_TOKEN:-}")"
  echo "rit=${CLAUDE_CODE_RESUME_INTERRUPTED_TURN:-unset}"; echo "rp=${CLAUDE_CODE_RESUME_PROMPT:-unset}"; echo "rma=${CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS:-unset}"
  echo "sleep=${STEP_SLEEP:-unset}"; echo "ccd=$CLAUDE_CONFIG_DIR"; echo "home=$HOME"; echo "pwd=$(pwd)"; for a in "$@"; do echo "arg=$a"; done; } >"$OUTF"
EOF
chmod 0755 "$T/fakeclaude"

L=$T; E=$T; RUN=0000-0000; IMG=x; PROV=exp008c-test
# shellcheck source=../launcher4.sh
. "$HERE/launcher4.sh"
mkdir -p "$T/obs"
pkg_build "$T/a.tar"; pkg_build "$T/b.tar"
cmp -s "$T/a.tar" "$T/b.tar" && ok "C4 package build is deterministic" || no "C4 package build is not deterministic"
[ "$(tar -tf "$T/a.tar" | tr '\n' ' ')" = "launch.sh prompt.txt settings.json step.sh " ] && ok "package holds launch.sh prompt.txt settings.json step.sh" || no "package contents: $(tar -tf "$T/a.tar" | tr '\n' ' ')"
mkdir -p "$T/x" && tar -xf "$T/a.tar" -C "$T/x"
cmp -s "$T/x/prompt.txt" "$HERE/../stage-c/task/prompt.txt" && cmp -s "$T/x/settings.json" "$HERE/../stage-c/task/settings.json" \
  && ok "prompt and settings are the C0-C3 files, byte-identical" || no "prompt/settings differ from C0-C3"
cmp -s "$T/x/launch.sh" "$HERE/task/launch.sh" && cmp -s "$T/x/step.sh" "$HERE/task/step.sh" && ok "launcher and step.sh are the C4 files" || no "launcher/step.sh not the C4 files"
B0=$(sed -n "s/^BOOT='\(.*\)'$/\1/p" "$HERE/../stage-c/launcher.sh")
# the C4 bootstrap is the C0-C3 bootstrap with exactly one change: base64 -> gzip -dc -> the original tar (then sha256 as before)
B0X=${B0/'printf %s "$0" | base64 -d >/sandbox/c/pkg.tar;'/'printf %s "$0" | base64 -d >/sandbox/c/pkg.tar.gz; gzip -dc /sandbox/c/pkg.tar.gz >/sandbox/c/pkg.tar;'}
[ -n "$B0" ] && [ "$B0X" != "$B0" ] && [ "$BOOT" = "$B0X" ] && ok "bootstrap = C0-C3 bootstrap + only the gzip decode step (sha256 of the original tar, extract, exec unchanged)" || no "bootstrap delta from C0-C3"
create_args
[ "${#LAUNCH[@]}" = 5 ] && [ "${LAUNCH[0]}" = /bin/sh ] && [ "${LAUNCH[1]}" = -c ] && [ "${LAUNCH[2]}" = "$BOOT" ] && [ "${LAUNCH[4]}" = "$(sha256sum "$T/pkg.tar" | cut -d' ' -f1)" ] \
  && ok "LAUNCH = /bin/sh -c BOOT <payload> <sha256 of the original tar>" || no "LAUNCH shape"
[ "$(printf %s "${LAUNCH[3]}" | base64 -d | gzip -dc | sha256sum | cut -d' ' -f1)" = "${LAUNCH[4]}" ] && ok "the payload decodes and decompresses to the original tar" || no "payload does not decode to the tar"
cmp -s "$T/pkg.tar" "$T/a.tar" && ok "create_args packs the same deterministic tar as pkg_build" || no "create_args tar differs"
pkg_gz "$T/a.tar" "$T/a.gz"; pkg_gz "$T/b.tar" "$T/b.gz"; cmp -s "$T/a.gz" "$T/b.gz" && cmp -s "$T/a.gz" "$T/pkg.tar.gz" && ok "gzip -n output is deterministic" || no "gzip output not deterministic"
[ "$(od -An -tu1 -j4 -N4 "$T/a.gz" | tr -s ' ')" = " 0 0 0 0" ] && [ $(( $(od -An -tu1 -j3 -N1 "$T/a.gz") & 8 )) = 0 ] && ok "gzip header: no mtime, no file name" || no "gzip header carries mtime or name"
launch_check "$T/lc.txt" && grep -q '^launch_check=pass argc=5 ' "$T/lc.txt" && grep -q ' deterministic=yes ' "$T/lc.txt" && grep -q ' decodes_to_pkg_sha256=yes ' "$T/lc.txt" \
  && ok "launch_check passes: $(grep -o 'payload_bytes=[0-9]*' "$T/lc.txt") (budget 24576), $(grep -o 'max_elem_bytes=[0-9]*' "$T/lc.txt") (limit 32768)" || no "launch_check: $(cat "$T/lc.txt")"
grep -q -E '^pkg_sha256=[0-9a-f]{64} pkg_bytes=[0-9]+ gz_sha256=[0-9a-f]{64} gz_bytes=[0-9]+ payload_bytes=[0-9]+$' "$T/obs/c0-pkg.txt" && ok "c0-pkg.txt records sizes and hashes only" || no "c0-pkg.txt: $(cat "$T/obs/c0-pkg.txt")"
printf '%s\n' "${CREATE[@]}" | grep -q -x -E -- '--no-keep|--keep|--driver-config.*|--upload.*|--workspace.*' && no "CREATE has a forbidden option" || ok "CREATE has no --no-keep/--keep/--driver-config/--upload/--workspace"
[ "${CREATE[*]}" = "--from x --provider exp008c-test --detach --tty --restart-policy never --no-auto-providers --label exp008.run=0000-0000 --label exp008.stage=c4" ] \
  && ok "CREATE is the reviewed argv (restart-policy never, detach, no auto providers)" || no "CREATE: ${CREATE[*]}"

# remapped package for the offline runs
mkdir -p "$T/src" && tar -xf "$T/a.tar" -C "$T/src"
sed -i -e "s#/sandbox/c#$T/sb/c#g" -e "s#/usr/local/bin/claude#$T/fakeclaude#g" "$T/src/launch.sh"
mk() { tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$1" -cf "$2" launch.sh prompt.txt settings.json step.sh; }
mk "$T/src" "$T/t.tar"; TSHA=$(sha256sum "$T/t.tar" | cut -d' ' -f1); pkg_gz "$T/t.tar" "$T/t.tar.gz"
BOOT_T=$(sed -e "s#/sandbox/c#$T/sb/c#g" <<<"$BOOT")
run() { # run <out> <placeholder|-> [extra env...]: one launch of the canonical command (bootstrap + launcher)
  local out=$1 ph=$2; shift 2
  local envs=(PATH=/usr/bin:/bin OUTF="$out" CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1 CLAUDE_CODE_RESUME_PROMPT=x CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS=1 CLAUDE_CODE_FOO=1 ANTHROPIC_AUTH_TOKEN=injected)
  [ "$ph" = - ] || envs+=(ANTHROPIC_API_KEY="$ph")
  env -i "${envs[@]}" "$@" /bin/sh -c "$BOOT_T" "$(base64 -w0 "$T/t.tar.gz")" "$TSHA" 2>"$out.err"
}
has() { grep -q -x -- "$2" "$1"; }
S=$T/sb/c
fake_transcript() { mkdir -p "$S/claude/projects/slug"; printf '{"type":"user","uuid":"u1"}\n{"type":"assistant","uuid":"u2"}\n' >"$S/claude/projects/slug/$(cat "$S/launch/sid").jsonl"; }
fake_steps() { # three completed steps through the real token chain (the real step.sh, no sleep)
  ( cd "$S/repo" && n=1 tok=start && while [ "$n" -le 3 ]; do o=$(STEP_SLEEP=0 ./step.sh "$n" "$tok") || exit 1; tok=$(sed -n 's/.*NEXT: .\/step.sh [0-9]* //p' <<<"$o"); n=$((n + 1)); done ) \
    || echo "fake_steps failed" >&2
  [ "$(wc -l <"$S/repo/ledger.log")" = 3 ] || no "fixture: expected a 3-line ledger"
}

# ---- 1. fresh launch
run "$T/o1" "$PH1" && ok "fresh launch ran" || no "fresh launch failed: $(cat "$T/o1.err")"
has "$S/launch/identity-1" mode=fresh && ok "identity-1 records mode=fresh" || no "identity-1 mode"
[ "$(wc -c <"$S/state-id")" = 32 ] && grep -q -E '^[0-9a-f]{32}$' "$S/state-id" && ok "state id: 128 random bits as hex" || no "state id"
grep -q -E '^[0-9a-f]{8}-[0-9a-f]{4}-' "$S/launch/sid" && ok "session id recorded on the volume" || no "sid file"
has "$T/o1" "arg=--session-id" && has "$T/o1" "arg=$(cat "$S/launch/sid")" && ok "fresh: --session-id <sid>" || no "fresh: --session-id"
grep -q '^arg=--resume$' "$T/o1" && no "fresh used --resume" || ok "fresh: no --resume"
[ "$(grep -c '^arg=' "$T/o1")" = 13 ] && ok "fresh: 13 args (flags + --session-id + prompt)" || no "fresh argc $(grep -c '^arg=' "$T/o1")"
for a in --bare --strict-mcp-config --tools Bash --model claude-haiku-5-5 --effort medium; do has "$T/o1" "arg=$a" || no "fresh missing $a"; done
has "$T/o1" "sleep=45" && ok "STEP_SLEEP=45 exported to the agent" || no "STEP_SLEEP"
has "$T/o1" "rit=unset" && has "$T/o1" "rp=unset" && has "$T/o1" "rma=unset" && ok "auto-continue variables unset" || no "auto-continue variable reached claude"
has "$T/o1" "at=absent" && ok "Bearer-capable variable unset" || no "ANTHROPIC_AUTH_TOKEN reached claude"
grep -q '^claude_code_env_names=CLAUDE_CODE_FOO,CLAUDE_CODE_RESUME_INTERRUPTED_TURN,CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS,CLAUDE_CODE_RESUME_PROMPT$' "$S/launch/identity-1" \
  && ok "CLAUDE_CODE_* names (never values) recorded" || no "env names: $(grep claude_code_env "$S/launch/identity-1")"
grep -q -F "=1" <(grep claude_code_env_names "$S/launch/identity-1") && no "an env value was recorded" || ok "no env value recorded"
has "$T/o1" "pwd=$S/repo" && has "$T/o1" "ccd=$S/claude" && has "$T/o1" "home=$S/home" && ok "cwd, CLAUDE_CONFIG_DIR, HOME" || no "paths"
[ ! -e "$S/launch/precheck-1" ] && ok "fresh: no precheck" || no "fresh wrote a precheck"

# ---- 2. resume with retained state (same placeholder revision)
fake_transcript; fake_steps
run "$T/o2" "$PH1" && ok "resume launch ran" || no "resume failed: $(cat "$T/o2.err")"
has "$S/launch/identity-2" mode=resume && has "$S/launch/identity-2" launch=2 && ok "identity-2 records mode=resume launch=2" || no "identity-2"
has "$T/o2" "arg=--resume" && has "$T/o2" "arg=$(cat "$S/launch/sid")" && ok "resume: --resume <sid>" || no "resume arg"
grep -q '^arg=--session-id$' "$T/o2" && no "resume passed --session-id (exits with an error in 2.1.323: CR6)" || ok "resume: no --session-id"
[ "$(grep -c '^arg=' "$T/o2")" = 12 ] && [ "$(tail -n 1 "$T/o2")" = "arg=$(cat "$S/launch/sid")" ] && ok "resume: 12 args, last is the session id (no positional prompt)" || no "resume argv: $(grep -c '^arg=' "$T/o2")"
for a in --bare --strict-mcp-config --tools Bash --model claude-haiku-5-5 --effort medium "--settings"; do has "$T/o2" "arg=$a" || no "resume missing $a"; done
has "$T/o2" "pwd=$S/repo" && has "$T/o2" "ccd=$S/claude" && ok "resume keeps cwd and config dir (same transcript slug)" || no "resume paths"
has "$T/o2" "rit=unset" && has "$T/o2" "rp=unset" && has "$T/o2" "rma=unset" && ok "resume: auto-continue variables unset (plain --resume)" || no "resume: auto-continue variable reached claude"
P2=$S/launch/precheck-2
[ -s "$P2" ] && has "$P2" mode=resume && ok "precheck-2 written" || no "precheck-2"
has "$P2" "state_id_sha256=$(sha256sum "$S/state-id" | cut -d' ' -f1)" && ok "precheck: state id as sha256 only" || no "precheck state id"
grep -q -F "$(cat "$S/state-id")" "$P2" && no "raw state id in precheck" || ok "raw state id not in precheck"
cmp -s "$S/launch/pre-2/transcript.jsonl" "$S/claude/projects/slug/$(cat "$S/launch/sid").jsonl" && ok "frozen transcript copy taken before exec" || no "frozen transcript"
cmp -s "$S/launch/pre-2/progress.log" "$S/repo/progress.log" && cmp -s "$S/launch/pre-2/ledger.log" "$S/repo/ledger.log" && cmp -s "$S/launch/pre-2/next-token.sha256" "$S/repo/.state/next-token.sha256" \
  && ok "frozen task logs and token-hash file" || no "frozen task logs"
has "$P2" "ledger_chain=ok" && has "$P2" "approval_tail=same,same" && ok "chain ok; approval tail unchanged (same revision)" || no "precheck chain/approval: $(grep -E 'ledger_chain|approval' "$P2")"
has "$T/o2" "sleep=45" && ok "resume: STEP_SLEEP=45" || no "resume sleep"

# ---- 3. resume with a new placeholder revision: the tail is ADDED to both copies, nothing else changes
cp "$S/claude/.claude.json" "$T/cj-before"
run "$T/o3" "$PH2" && ok "resume with a new placeholder revision ran" || no "resume rev2 failed: $(cat "$T/o3.err")"
has "$S/launch/precheck-3" "approval_tail=added,added" && ok "approval tail added to both .claude.json copies" || no "approval tail: $(grep approval "$S/launch/precheck-3")"
python3 -I - "$T/cj-before" "$S/claude/.claude.json" "$S/home/.claude.json" "${PH1: -20}" "${PH2: -20}" <<'PY' && ok "only customApiKeyResponses.approved gained the new tail" || no "claude.json changed beyond the approval list"
import json, sys
a, b, c = (json.load(open(p)) for p in sys.argv[1:4])
old, new = sys.argv[4], sys.argv[5]
for d in (b, c):
    assert d["customApiKeyResponses"]["approved"] == [old, new], d["customApiKeyResponses"]
    d2 = dict(d); d2["customApiKeyResponses"] = a["customApiKeyResponses"]; assert d2 == a
PY
grep -q -F "$PH2" "$S/launch/precheck-3" "$S/launch/identity-3" && no "a placeholder value was recorded" || ok "no placeholder value recorded"

# ---- 4. state checks: refuse, never fall back to a fresh session
refuse_case() { # refuse_case <name> <setup command>: the launcher must exit nonzero, not exec claude, and record the refusal
  rm -rf "$S"; run "$T/r0" "$PH1" >/dev/null 2>&1; fake_transcript; fake_steps
  eval "$2"
  rm -f "$T/rout"
  if run "$T/rout" "$PH1" >/dev/null 2>&1; then no "$1: launcher did not refuse"; elif [ -e "$T/rout" ]; then no "$1: claude was exec'd"; else ok "$1: refused, claude not started"; fi
  grep -q '^refused=' "$S/launch/refusals" 2>/dev/null || no "$1: refusal not recorded"
}
refuse_case "partial state: repo without state-id" 'rm -f "$S/state-id"'
refuse_case "partial state: state-id without repo" 'rm -rf "$S/repo"'
refuse_case "session id missing" 'rm -f "$S/launch/sid"'
refuse_case "session id malformed" 'echo nope >"$S/launch/sid"'
refuse_case "state id malformed" 'echo XYZ >"$S/state-id"'
refuse_case "transcript missing" 'rm -rf "$S/claude/projects"'
refuse_case "transcript not unique" 'mkdir -p "$S/claude/projects/other" && cp "$S/claude/projects/slug/$(cat "$S/launch/sid").jsonl" "$S/claude/projects/other/"'
refuse_case "ledger chain broken" 'sed -i "s/tokhash=/tokhash=0/" "$S/repo/ledger.log"'
refuse_case "settings differ from the package" 'echo "{}" >"$S/settings.json"'
refuse_case "step.sh differs from the package" 'echo "# x" >>"$S/repo/step.sh"'
refuse_case "a .claude.json copy is not JSON" 'echo "{" >"$S/home/.claude.json"'

# ---- 5. state measured even when the credential check then fails (precheck before credential checks)
rm -rf "$S"; run "$T/r0" "$PH1" >/dev/null 2>&1; fake_transcript; fake_steps; rm -f "$T/o5"
run "$T/o5" - >/dev/null 2>&1 && no "resume without a placeholder started" || ok "resume without a placeholder refused"
[ ! -e "$T/o5" ] && [ -s "$S/launch/precheck-2" ] && ok "precheck written before the credential refusal (C4b still measurable)" || no "no precheck before the credential refusal"
grep -q 'not an OpenShell placeholder' "$S/launch/refusals" && ok "credential refusal recorded" || no "credential refusal not recorded"

# ---- 6. a fresh first launch with a missing placeholder never leaves a half state that resume could pick up
rm -rf "$S"; rm -f "$T/o6"; run "$T/o6" - >/dev/null 2>&1 || true
[ ! -e "$T/o6" ] && ok "fresh without placeholder: claude not started" || no "fresh without placeholder started claude"

echo "failures=$fails"; [ "$fails" = 0 ]
