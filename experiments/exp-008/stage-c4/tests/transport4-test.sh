#!/usr/bin/env bash
# Offline test of the C4 package transport (corrective PR after run 1127-1814). No cluster, no network, no credential.
#  1. sizes: the run's 40,960-byte raw-tar element is refused by the stub CLI exactly as OpenShell refused it; the C0-C3
#     27,308-byte element is under the 32,768-byte limit; the corrected gzip payload is within the 24,576-byte budget;
#     boundaries at 32,767 / 32,768 / 32,769 bytes; a poorly compressible package fails the local check.
#  2. the REAL bootstrap (paths remapped) under /bin/sh and bash --posix: valid launch and relaunch, and every failure
#     (corrupted base64, invalid gzip, wrong sha256, missing gzip, sha-valid non-tar) exits nonzero without running the
#     launcher and without extracting a launcher.
#  3. the REAL c0-create step body against the stub CLI: the corrected package sends one create; the original raw-tar
#     transport and a poorly compressible package STOP locally with no create request and no done-c0-create marker.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); if [ -n "${KEEP:-}" ]; then echo "T=$T" >&2; else trap 'rm -rf "$T"' EXIT; fi
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
nb() { printf %s "$1" | LC_ALL=C wc -c; }
SIM=$T/sim; export SIM; mkdir -p "$SIM"; : >"$SIM/cli-calls"; cp "$D/tests/openshell-stub.sh" "$T/cli"; chmod +x "$T/cli"
stubcreate() { : >"$SIM/creates"; "$T/cli" -g exp008c sandbox create --name exp008c4-0101-0101 --from x -- "$@" >/dev/null 2>"$T/create.err"; }

HERE=$D L=$T/l E=$T/e RUN=0101-0101 IMG=x PROV=exp008c-test; mkdir -p "$L" "$E/obs"
# shellcheck source=../launcher4.sh
. "$D/launcher4.sh"
OLD_BOOT=$(sed -n "s/^BOOT='\(.*\)'$/\1/p" "$D/../stage-c/launcher.sh")

# ---------------------------------------------------------------- 1. sizes and limits
pkg_build "$T/c4.tar"; OLD=$(base64 -w0 "$T/c4.tar")
[ "$(sha256sum "$T/c4.tar" | cut -d' ' -f1)" = 5f524cae872a2c2c457f6f66ed2f401f6a8655e1e08b9f041c1b1e43a481c5d1 ] \
  && ok "the run 1127-1814 package is reproduced (sha256 5f524cae..., $(stat -c %s "$T/c4.tar") bytes)" || no "package sha differs from run 1127-1814 (task files changed?)"
[ "$(nb "$OLD")" = 40960 ] && ok "original transport: raw-tar base64 element is 40,960 bytes" || no "original element: $(nb "$OLD")"
stubcreate /bin/sh -c "$OLD_BOOT" "$OLD" "$(sha256sum "$T/c4.tar" | cut -d' ' -f1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'spec.command\[3\]' "$T/create.err" && grep -q 'exceeds 32768 byte limit' "$T/create.err" && [ ! -s "$SIM/creates" ] \
  && ok "stub CLI refuses the 40,960-byte element as OpenShell did (spec.command[3] exceeds 32768 byte limit)" || no "stub on the original element: rc=$rc $(cat "$T/create.err")"
( C4TASK=$D/../stage-c/task; pkg_build "$T/c03.tar" )
C03=$(base64 -w0 "$T/c03.tar")
[ "$(nb "$C03")" = 27308 ] && ok "C0-C3 transport element is 27,308 bytes" || no "C0-C3 element: $(nb "$C03")"
stubcreate /bin/sh -c "$OLD_BOOT" "$C03" x && [ -s "$SIM/creates" ] && ok "stub CLI accepts the 27,308-byte element (under the 32,768-byte limit)" || no "stub refused the C0-C3 element"
[ "$(nb "$C03")" -gt "$PAYLOAD_BUDGET" ] && ok "27,308 bytes would exceed the stricter 24,576-byte experimental budget" || no "budget relation"
create_args
P=$(nb "${LAUNCH[3]}")
[ "$P" -le "$PAYLOAD_BUDGET" ] && ok "corrected C4 payload: $P bytes (budget 24,576; gzip $(sed -n 's/.* gz_bytes=\([0-9]*\).*/\1/p' "$E/obs/c0-pkg.txt") B of a $(stat -c %s "$L/pkg.tar") B tar)" || no "corrected payload $P > budget"
stubcreate "${LAUNCH[@]}" && [ -s "$SIM/creates" ] && ok "stub CLI accepts the corrected argv" || no "stub refused the corrected argv: $(cat "$T/create.err")"
for n in 32767 32768; do x=$(head -c "$n" /dev/zero | tr '\0' A); stubcreate /bin/sh -c "$x" && [ -s "$SIM/creates" ] && ok "stub CLI accepts a $n-byte element" || no "stub refused $n bytes"; done
x=$(head -c 32769 /dev/zero | tr '\0' A); stubcreate /bin/sh -c "$x"; rc=$?
[ "$rc" = 1 ] && grep -q 'spec.command\[2\]' "$T/create.err" && [ ! -s "$SIM/creates" ] && ok "stub CLI refuses a 32,769-byte element and names its index" || no "stub on 32,769 bytes: rc=$rc"
launch_check "$T/lc-ok.txt" && ok "launch_check passes on the corrected argv: $(cut -d' ' -f1-8 "$T/lc-ok.txt")" || no "launch_check corrected: $(cat "$T/lc-ok.txt")"
S_LAUNCH=("${LAUNCH[@]}")
LAUNCH=(/bin/sh -c "$BOOT" "$OLD" "$PKG_SHA"); launch_check "$T/lc-old.txt" && no "launch_check accepted the raw-tar element" \
  || { grep -q 'element-over-limit' "$T/lc-old.txt" && grep -q 'payload-over-budget' "$T/lc-old.txt" && ok "launch_check refuses the 40,960-byte element (element-over-limit, payload-over-budget)" || no "launch_check old: $(cat "$T/lc-old.txt")"; }
LAUNCH=("${S_LAUNCH[@]}"); LAUNCH[3]=${LAUNCH[3]:0:100}; launch_check "$T/lc-trunc.txt" && no "launch_check accepted a truncated payload" || { grep -q 'payload-does-not-decode-to-pkg' "$T/lc-trunc.txt" && ok "launch_check refuses a payload that does not decode to the package" || no "launch_check trunc: $(cat "$T/lc-trunc.txt")"; }
LAUNCH=("${S_LAUNCH[@]}" extra); launch_check "$T/lc-argc.txt" && no "launch_check accepted 6 elements" || { grep -q 'reasons=argc' "$T/lc-argc.txt" && ok "launch_check refuses an unexpected argument count" || no "launch_check argc: $(cat "$T/lc-argc.txt")"; }
LAUNCH=("${S_LAUNCH[@]}"); LAUNCH[4]=$(printf '%064d' 0); launch_check "$T/lc-sha.txt" && no "launch_check accepted a wrong sha element" || { grep -q 'sha-element' "$T/lc-sha.txt" && ok "launch_check refuses a sha256 element that is not the package's" || no "launch_check sha: $(cat "$T/lc-sha.txt")"; }
LAUNCH=("${S_LAUNCH[@]}")
grep -q -E '(sk-ant-|openshell:resolve:|"type":)' "$T"/lc-*.txt "$E/obs/c0-pkg.txt" && no "a check record holds content" || ok "check records hold sizes, hashes and pass/fail only"
# a poorly compressible package (30,000 random bytes, base64 text, appended to a copy of step.sh)
mkdir -p "$T/bigtask"; cp "$D/task/launch.sh" "$D/task/step.sh" "$T/bigtask/"; { echo; printf '# '; head -c 30000 /dev/urandom | base64 -w0; echo; } >>"$T/bigtask/step.sh"
( C4TASK=$T/bigtask L=$T/lbig E=$T/ebig; mkdir -p "$L" "$E/obs"; create_args; launch_check "$T/lc-big.txt"; echo $? >"$T/lc-big.rc" )
[ "$(cat "$T/lc-big.rc")" != 0 ] && grep -q 'payload-over-budget' "$T/lc-big.txt" && ok "a poorly compressible package fails the local check ($(grep -o 'payload_bytes=[0-9]*' "$T/lc-big.txt"))" || no "big package: $(cat "$T/lc-big.txt")"

# ---------------------------------------------------------------- 2. the real bootstrap: success and every failure
mkdir -p "$T/tp"; printf '#!/bin/sh\necho "ran $*" >>"%s/marker-$TPID"\n' "$T" >"$T/tp/launch.sh"; echo p >"$T/tp/prompt.txt"; echo '{}' >"$T/tp/settings.json"; echo 'exit 0' >"$T/tp/step.sh"
chmod 0644 "$T"/tp/*; chmod 0755 "$T/tp/launch.sh" "$T/tp/step.sh"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$T/tp" -cf "$T/tp.tar" launch.sh prompt.txt settings.json step.sh
pkg_gz "$T/tp.tar" "$T/tp.gz"; GOOD=$(base64 -w0 "$T/tp.gz"); GSHA=$(sha256sum "$T/tp.tar" | cut -d' ' -f1)
mkdir -p "$T/nogz"; for b in base64 sha256sum tar mkdir; do ln -s "$(command -v "$b")" "$T/nogz/$b"; done
head -c 2000 /dev/urandom >"$T/junk"; JGZ=$(gzip -9 -n -c <"$T/junk" | base64 -w0); JSHA=$(sha256sum <"$T/junk" | cut -d' ' -f1)
boot() { # boot <shell-cmd> <case> <payload> <sha> [PATH]: one run of the real bootstrap with /sandbox/c remapped
  local sb=$T/sb-$2; local b; b=$(sed -e "s#/sandbox/c#$sb/c#g" <<<"$BOOT")
  env -i PATH="${5:-/usr/bin:/bin}" TPID="$2" $1 -c "$b" "$3" "$4" >/dev/null 2>"$T/boot-$2.err"
}
for sh in /bin/sh "/usr/bin/bash --posix"; do
  k=${sh// /}; k=${k//\//}
  boot "$sh" "$k-ok" "$GOOD" "$GSHA" && [ "$(cat "$T/marker-$k-ok" 2>/dev/null)" = "ran " ] && [ "$(cat "$T/sb-$k-ok/c/pkg.sha256")" = "$GSHA" ] \
    && cmp -s "$T/sb-$k-ok/c/pkg.tar" "$T/tp.tar" && ok "[$sh] valid payload: decoded, sha256 of the original tar verified, launcher run" || no "[$sh] valid: $(cat "$T/boot-$k-ok.err")"
  boot "$sh" "$k-ok" "$GOOD" "$GSHA" && [ "$(grep -c '^ran' "$T/marker-$k-ok")" = 2 ] && ok "[$sh] relaunch (sandbox start) over the existing state: same transport, launcher run again" || no "[$sh] relaunch"
  fcase() { # fcase <name> <payload> <sha> [PATH]
    boot "$sh" "$k-$1" "$2" "$3" "${4:-}"; local rc=$?
    [ "$rc" != 0 ] && [ ! -e "$T/marker-$k-$1" ] && [ ! -e "$T/sb-$k-$1/c/pkg/launch.sh" ] \
      && ok "[$sh] $1: exit $rc, launcher not run, nothing extracted" || no "[$sh] $1: rc=$rc marker=$([ -e "$T/marker-$k-$1" ] && echo yes || echo no)"
  }
  fcase corrupted-base64 "${GOOD:0:40}!!!!${GOOD:44}" "$GSHA"
  fcase truncated-payload "${GOOD:0:$(( ${#GOOD} / 2 ))}" "$GSHA"
  fcase invalid-gzip "$(head -c 3000 /dev/urandom | base64 -w0)" "$GSHA"
  fcase raw-tar-not-gzip "$(base64 -w0 "$T/tp.tar")" "$GSHA"
  fcase wrong-sha256 "$GOOD" "$JSHA"
  [ ! -e "$T/sb-$k-wrong-sha256/c/pkg.sha256" ] && [ ! -e "$T/sb-$k-missing-gzip/c/pkg.sha256" ] && ok "[$sh] no pkg.sha256 is recorded unless the original tar verified" || no "[$sh] pkg.sha256 written before verification"
  fcase missing-gzip "$GOOD" "$GSHA" "$T/nogz"
  fcase sha-valid-not-a-tar "$JGZ" "$JSHA"
done

# ---------------------------------------------------------------- 3. the real c0-create body: no create request unless the local check passes
H=$D/stagec4.sh
awk '/^now\(\) \{/ {p=1} /^# =+ steps$/ {p=0} p' "$H" >"$T/lib.sh"
{ echo "run_c0create() {"; awk '$0 ~ "^c0-create\\)" {p=1; next} p && /^  ;;$/ {exit} p' "$H"; echo "}"; } >"$T/step-c0.sh"
grep -q 'launch_check "$E/obs/c0-launch-result.txt"' "$T/step-c0.sh" && ok "c0-create body extracted" || no "c0-create extraction"
c0_case() { # c0_case <name> [setup]: the real c0-create body; the stub sandbox get then fails so the step STOPs after create
  local s=$T/c0-$1; mkdir -p "$s/e/obs" "$s/l"
  ( SIM=$s; export SIM; : >"$SIM/cli-calls"; touch "$SIM/get-fail"; E=$s/e L=$s/l TL=$s/tl STEP=c0-create RUN=0101-0101 SBX=exp008c4-0101-0101 GWNAME=exp008c HX=$T/hx NS=openshell
    # shellcheck source=/dev/null
    . "$T/lib.sh"; . "$D/launcher4.sh"; CLI=$T/cli OENV=(env SIM="$SIM")
    log() { echo "$*" >>"$TL"; }; stop() { echo "STOP: $*" >>"$E/STOPPED"; exit 3; }; fail() { echo "FAIL: $*" >>"$s/fails"; exit 4; }
    guard_full() { :; }; grab_logs() { :; }; touch "$E/sampler.pid"
    eval "${2:-}"; . "$T/step-c0.sh"; run_c0create ) >"$s/out" 2>&1
  echo "$s"
}
creates() { grep -c '^sandbox create ' "$1/cli-calls"; }
s=$(c0_case corrected)
[ "$(creates "$s")" = 1 ] && [ -e "$s/e/done-c0-create" ] && grep -q '^launch_check=pass ' "$s/e/obs/c0-launch-result.txt" && ok "c0-create, corrected package: local check passed, one create request, marker written" || no "c0 corrected: creates=$(creates "$s") $(cat "$s/e/obs/c0-launch-result.txt" 2>/dev/null)"
s=$(c0_case original-transport 'create_args() { pkg_build "$L/pkg.tar"; PKG_SHA=$(sha256sum "$L/pkg.tar" | cut -d" " -f1); CREATE=(--from "$IMG" --provider "$PROV"); LAUNCH=(/bin/sh -c "$BOOT" "$(base64 -w0 "$L/pkg.tar")" "$PKG_SHA"); }')
[ "$(creates "$s")" = 0 ] && [ ! -e "$s/e/done-c0-create" ] && grep -q 'no create request sent' "$s/e/STOPPED" && grep -q 'max_elem_bytes=40960 ' "$s/e/obs/c0-launch-result.txt" \
  && ok "c0-create, original 40,960-byte transport: STOP locally, no create request, no done-c0-create" || no "c0 original: creates=$(creates "$s") $(cat "$s/e/STOPPED" 2>/dev/null)"
s=$(c0_case poorly-compressible "C4TASK=$T/bigtask")
[ "$(creates "$s")" = 0 ] && [ ! -e "$s/e/done-c0-create" ] && grep -q 'payload-over-budget' "$s/e/obs/c0-launch-result.txt" && ok "c0-create, poorly compressible package: STOP locally, no create request" || no "c0 big: creates=$(creates "$s")"
s=$(c0_case nogzip-host 'pkg_gz() { return 1; }')
[ "$(creates "$s")" = 0 ] && [ ! -e "$s/e/done-c0-create" ] && ok "c0-create, compression unavailable on the workstation: STOP locally, no create request" || no "c0 nogzip: creates=$(creates "$s")"
s=$(c0_case after-stop 'echo prior >"$E/STOPPED"')
[ "$(creates "$s")" = 0 ] && [ ! -e "$s/e/obs/c0-launch-result.txt" ] && grep -q 'a previous step stopped' "$s/fails" && ok "c0-create after a STOP: refused before packaging" || no "c0 after-stop"
s=$(c0_case twice 'touch "$E/done-c0-create"')
[ "$(creates "$s")" = 0 ] && grep -q 'already ran' "$s/fails" && ok "c0-create twice: refused (single attempt)" || no "c0 twice"

echo "failures=$fails"; [ "$fails" = 0 ]
