#!/usr/bin/env bash
# Cluster-free resume regression test for C4 (proposal section 2.1, CR1-CR7, made reproducible).
# The REAL C4 bootstrap, state-aware launcher, step.sh and settings, with the REAL sha256-pinned Claude Code
# 2.1.323 binary, inside an unprivileged user+network+PID namespace whose only interface is loopback, against a
# scripted mock model (tests/resume_probe.py): no network, no model, no credential (a made-up placeholder).
# A pod loss is simulated by SIGKILLing every process of the namespace while step 2 sleeps; the canonical command
# is then relaunched. Asserts the launcher's Resume selection and argv, CR2 (no request before input), CR3 (a
# synthesized is_error "interrupted" result for the orphaned call; the history is sent), CR5 (same session file,
# byte prefix kept), and runs metrics4's C4b and C4c on the real files (expected: intact or intact-with-allowance;
# resumed-continued-after-prompt; primary pass). Test pacing: STEP_SLEEP 4 s instead of 45 s (remapped copy only).
# Exit 2 (NOT RUN) without the pinned binary or the namespaces.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CLAUDE_SHA=604d29a6869409106b6a1110bdadcc8b72e8654a5a865d23258f938a696e348e
FAKE=openshell:resolve:env:v7_ANTHROPIC_API_KEY
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
BIN=
for c in "${CLAUDE_BIN:-}" "$(command -v claude 2>/dev/null)" /home/linuxbrew/.linuxbrew/Caskroom/claude-code/2.1.323/claude; do
  [ -n "$c" ] && c=$(readlink -f "$c") && [ -x "$c" ] && [ "$(sha256sum "$c" | cut -d' ' -f1)" = "$CLAUDE_SHA" ] && { BIN=$c; break; }
done
[ -n "$BIN" ] || { echo "NOT RUN: no Claude Code binary with sha256 $CLAUDE_SHA (set CLAUDE_BIN)"; exit 2; }
unshare -rnmpf --mount-proc true 2>/dev/null || { echo "NOT RUN: unprivileged user+network+PID namespaces unavailable"; exit 2; }
T=$(mktemp -d); if [ -n "${KEEP:-}" ]; then echo "T=$T" >&2; else trap 'rm -rf "$T"' EXIT; fi
W=$T/w; mkdir -p "$W/src"

L=$T E=$T RUN=0000-0000 IMG=x PROV=x; mkdir -p "$T/obs"
# shellcheck source=../launcher4.sh
. "$HERE/launcher4.sh"
pkg_build "$T/p0.tar"; tar -xf "$T/p0.tar" -C "$W/src"
sed -i -e "s#/sandbox/c#$W/sb/c#g" -e "s#/usr/local/bin/claude#$BIN#g" -e 's#^STEP_SLEEP=45$#STEP_SLEEP=4#' "$W/src/launch.sh"
grep -q '^STEP_SLEEP=4$' "$W/src/launch.sh" || no "could not remap the test pacing"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$W/src" -cf "$W/p.tar" launch.sh prompt.txt settings.json step.sh
pkg_gz "$W/p.tar" "$W/p.tar.gz"; base64 -w0 "$W/p.tar.gz" >"$W/p.b64"; sha256sum "$W/p.tar" | cut -d' ' -f1 >"$W/p.sha" # the C4 transport: gzip, base64; sha256 of the original tar
sed -e "s#/sandbox/c#$W/sb/c#g" <<<"$BOOT" >"$W/boot.sh"
unshare -rnmpf --mount-proc sh -c 'ip link set lo up && exec /usr/bin/python3 -I "$0" "$@"' "$HERE/tests/resume_probe.py" \
  "$W" "$W/boot.sh" "$W/p.b64" "$(cat "$W/p.sha")" "$FAKE" "$BIN" >"$T/run.log" 2>&1
[ -s "$W/report.json" ] && ok "probe ran (pinned binary, loopback-only user+net+PID namespace)" || { no "no report: $(tail -c 400 "$T/run.log")"; echo "failures=$fails"; exit 1; }
q() { jq -r "$1" "$W/report.json"; }
[ "$(q .A_step1_started)" = true ] && [ "$(q .A_step2_started)" = true ] && ok "phase A: the agent ran step 1 and started step 2 through the real launcher" || no "phase A steps: $(q '[.A_step1_started,.A_step2_started]')"
[ "$(q .A_control_answered)" = true ] && ok "phase A: the control line was answered" || no "phase A control"
[ "$(q .A_step2_open_at_kill)" = true ] && [ "$(q .A_alive_after_kill)" = 0 ] && ok "pod loss simulated with step 2 in flight (no process survived)" || no "kill: $(q '[.A_step2_open_at_kill,.A_alive_after_kill]')"
grep -q '^mode=resume$' "$W/sb/c/launch/identity-2" && [ -s "$W/sb/c/launch/precheck-2" ] && ok "relaunch: the launcher selected Resume and wrote precheck-2" || no "relaunch mode"
[ "$(q .B_argv_resume)" = true ] && [ "$(q .B_argv_session_id)" = false ] && [ "$(q .B_argv_last_is_sid)" = true ] && ok "resumed argv: --resume <sid>, no --session-id, no positional prompt" || no "argv: $(q '[.B_argv_resume,.B_argv_session_id,.B_argv_last_is_sid]')"
[ "$(q .B_main_requests_before_input)" = 0 ] && ok "CR2: no model request in 12 s without input" || no "CR2: $(q .B_main_requests_before_input) requests before input"
[ "$(q '.B_probe_request.error_tool_results | map(select(.interrupted_text)) | length')" -ge 1 ] && ok "CR3: the first request after input carries a synthesized is_error 'interrupted' tool_result" || no "CR3: $(q .B_probe_request.error_tool_results)"
[ "$(q '.B_probe_request.n_messages')" -gt 4 ] && ok "CR3: the history is sent ($(q .B_probe_request.n_messages) messages)" || no "history not sent"
[ "$(q '.B_probe_request.response | join(",")')" = text ] && ok "the probe reply is text only" || no "probe response blocks"
[ "$(q .B_done_4)" = true ] && ok "after 'Continue the task.': steps 2, 3 and 4 done" || no "continuation: steps not done"
[ "$(q '.B_transcripts | length')" = 1 ] && [ "$(q '.B_transcripts[0]')" = "$(q .sid_file)" ] && ok "CR5: one transcript, the same session file" || no "CR5: $(q .B_transcripts)"
TR=$(find "$W/sb/c/claude/projects" -name '*.jsonl' | head -n 1)
python3 -I -c 'import sys; a=open(sys.argv[1],"rb").read(); b=open(sys.argv[2],"rb").read(); sys.exit(0 if b.startswith(a) else 1)' "$W/R.jsonl" "$TR" && ok "CR5: the pre-fault bytes are an exact prefix" || no "prefix"
grep -q '^attempt n=2 .*prior_attempts=1 ' "$W/sb/c/repo/attempts.log" && ok "the in-flight step 2 was re-attempted (prior_attempts=1), not repeated after done" || no "step 2 re-attempt"
[ ! -s "$W/sb/c/repo/refusals.log" ] && ok "no refusal: no duplicate, skip or wrong token" || no "refusals: $(wc -l <"$W/sb/c/repo/refusals.log")"

# metrics4 on the real files: C4b (frozen pre-resume copy vs R) and C4c (whole run)
c4b_of() { # c4b_of <work dir> <out>: metrics4 c4b on the frozen pre-resume copy against R
  local w=$1 V='{"pvc_uid": "p", "pv": "v", "volume_handle": "h"}'
  jq -n --arg rd "$w/R" --arg pd "$w/sb/c/launch/pre-2" --arg rt "$w/R.jsonl" --arg pt "$w/sb/c/launch/pre-2/transcript.jsonl" --argjson v "$V" \
    --arg sid "$(sha256sum "$w/R-state-id" | cut -d' ' -f1)" --arg tok "$(sha256sum "$w/R-token" | cut -d' ' -f1)" \
    --arg psid "$(sed -n 's/^state_id_sha256=//p' "$w/sb/c/launch/precheck-2")" --arg ptok "$(sed -n 's/^next_token_hash_file_sha256=//p' "$w/sb/c/launch/precheck-2")" \
    '{R_dir: $rd, pre_dir: $pd, R_transcript: $rt, pre_transcript: $pt, V_before: $v, V_after: $v, R_state_id_sha256: $sid, R_token_file_sha256: $tok,
      precheck_present: true, precheck: {state_id_sha256: $psid, next_token_hash_file_sha256: $ptok}}' >"$2.in"
  python3 -I "$HERE/metrics4.py" c4b "$2.in" >"$2"
}
c4b_of "$W" "$T/c4b-out.json"
v=$(jq -r .value "$T/c4b-out.json")
[[ $v == intact || $v == intact-with-allowance ]] && [ "$(jq -r .in_flight_step "$T/c4b-out.json")" = 2 ] && [ "$(jq -r .chain_broken_by_fault "$T/c4b-out.json")" = false ] \
  && ok "C4b on real files: $v, in-flight step 2, chain not broken" || no "C4b: $(jq -c '{value,in_flight_state,reasons,transcript}' "$T/c4b-out.json")"
mkdir -p "$T/final"; cp "$W/sb/c/repo/"*.log "$T/final/"
jq -n --slurpfile c4b "$T/c4b-out.json" --arg rd "$W/R" --arg fd "$T/final" --arg rt "$W/R.jsonl" --arg pt "$W/sb/c/launch/pre-2/transcript.jsonl" --arg ft "$TR" \
  --arg rn "$(q .sid_file)" --argjson names "$(q .B_transcripts | jq -c .)" \
  '{c4b: $c4b[0], R_dir: $rd, final_dir: $fd, R_transcript: $rt, pre_transcript: $pt, final_transcript: $ft, transcripts_after: $names, R_transcript_name: $rn,
    process: "new-process", launcher_refused: false, probe_token: "PROBE-22222222", codeword: "heronab12cd", expected_last: [1], control_pass: true,
    M_s: 5.0, start_t: 0, dialogs: {}, spend_stop: false, probe_typed: true, continue_typed: true}' >"$T/c4c.json"
python3 -I "$HERE/metrics4.py" c4c "$T/c4c.json" >"$T/c4c-out.json"
r=$(jq -r '.axes | "\(.resume) \(.interrupted_turn) \(.session) \(.repeat_skip)"' "$T/c4c-out.json")
[ "$r" = "resumed-continued-after-prompt synthesized-interrupted same-id-same-file in-flight-reattempt-only" ] && [ "$(jq -r .primary_pass "$T/c4c-out.json")" = true ] \
  && ok "C4c on the real transcript: $r, primary pass" || no "C4c: $r / $(jq -c '{decision_path, attributes: (.attributes | {probe, step_n_token_matches_prefault, done_after_resume, nonconforming_bash_commands, api_error_entries_after_resume})}' "$T/c4c-out.json")"
[ "$(jq -r .attributes.step_n_token_matches_prefault "$T/c4c-out.json")" = true ] && ok "the accepted step 2 used the token that existed only in the pre-fault conversation" || no "token check"
python3 -I "$HERE/metrics4.py" activity "$TR" "$(wc -c <"$W/R.jsonl")" | jq -e '.synthetic_entries >= 1' >/dev/null && ok "Claude Code's synthetic resume entries are present and excluded by the real-model predicate" || no "synthetic entries"
# ---- variant: SIGTERM then SIGKILL after 1 s (what a --grace-period=1 delete does): measure the transcript tail
W2=$T/w2; mkdir -p "$W2"; cp "$W/p.b64" "$W/p.sha" "$W2/"; sed -e "s#$W/sb/c#$W2/sb/c#g" "$W/boot.sh" >"$W2/boot.sh"
mkdir -p "$W2/src" && cp "$W/src/"* "$W2/src/" && sed -i "s#$W/sb/c#$W2/sb/c#g" "$W2/src/launch.sh"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$W2/src" -cf "$W2/p.tar" launch.sh prompt.txt settings.json step.sh
pkg_gz "$W2/p.tar" "$W2/p.tar.gz"; base64 -w0 "$W2/p.tar.gz" >"$W2/p.b64"; sha256sum "$W2/p.tar" | cut -d' ' -f1 >"$W2/p.sha"
PROBE_KILL=term1 unshare -rnmpf --mount-proc sh -c 'ip link set lo up && exec /usr/bin/python3 -I "$0" "$@"' "$HERE/tests/resume_probe.py" \
  "$W2" "$W2/boot.sh" "$W2/p.b64" "$(cat "$W2/p.sha")" "$FAKE" "$BIN" >"$T/run2.log" 2>&1
if [ -s "$W2/report.json" ] && [ -s "$W2/sb/c/launch/pre-2/transcript.jsonl" ]; then
  tail_report=$(python3 -I -c '
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("m4", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
r, p = m.load_bytes(sys.argv[2]), m.load_bytes(sys.argv[3])
e = m.after(p, len(r)) if p.startswith(r) else []
print(json.dumps({"prefix_ok": p.startswith(r), "tail_bytes": len(p) - len(r), "tail_entries": len(e), "types": [x.get("type") for x in e]}))' "$HERE/metrics4.py" "$W2/R.jsonl" "$W2/sb/c/launch/pre-2/transcript.jsonl")
  echo "     SIGTERM+1s variant, transcript tail after R (recorded, not asserted; see README 9): $tail_report"
  jq -e '.prefix_ok' <<<"$tail_report" >/dev/null && ok "SIGTERM+1s variant: pre-fault bytes still an exact prefix of the frozen copy" || no "SIGTERM variant prefix"
  ! grep -q '^done n=2 ' "$W2/sb/c/launch/pre-2/progress.log" && ok "SIGTERM+1s variant: the in-flight step 2 did not complete during the grace (no done in the frozen copy)" || no "SIGTERM variant: step 2 completed during the grace"
  [ "$(jq -r .B_done_4 "$W2/report.json")" = true ] && [ "$(jq -r .B_main_requests_before_input "$W2/report.json")" = 0 ] && ok "SIGTERM+1s variant: no request before input, and the task continued after the prompt" || no "SIGTERM variant resume: $(jq -c . "$W2/report.json" | cut -c1-300)"
  c4b_of "$W2" "$T/c4b2-out.json"
  v2=$(jq -r '"\(.value) \(.in_flight_state) \(.chain_broken_by_fault)"' "$T/c4b2-out.json")
  [[ $v2 == "intact-with-allowance 0 false" || $v2 == "intact 0 false" ]] && ok "SIGTERM+1s variant: C4b $v2 (tail within the approved bound)" || no "SIGTERM variant C4b: $(jq -c '{value,reasons,transcript}' "$T/c4b2-out.json")"
  [ ! -s "$W2/sb/c/repo/refusals.log" ] && ok "SIGTERM+1s variant: no refusal (chain not broken by the fault)" || no "SIGTERM variant refusals: $(cut -c1-80 "$W2/sb/c/repo/refusals.log")"
else
  no "SIGTERM+1s variant produced no report: $(tail -c 300 "$T/run2.log")"
fi
echo "failures=$fails"; [ "$fails" = 0 ]
