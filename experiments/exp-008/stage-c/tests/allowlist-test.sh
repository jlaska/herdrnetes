#!/usr/bin/env bash
# Static check of stagec.sh: every cluster/CLI/terminal action goes through its allowlisted wrapper.
# Offline: reads the script text only.
set -uo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)/stagec.sh
fails=0; no() { echo "FAIL - $*"; fails=$((fails + 1)); }; ok() { echo "ok   - $*"; }
# map each line to the enclosing function (or step) name
annot() { awk '
  /^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/ { fn=$1; sub(/\(\).*/,"",fn) }
  /^  [a-z0-9_-]+\)$/ || /^[a-z0-9_-]+\)/ { st=$1; sub(/\).*/,"",st) }
  /^[a-z0-9_|-]+\)/ { fn="step:" st }
  { print fn "\t" NR "\t" $0 }' "$H"; }
code() { annot | grep -v -P '\t\s*#' | sed -E 's/[[:space:]]+# [^"'"'"']*$//'; } # drop comment lines and trailing comments
# 1. direct kubectl only in K (read), kw (mutating allowlist), kx (exec), sampler watches, the _tr_probe ls
bad=$(code | grep -F '"${KC[@]}"' | grep -v -E '^(K|kw|kx|KWATCH|sampler|step:_tr_probe|step:c2)	' | grep -v 'KC=(')
[ -z "$bad" ] && ok "raw kubectl confined to K/kw/kx/watch" || no "raw kubectl outside wrappers: $bad"
c2=$(code | grep -F '"${KC[@]}"' | grep -E '^step:c2	')
grep -q -v -E 'get pod "\$GW_POD"' <<<"$c2" && no "c2 raw kubectl other than get pod: $c2" || ok "c2 raw kubectl is a read (get pod) only"
# 2. no kubectl mutation verbs outside kw's case list
bad=$(code | sed -E 's/(log|stop|fail) "[^"]*"//g' | grep -E '(\bK|KC\[@\]\}"|kubectl)( [^|;]*)? (delete|patch|apply|edit|replace|annotate|label|cordon|drain|rollout|cp|scale|exec)\b' | grep -v -E '^(kw|kx)	')
[ -z "$bad" ] && ok "no kubectl delete/patch/apply/... anywhere" || no "mutation verb: $bad"
# 3. the pinned CLI only via O and client_start
bad=$(code | grep -F '"$CLI"' | grep -v -E '^(O|client_start)	' | grep -v 'sha256sum "$CLI"')
[ -z "$bad" ] && ok "openshell CLI only via O/client_start" || no "CLI outside wrappers: $bad"
# 4. no credential/provider/profile mutation in executable lines
bad=$(code | grep -E 'provider (create|delete|update)|profile (import|delete|update)|--credential|--from-existing|--auto-providers|ANTHROPIC_API_KEY=')
[ -z "$bad" ] && ok "no provider/profile/credential mutation" || no "credential path: $bad"
# 5. keys sent to tmux only from type_line, ctrl_l, client_detach
bad=$(code | grep -F 'send-keys' | grep -v -E '^(type_line|ctrl_l|client_detach)	')
[ -z "$bad" ] && ok "send-keys confined" || no "send-keys outside wrappers: $bad"
# 6. kill only in client_kill (SIGKILL of the client tree) and the sampler's own process group
bad=$(code | grep -E '(^|[[:space:];&(])kill[[:space:]]' | grep -v -E '^(client_kill|sampler)	')
[ -z "$bad" ] && ok "kill confined to client_kill/sampler" || no "kill elsewhere: $bad"
# 7. every mutating step is single-attempt
grep -q 'done-cleanup" \] || fail "cleanup already ran' "$H" && ok "cleanup has its own single-attempt marker (runs after STOP)" || no "cleanup marker"
for st in c0-create c0-baseline c1 c1-reattach c2 c2-reattach; do
  grep -q -E "^$st\).*once $st|^$st\)$" "$H" && awk -v s="$st" '$0 ~ "^"s"\\)" {f=1} f && /once/ {print; exit}' "$H" | grep -q "once $st" && ok "$st is once-only" || no "$st lacks once"
done
# 8. the kw allowlist contains only scale operations
kwc=$(awk '/^kw\(\)/{f=1} f&&/^}/{exit} f' "$H" | grep -E '^\s+"[a-z]' )
grep -q -v 'scale statefulset' <<<"$kwc" && no "kw allows a non-scale mutation" || ok "kw allows scale only"
echo "failures=$fails"; [ "$fails" = 0 ]
