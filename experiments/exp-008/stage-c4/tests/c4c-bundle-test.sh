#!/usr/bin/env bash
# Offline regression for FIND-101 (run 1127-2105). Runs the REAL c4c bundle block of stagec4.sh (from the
# transcript listing through the metrics4 c4c call), extracted unchanged, against a fixture in the harness's own
# E/L layout. It checks the harness-to-classifier input (R_transcript_name), not the classifier alone.
# In the run, tr_rel was "-sandbox-c-repo/<sid>.jsonl" (Claude Code's encoding of /sandbox/c/repo), so
# `basename "$(cat tr_rel)"` parsed it as the -s option, printed "missing operand" and gave "", and the
# classifier recorded session=new-id / inconclusive.
#   1. the original block (`basename` without `--`, reconstructed from this file's block) derives "" and no pass;
#   2. the corrected block derives exactly <sid>.jsonl;
#   3. the original session, all other evidence valid: session=same-id-same-file, primary pass;
#   4. a missing, malformed or mismatched reference name: no primary pass;
#   5. a different (or a second) session file after resume: no primary pass.
# Limits: the block starts after `kx X2`, so the X2 listing is a synthetic `tr=NAME lines= bytes=` line; X2, kx and
# the line-724 tr_rel writer are not exercised (the tr_rel shape is the run's, evidence obs/c4c-final-S.txt).
# The fixture overrides TB's single default (sid); fixture-check guards the expected pass shape.
# No cluster, no network, no credential.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); H=$D/stagec4.sh
T=$(mktemp -d); if [ -n "${KEEP:-}" ]; then echo "T=$T" >&2; else trap 'rm -rf "$T"' EXIT; fi
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
SID=d48f3ecf-3ad4-4f56-b82e-2794223d52ad OTHER=0f0f0f0f-1111-4222-8333-444444444444

# the block, byte-for-byte from the harness: the transcript-listing line through the classifier call
awk '/^  names=\$\(sed -n .s\/\^tr=/ {p=1} p {print} p && /"\$\{M4\[@\]\}" c4c "\$L\/c4c-bundle.json"/ {exit}' "$H" >"$T/block.sh"
[ "$(grep -c 'basename -- "$(cat "$E/tr_rel")"' "$T/block.sh")" = 1 ] && [ "$(grep -c 'c4c "$L/c4c-bundle.json"' "$T/block.sh")" = 1 ] \
  && ok "c4c bundle block extracted from stagec4.sh ($(wc -l <"$T/block.sh") lines; basename is option-terminated)" || no "block extraction: $(cat "$T/block.sh")"
# every other basename is the in-sandbox X2 listing, whose operands come from an absolute glob (never dash-leading)
[ "$(grep -v '^X2=' "$H" | grep -c 'basename')" = 1 ] && grep '^X2=' "$H" | grep -q 't=$(ls /sandbox/c/claude/projects/\*/\*.jsonl' \
  && ok "stagec4.sh: one workstation-side basename (under test); X2's in-sandbox basename takes absolute /sandbox/... paths" || no "unexpected basename calls in stagec4.sh"
sed 's/basename -- "\$(cat/basename "$(cat/' "$T/block.sh" >"$T/block-orig.sh"
! grep -q 'basename --' "$T/block-orig.sh" && ok "original (run 1127-2105) form of the block reconstructed" || no "orig reconstruction"

run_block() { # run_block <case> <block> <tr_rel or "-"> <listing names...>: E/L fixture; prints the case dir
  local c=$T/$1 blk=$2 rel=$3; shift 3; local E=$c/e L=$c/l n
  mkdir -p "$c"; python3 -I "$D/tests/c4c_fixture.py" "$E" "$L" "$SID" >"$c/vars.json" || { echo "fixture failed" >"$c/err"; echo "$c"; return; }
  [ "$rel" = - ] || printf '%s' "$rel" >"$E/tr_rel"
  : >"$E/obs/c4c-final-T.txt"; echo "attempts=1 last=x" >>"$E/obs/c4c-final-T.txt"
  for n in "$@"; do echo "tr=$n lines=1 bytes=1" >>"$E/obs/c4c-final-T.txt"; done
  ( HERE=$D M4=(python3 -I "$D/metrics4.py") proc=new-process probe_typed=true cont_typed=true
    m=$(jq -r .M_s "$c/vars.json") start_t=$(jq -r .start_t "$c/vars.json") dialogs=$(jq -c .dialogs "$c/vars.json")
    stop() { echo "STOP: $*" >"$c/stopped"; exit 3; }
    # shellcheck source=/dev/null
    . "$blk" ) 2>"$c/stderr"
  echo "$c"
}
rn() { jq -r .R_transcript_name "$1/l/c4c-bundle.json"; }
pp() { jq -r .primary_pass "$1/e/metrics/c4c.json"; }
ses() { jq -r .axes.session "$1/e/metrics/c4c.json"; }
REL="-sandbox-c-repo/$SID.jsonl"

c=$(run_block fixture-check "$T/block.sh" "$REL" "$SID.jsonl")
[ "$(jq -r .c4b_value "$c/vars.json")" = intact ] && ok "fixture: C4b intact, post-resume run in the expected primary-pass shape" || no "fixture: $(cat "$c/vars.json" "$c/err" 2>/dev/null)"

# 1. the original implementation
c=$(run_block orig "$T/block-orig.sh" "$REL" "$SID.jsonl")
[ "$(rn "$c")" = "" ] && grep -q 'missing operand' "$c/stderr" && ok "1 original block on the real path shape: R_transcript_name=\"\" and 'basename: missing operand' (FIND-101 reproduced)" || no "1 original: rn='$(rn "$c")'"
[ "$(ses "$c")" = new-id ] && [ "$(pp "$c")" = false ] && [ "$(jq -r .decision_path "$c/e/metrics/c4c.json")" = session-new-id-not-followed ] \
  && ok "1 original block: session=new-id, decision=session-new-id-not-followed, primary_pass=false (the run's recorded result)" || no "1 original classify: $(ses "$c") $(pp "$c")"
# 2 + 3. the corrected implementation
c=$(run_block fixed "$T/block.sh" "$REL" "$SID.jsonl")
[ "$(rn "$c")" = "$SID.jsonl" ] && [ ! -s "$c/stderr" ] && ok "2 corrected block: R_transcript_name=$SID.jsonl exactly, no stderr" || no "2 corrected: rn='$(rn "$c")' $(cat "$c/stderr")"
[ "$(ses "$c")" = same-id-same-file ] && [ "$(jq -r .attributes.session_ids_consistent "$c/e/metrics/c4c.json")" = true ] && [ "$(pp "$c")" = true ] \
  && [ "$(jq -r .axes.resume "$c/e/metrics/c4c.json")" = resumed-continued-after-prompt ] \
  && ok "3 corrected block, original session, valid evidence: same-id-same-file, ids consistent, resumed-continued-after-prompt, primary pass" || no "3 corrected classify: $(jq -c '{axes,decision_path,primary_pass}' "$c/e/metrics/c4c.json")"
c=$(run_block plain "$T/block.sh" "x/$SID.jsonl" "$SID.jsonl")
[ "$(rn "$c")" = "$SID.jsonl" ] && [ "$(pp "$c")" = true ] && ok "2b corrected block, a path without a leading dash: unchanged behaviour" || no "2b plain path"
# 4. missing, malformed or mismatched reference name: never a primary pass
for k in missing malformed-empty malformed-dir-only malformed-no-jsonl mismatched; do
  case $k in
  missing) rel=- ;; malformed-empty) rel="" ;; malformed-dir-only) rel="-sandbox-c-repo/" ;;
  malformed-no-jsonl) rel="-sandbox-c-repo/$SID" ;; mismatched) rel="-sandbox-c-repo/$OTHER.jsonl" ;;
  esac
  c=$(run_block "neg-$k" "$T/block.sh" "$rel" "$SID.jsonl")
  [ -s "$c/e/metrics/c4c.json" ] && [ "$(pp "$c")" = false ] && ok "4 $k reference name (rn='$(rn "$c")'): session=$(ses "$c"), primary_pass=false" || no "4 $k: rn='$(rn "$c")' pp=$(pp "$c" 2>/dev/null)"
done
# 5. a different session file, or a second file, after resume: never a primary pass
c=$(run_block other-file "$T/block.sh" "$REL" "$OTHER.jsonl")
[ "$(ses "$c")" = new-id ] && [ "$(pp "$c")" = false ] && ok "5 a different session file after resume: session=new-id, primary_pass=false" || no "5 other file: $(ses "$c") $(pp "$c")"
c=$(run_block two-files "$T/block.sh" "$REL" "$SID.jsonl" "$OTHER.jsonl")
[ "$(ses "$c")" = new-id ] && [ "$(pp "$c")" = false ] && ok "5 the original plus another session file: session=new-id, primary_pass=false" || no "5 two files: $(ses "$c") $(pp "$c")"
c=$(run_block dup-file "$T/block.sh" "$REL" "$SID.jsonl" "$SID.jsonl")
[ "$(ses "$c")" = same-id-new-file ] && [ "$(pp "$c")" = false ] && ok "5 the same session file listed twice: session=same-id-new-file, primary_pass=false" || no "5 dup: $(ses "$c") $(pp "$c")"
c=$(run_block no-listing "$T/block.sh" "$REL")
[ "$(ses "$c")" = unavailable ] && [ "$(pp "$c")" = false ] && ok "5 no transcript listing: session=unavailable, primary_pass=false" || no "5 no listing: $(ses "$c") $(pp "$c")"

echo "failures=$fails"; [ "$fails" = 0 ]
