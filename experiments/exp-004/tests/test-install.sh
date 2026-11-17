#!/usr/bin/env bash
# EXP-004 offline tests for live/install-issuer.sh (throwaway local git repo; nothing leaves the temp dir).
# Root-only ownership checks are NOT exercised here (see I09).
# shellcheck disable=SC2016,SC2010,SC2143 # bash -c snippets take $1.. positionally; ls|grep on test-made names
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
base=$(realpath "${EXP004_TMP:-${TMPDIR:-/tmp}}")
T=$(mktemp -d -p "$base" exp004-inst.XXXXXX)
trap '[ "${EXP004_KEEP:-0}" = 1 ] || rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
FAILS=0
pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2"; FAILS=$((FAILS+1)); }
chk() { local id=$1 desc=$2; shift 2; if "$@"; then pass "$id" "$desc"; else fail "$id" "$desc"; fi; }

orig=$T/orig; E=$orig/experiments/exp-004
mkdir -p "$E"
cp -r "$here/." "$E/"
find "$E" -name __pycache__ -prune -exec rm -rf {} +
sh "$E/live/install-issuer.sh" --print-manifest "$E" >"$E/live/MANIFEST.sha256"
g() { git -C "$orig" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
git init -q "$orig"
g add -A; g commit -q -m base
REV=$(g rev-parse HEAD)

src_at() {  # src_at <name> <rev> -> fresh clone, detached
  git clone -q --no-checkout "$orig" "$T/$1" 2>/dev/null
  git -C "$T/$1" -c transfer.fsckObjects=true checkout -q --detach "$2"
}
inst() { local s=$1 f=(); shift; [ "${1:-}" = --replace ] && { f=(--replace); shift; }; sh "$s/experiments/exp-004/live/install-issuer.sh" "${f[@]}" "$s" "$@"; }   # inst <src> [--replace] <rev> <dest>
run() { OUT=$(inst "$@" 2>&1) && RC=0 || RC=$?; }
refused() { [ "$RC" -ne 0 ] && grep -q '^INSTALL REFUSED:' <<<"$OUT"; }
no_dest() { [ ! -e "$1" ]; }
no_litter() { [ -z "$(ls -A "$T/d" 2>/dev/null | grep -v '^dest')" ]; }
mkdir -p "$T/d"

# I01
src_at s1 "$REV"; run "$T/s1" "$REV" "$T/d/dest1"
ok=0; [ "$RC" -eq 0 ] && (cd "$T/d/dest1" && sha256sum -c --strict --quiet "$E/live/MANIFEST.sha256") && ok=1
want=$(cut -c67- "$E/live/MANIFEST.sha256" | sort); have=$(cd "$T/d/dest1" && find . -type f | sed 's|^\./||' | sort)
[ "$want" = "$have" ] || ok=0
[ -x "$T/d/dest1/harness/issuer.py" ] && [ -x "$T/d/dest1/live/issuer-start.sh" ] || ok=0
grep -q "^rev: $REV" <<<"$OUT" && grep -q 'REMINDER: compare' <<<"$OUT" || ok=0
chk I01 "clean install: exit 0, hashes == manifest, only manifest files, rev+reminder printed" test $ok = 1

# I02
run "$T/s1" "${REV:0:12}" "$T/d/dest2"
chk I02 "abbreviated rev refused" bash -c '[ "$1" -ne 0 ] && grep -q "INSTALL REFUSED" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$OUT" "$T/d/dest2"

# I03
OTHER=$(printf '0%.0s' $(seq 40)); run "$T/s1" "$OTHER" "$T/d/dest3"
chk I03 "rev mismatch refused, dest untouched" bash -c '[ "$1" -ne 0 ] && grep -q "HEAD" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$OUT" "$T/d/dest3"

# I04
src_at s4 "$REV"; echo '# tamper' >>"$T/s4/experiments/exp-004/harness/issuer.py"
run "$T/s4" "$REV" "$T/d/dest4"
chk I04 "modified tracked file refused before copying (no dest, no staging)" bash -c '[ "$1" -ne 0 ] && grep -q "modified tracked" <<<"$2" && [ ! -e "$3" ] && [ -z "$(ls -A "$4" | grep -v "^dest[0-9]*$")" ]' _ "$RC" "$OUT" "$T/d/dest4" "$T/d"

# I05
bad=$(sed '1s/^./0/; 1s/^00/11/' "$E/live/MANIFEST.sha256")
[ "$bad" != "$(cat "$E/live/MANIFEST.sha256")" ] || bad=$(sed '1s/^./1/' "$E/live/MANIFEST.sha256")
printf '%s\n' "$bad" >"$E/live/MANIFEST.sha256"; g commit -q -am badhash; REV5=$(g rev-parse HEAD)
src_at s5 "$REV5"; run "$T/s5" "$REV5" "$T/d/dest5"
chk I05 "wrong hash in committed manifest refused" bash -c '[ "$1" -ne 0 ] && grep -q "INSTALL REFUSED" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$OUT" "$T/d/dest5"
git -C "$orig" checkout -q "$REV" -- experiments/exp-004/live/MANIFEST.sha256   # restore good manifest in orig index/tree

# I06 (uncommitted change to file AND manifest)
src_at s6 "$REV"; X=$T/s6/experiments/exp-004
echo '# tamper' >>"$X/harness/issuer.py"; sh "$X/live/install-issuer.sh" --print-manifest "$X" >"$X/live/MANIFEST.sha256"
run "$T/s6" "$REV" "$T/d/dest6"
chk I06 "working tree + manifest edited together (uncommitted) refused via status" bash -c '[ "$1" -ne 0 ] && grep -q "modified tracked" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$OUT" "$T/d/dest6"
# I06b: same, but git status is blinded with assume-unchanged -> committed-blob comparison must catch it
git -C "$T/s6" update-index --assume-unchanged experiments/exp-004/harness/issuer.py experiments/exp-004/live/MANIFEST.sha256
[ -z "$(git -C "$T/s6" status --porcelain --untracked-files=no)" ] || echo "note: status not blinded"
run "$T/s6" "$REV" "$T/d/dest6b"
chk I06b "same with git status blinded (assume-unchanged): refused by git-show comparison" bash -c '[ "$1" -ne 0 ] && grep -q "differs from the one committed" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$OUT" "$T/d/dest6b"

# I07
for kind in dotdot abs; do
  if [ $kind = dotdot ]; then p='harness/../live/issuer-start.sh'; else p='/etc/passwd'; fi
  { cat "$E/live/MANIFEST.sha256"; printf '%s  %s\n' "$(sha256sum <"$E/live/issuer-start.sh" 2>/dev/null | cut -d' ' -f1)" "$p"; } >"$E/live/MANIFEST.sha256.new"
  mv "$E/live/MANIFEST.sha256.new" "$E/live/MANIFEST.sha256"; g commit -q -am "bad-$kind"; R=$(g rev-parse HEAD)
  src_at s7$kind "$R"; run "$T/s7$kind" "$R" "$T/d/dest7$kind"
  chk I07-$kind "manifest path '$p' refused" bash -c '[ "$1" -ne 0 ] && grep -q "malformed line or a path outside" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$OUT" "$T/d/dest7$kind"
  git -C "$orig" checkout -q "$REV" -- experiments/exp-004/live/MANIFEST.sha256
done

# I08
mkdir -p "$T/d/dest8"; echo stale >"$T/d/dest8/stale.txt"
run "$T/s1" "$REV" "$T/d/dest8"
chk I08a "pre-existing non-empty dest refused without --replace (stale file untouched, nothing installed)" bash -c '[ "$1" -ne 0 ] && grep -q "non-empty" <<<"$2" && [ -f "$3/stale.txt" ] && [ ! -e "$3/harness" ]' _ "$RC" "$OUT" "$T/d/dest8"
run "$T/s1" --replace "$REV" "$T/d/dest8"
chk I08b "--replace installs manifest files, reports and keeps extra file" bash -c '[ "$1" -eq 0 ] && grep -q "NOTE:.*stale.txt" <<<"$2" && [ -f "$3/stale.txt" ] && [ -f "$3/harness/issuer.py" ]' _ "$RC" "$OUT" "$T/d/dest8"
echo '# stale old' >>"$T/d/dest8/harness/issuer.py"
run "$T/s1" --replace "$REV" "$T/d/dest8"
chk I08c "--replace overwrites a modified installed manifest file" bash -c '[ "$1" -eq 0 ] && cd "$2" && sha256sum -c --strict --quiet "$3"' _ "$RC" "$T/d/dest8" "$T/s1/experiments/exp-004/live/MANIFEST.sha256"

# I09
if [ "$(id -u)" -eq 0 ]; then echo "SKIP I09: running as root; WARNING path not exercised"
else chk I09 "non-root run prints ownership WARNING" grep -qx 'WARNING: not root: ownership checks skipped (test mode)' <<<"$(inst "$T/s1" "$REV" "$T/d/dest9" 2>&1)"; fi
echo "NOTE: root-only ownership checks (root owner, no group/world-write on src chain, files, dest ancestors; chown) are untested offline."

echo "failures: $FAILS"
[ "$FAILS" -eq 0 ]
