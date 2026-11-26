#!/usr/bin/env bash
# EXP-008 Stage C: explicit restoration checks used by `stagec.sh post` (offline-testable; no cluster access).
#
#   restore-check.sh generation <pre gen file> <post gen file> <scale-ops file>
#       The gateway StatefulSet generation may differ from `pre` only by the M5 operations the harness itself
#       recorded (obs/scale-ops.txt: rc, gen_before, gen_after per operation). The chain must be unbroken:
#       op1.gen_before = pre, each successful op adds exactly 1, a failed op adds 0, and post = the last
#       gen_after. Prints "explained pre=N post=M scale_ops=K" or "UNEXPLAINED reason=...".
#
#   restore-check.sh names <pre list> <post list> <experiment name>
#       Provider/profile state, compared as whitespace-normalized non-empty rows (the CLI re-aligns its table
#       columns when the longest name goes, and an empty list may print a blank line: run 1125-2153 post 2).
#       `pre` must list the experiment's name exactly once (as a whole field). Prints
#       "removed" (post = pre without that line), "present-owner-delete-pending" (post = pre), or
#       "UNEXPECTED added=N removed=N" / "UNVERIFIABLE reason=..." for anything else.
#
#   restore-check.sh verdict <unexpected-diffs file> <generation result> <providers result> <profiles result>
#       restoration=matches-pre only when no other inventory file differs, the generation is explained and
#       both names checks say "removed"; INCOMPLETE when only the owner's provider/profile deletion is
#       pending; NOT-CLEAN otherwise. Arbitrary changes are never accepted as clean.
set -uo pipefail
num() { sed -n 's/^gen=\([0-9][0-9]*\)$/\1/p' "$1" 2>/dev/null | head -n 1; }
case ${1:-} in
generation)
  pre=$(num "$2"); post=$(num "$3"); ops=$4
  [ -n "$pre" ] && [ -n "$post" ] || { echo "UNEXPLAINED reason=generation-unreadable"; exit 0; }
  cur=$pre n=0
  if [ -s "$ops" ]; then
    while IFS= read -r line; do
      n=$((n + 1))
      rc=$(sed -n 's/.* rc=\([0-9][0-9]*\) .*/\1/p' <<<"$line")
      gb=$(sed -n 's/.* gen_before=\([0-9][0-9]*\) .*/\1/p' <<<"$line")
      ga=$(sed -n 's/.* gen_after=\([0-9][0-9]*\) .*/\1/p' <<<"$line")
      [ -n "$rc" ] && [ -n "$gb" ] && [ -n "$ga" ] || { echo "UNEXPLAINED reason=op$n-unreadable"; exit 0; }
      [ "$gb" = "$cur" ] || { echo "UNEXPLAINED reason=change-outside-harness-before-op$n expected=$cur seen=$gb"; exit 0; }
      if [ "$rc" = 0 ]; then
        [ "$ga" = $((gb + 1)) ] || { echo "UNEXPLAINED reason=op$n-generation-step-$((ga - gb))"; exit 0; }
      else
        [ "$ga" = "$gb" ] || { echo "UNEXPLAINED reason=failed-op$n-changed-generation"; exit 0; }
      fi
      cur=$ga
    done <"$ops"
  fi
  [ "$post" = "$cur" ] || { echo "UNEXPLAINED reason=change-outside-harness-after-last-op expected=$cur seen=$post"; exit 0; }
  echo "explained pre=$pre post=$post scale_ops=$n"
  ;;
names)
  pre=$2 post=$3 name=$4
  [ -r "$pre" ] && [ -r "$post" ] || { echo "UNVERIFIABLE reason=list-missing"; exit 0; }
  for f in "$pre" "$post"; do grep -q '^ERROR ' "$f" && { echo "UNVERIFIABLE reason=list-failed-$([ "$f" = "$pre" ] && echo pre || echo post)"; exit 0; }; done
  N=$(mktemp -d); trap 'rm -rf "$N"' EXIT
  awk 'NF {$1 = $1; print}' "$pre" >"$N/pre"; awk 'NF {$1 = $1; print}' "$post" >"$N/post"; pre=$N/pre post=$N/post
  hit() { awk -v n="$name" '{for (i = 1; i <= NF; i++) if ($i == n) {print NR; next}}' "$1"; }
  h=$(hit "$pre")
  [ "$(grep -c . <<<"$h")" = 1 ] || { echo "UNVERIFIABLE reason=pre-lists-experiment-name-$(grep -c . <<<"$h")-times"; exit 0; }
  if cmp -s "$pre" "$post"; then echo "present-owner-delete-pending"; exit 0; fi
  if cmp -s <(sed "${h}d" "$pre") "$post"; then echo "removed"; exit 0; fi
  added=$(diff <(sort "$pre") <(sort "$post") | grep -c '^>'); removed=$(diff <(sort "$pre") <(sort "$post") | grep -c '^<')
  echo "UNEXPECTED added=$added removed=$removed"
  ;;
verdict)
  why=()
  [ -s "$2" ] && why+=("inventory:$(tr '\n' ',' <"$2" | sed 's/,$//')")
  case $3 in explained\ *) ;; *) why+=("generation:${3// /_}") ;; esac
  pend=()
  for x in "providers=$4" "profiles=$5"; do
    case ${x#*=} in removed) ;; present-owner-delete-pending) pend+=("${x%%=*}") ;; *) why+=("${x%%=*}:${x#*=}") ;; esac
  done
  why=("${why[@]// /_}")
  if [ "${#why[@]}" -gt 0 ]; then echo "restoration=NOT-CLEAN ${why[*]}"
  elif [ "${#pend[@]}" -gt 0 ]; then echo "restoration=INCOMPLETE pending-owner-delete=$(IFS=,; echo "${pend[*]}")"
  else echo "restoration=matches-pre (generation explained by recorded scale operations; experiment provider and profile removed)"; fi
  ;;
*) sed -n '2,19p' "$0"; exit 2 ;;
esac
