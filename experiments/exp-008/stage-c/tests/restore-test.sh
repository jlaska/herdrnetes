#!/usr/bin/env bash
# Correction C regression test: restore-check.sh validates the gateway StatefulSet generation and the
# provider/profile state explicitly; arbitrary changes are never classified as clean. Offline.
set -uo pipefail
RC=$(cd "$(dirname "$0")/.." && pwd)/restore-check.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
expect() { local want=$1; shift; local got; got=$(bash "$RC" "$@"); case $got in $want) ok "$want <- ${*:1:1} ${T:+}$(basename "${3:-}")" ;; *) no "want '$want' got '$got' ($*)" ;; esac; }
g() { echo "gen=$1" >"$T/$2"; }
op() { echo "t=1 rc=$1 gen_before=$2 gen_after=$3 op=scale statefulset/openshell --replicas=$4" >>"$T/$5"; }

# --- generation
g 7 pre; g 9 post; op 0 7 8 0 ops-ok; op 0 8 9 1 ops-ok
expect 'explained pre=7 post=9 scale_ops=2' generation "$T/pre" "$T/post" "$T/ops-ok"
g 7 post0; expect 'explained pre=7 post=7 scale_ops=0' generation "$T/pre" "$T/post0" "$T/none"
g 10 post10; expect 'UNEXPLAINED reason=change-outside-harness-after-last-op*' generation "$T/pre" "$T/post10" "$T/ops-ok"
expect 'UNEXPLAINED reason=change-outside-harness-after-last-op*' generation "$T/pre" "$T/post" "$T/none"   # +2 with no recorded ops
op 0 7 8 0 ops-gap; op 0 9 10 1 ops-gap; g 10 p10
expect 'UNEXPLAINED reason=change-outside-harness-before-op2*' generation "$T/pre" "$T/p10" "$T/ops-gap"
op 0 7 9 0 ops-jump; expect 'UNEXPLAINED reason=op1-generation-step-2' generation "$T/pre" "$T/post" "$T/ops-jump"
op 1 7 8 0 ops-failchg; g 8 p8; expect 'UNEXPLAINED reason=failed-op1-changed-generation' generation "$T/pre" "$T/p8" "$T/ops-failchg"
op 1 7 7 0 ops-fail; op 0 7 8 0 ops-fail; expect 'explained pre=7 post=8 scale_ops=2' generation "$T/pre" "$T/p8" "$T/ops-fail"
echo "t=1 rc=0 gen_before=unreadable gen_after=8 op=x" >"$T/ops-unr"; expect 'UNEXPLAINED reason=op1-unreadable' generation "$T/pre" "$T/p8" "$T/ops-unr"
echo "error: the server doesn't have a resource type" >"$T/bad"; expect 'UNEXPLAINED reason=generation-unreadable' generation "$T/bad" "$T/post" "$T/ops-ok"

# --- names (providers: one name per line; profiles: a table)
printf 'exp008b-old\nexp008c-anthropic\nother\n' >"$T/pv-pre"
printf 'exp008b-old\nother\n' >"$T/pv-removed"; cp "$T/pv-pre" "$T/pv-same"
printf 'exp008b-old\nexp008c-anthropic\nnew-one\nother\n' >"$T/pv-added"
printf 'exp008c-anthropic\nother\n' >"$T/pv-lost"; printf 'exp008b-old\nother\nzzz\n' >"$T/pv-swap"
printf 'exp008b-old\nexp008c-anthropic-2\nother\n' >"$T/pv-similar"
expect removed names "$T/pv-pre" "$T/pv-removed" exp008c-anthropic
expect present-owner-delete-pending names "$T/pv-pre" "$T/pv-same" exp008c-anthropic
expect 'UNEXPECTED added=1 removed=0' names "$T/pv-pre" "$T/pv-added" exp008c-anthropic
expect 'UNEXPECTED added=0 removed=1' names "$T/pv-pre" "$T/pv-lost" exp008c-anthropic
expect 'UNEXPECTED added=1 removed=1' names "$T/pv-pre" "$T/pv-swap" exp008c-anthropic
expect 'UNVERIFIABLE reason=pre-lists-experiment-name-0-times' names "$T/pv-similar" "$T/pv-removed" exp008c-anthropic
expect 'UNVERIFIABLE reason=list-missing' names "$T/pv-pre" "$T/nope" exp008c-anthropic
printf 'ID                    TYPE      SCOPE\nclaude-code-exp008c   provider  workspace\n' >"$T/pf-pre"; printf 'ID                    TYPE      SCOPE\n' >"$T/pf-post"
expect removed names "$T/pf-pre" "$T/pf-post" claude-code-exp008c
echo "error: unrecognized subcommand 'profile'" >"$T/pf-err"
expect 'UNVERIFIABLE reason=pre-lists-experiment-name-0-times' names "$T/pf-err" "$T/pf-err" claude-code-exp008c
echo "ERROR provider-list-failed" >"$T/pv-err"; : >"$T/pv-empty"; printf 'exp008c-anthropic\n' >"$T/pv-only"
expect 'UNVERIFIABLE reason=list-failed-post' names "$T/pv-only" "$T/pv-err" exp008c-anthropic
expect 'UNVERIFIABLE reason=list-failed-pre' names "$T/pv-err" "$T/pv-empty" exp008c-anthropic
expect removed names "$T/pv-only" "$T/pv-empty" exp008c-anthropic   # a genuinely empty list after deletion (no ERROR marker)
printf 'claude-code-exp008c  provider  INFERENCE  user  workspace\n' >"$T/pf-norm"; : >"$T/pf-norm-empty"
expect removed names "$T/pf-norm" "$T/pf-norm-empty" claude-code-exp008c   # normalised table, "No profiles found." -> empty

# --- verdict
: >"$T/nodiff"; echo diff-crd.txt >"$T/diff"
E='explained pre=7 post=9 scale_ops=2'
expect 'restoration=matches-pre*' verdict "$T/nodiff" "$E" removed removed
expect 'restoration=INCOMPLETE pending-owner-delete=providers,profiles' verdict "$T/nodiff" "$E" present-owner-delete-pending present-owner-delete-pending
expect 'restoration=INCOMPLETE pending-owner-delete=profiles' verdict "$T/nodiff" "$E" removed present-owner-delete-pending
expect 'restoration=NOT-CLEAN inventory:diff-crd.txt' verdict "$T/diff" "$E" removed removed
expect 'restoration=NOT-CLEAN generation:UNEXPLAINED_reason=*' verdict "$T/nodiff" "UNEXPLAINED reason=op1-generation-step-2" removed removed
expect 'restoration=NOT-CLEAN providers:UNEXPECTED_added=1_removed=0' verdict "$T/nodiff" "$E" "UNEXPECTED added=1 removed=0" removed
expect 'restoration=NOT-CLEAN profiles:UNVERIFIABLE_reason=*' verdict "$T/nodiff" "$E" removed "UNVERIFIABLE reason=list-missing"
expect 'restoration=NOT-CLEAN generation:* providers:*' verdict "$T/nodiff" "UNEXPLAINED reason=x" "UNEXPECTED added=1 removed=0" present-owner-delete-pending
echo "failures=$fails"; [ "$fails" = 0 ]
