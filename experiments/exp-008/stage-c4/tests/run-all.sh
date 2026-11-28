#!/usr/bin/env bash
# Runs the complete offline suite: C4 (this directory) and the unchanged C0-C3 suite. No cluster, no network
# (the two pinned-binary tests run in loopback-only namespaces), no credential. Prints one line per suite.
set -uo pipefail
R=$(cd "$(dirname "$0")/../../../.." && pwd); C4=$R/experiments/exp-008/stage-c4/tests; C0=$R/experiments/exp-008/stage-c/tests
rc=0
py() { local o; o=$(cd "$R" && uv run --no-project python -I -m unittest discover -s "$1" 2>&1); echo "$o" | tail -n 3 | grep -E '^(Ran|OK|FAILED)' | tr '\n' ' '; echo; grep -q '^OK' <<<"$o" || rc=1; }
sh_() { local o s; o=$(bash "$1" </dev/null 2>&1); s=$?
  printf '%-28s ok=%s fail=%s %s\n' "$(basename "$1")" "$(grep -c '^ok' <<<"$o")" "$(grep -c '^FAIL' <<<"$o")" "$( [ $s = 2 ] && echo NOT-RUN || { [ $s = 0 ] && echo PASS || echo FAILED; })"
  [ $s = 0 ] || [ $s = 2 ] || rc=1; [ $s = 2 ] && grep 'NOT RUN' <<<"$o"; }
echo "== C4 Phase 1 (stage-c4)"; printf '%-28s ' test_metrics4.py; py "$C4"
for t in launch4 step4 allowlist4 wrapper4 transport4 c4c-bundle c0c3-unchanged resume-regression; do sh_ "$C4/$t-test.sh"; done
echo "== C0-C3 (stage-c, unchanged)"; printf '%-28s ' test_stagec.py; py "$C0"
for t in launch allowlist wrapper scan restore sampler-gate header-capture; do sh_ "$C0/$t-test.sh"; done
echo "== static"; for f in "$R"/experiments/exp-008/stage-c4/{stagec4.sh,launcher4.sh,task/launch.sh,task/step.sh} "$C4"/*.sh; do bash -n "$f" || rc=1; done
shellcheck -S error "$R"/experiments/exp-008/stage-c4/{stagec4.sh,launcher4.sh,task/launch.sh,task/step.sh} "$C4"/*.sh && echo "bash -n and shellcheck -S error: clean" || rc=1
exit $rc
