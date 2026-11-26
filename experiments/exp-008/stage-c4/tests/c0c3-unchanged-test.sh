#!/usr/bin/env bash
# The C0-C3 harness that ran 1126-1017 is byte-identical: every file listed in the run record's "Harness file
# hashes" still has that sha256, and nothing else was added to stage-c/ outside results/ and tests/fixtures.
set -uo pipefail
C0=$(cd "$(dirname "$0")/../../stage-c" && pwd)
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
L=$(awk '/^## Harness file hashes/{f=1} f && /^[0-9a-f]{64}  /' "$C0/results/1126-1017.md")
[ "$(grep -c . <<<"$L")" = 21 ] && ok "21 harness hashes listed in results/1126-1017.md" || no "hash list: $(grep -c . <<<"$L")"
(cd "$C0" && sha256sum -c --quiet <<<"$L") && ok "every C0-C3 harness file matches its recorded sha256" || no "a C0-C3 harness file changed"
now=$(cd "$C0" && find . -type f ! -path './results/*' ! -path '*/__pycache__/*' ! -path './tests/fixtures/*' | sed 's#^\./##' | sort)
[ "$now" = "$(awk '{print $2}' <<<"$L" | sort)" ] && ok "no file added to or removed from the C0-C3 harness" || no "file set differs: $(diff <(echo "$now") <(awk '{print $2}' <<<"$L" | sort) | tr '\n' ' ')"
echo "failures=$fails"; [ "$fails" = 0 ]
