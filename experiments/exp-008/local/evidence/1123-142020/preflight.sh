#!/usr/bin/env bash
# EXP-008 run 4 preflight (run 3's script; two corrections for its explained false FAILs)
# EXP-008 run 3 preflight (P1 host checks, B0 baselines, P2 release verification).
# Writes only under /tmp/hx8/<RUN>. Reads owner metadata (names/sizes/mtimes) for B0 only.
# Usage: preflight.sh <RUN> <PORT>
set -u -o pipefail
unset SSH_AUTH_SOCK GNUPGHOME
umask 077
RUN=$1 PORT=$2
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) # as run, this was an absolute path to the checkout
DEMO=$REPO/experiments/exp-008/local/demo.sh
PREV=$REPO/experiments/exp-008/local/evidence/1123-122157/p2 # run 3 (committed copies are redacted)
ROOT=/tmp/hx8/$RUN
CLI_SHA=2db8e54f63feebe9f994efaf6004bbd45c55bc70ea455eda42fe82a0ea7c7e69
GW_SHA=865e8c5ae15a599ca001d023efc137527ff8e102b0cccb90a85184a1c6e33978
HERDR_SHA=32f81aa0797c6361d074263d22db478762ec9950c0315e32f9b4309359affc66
TAG_SHA=ce58cf8e9b953281352d98a637e41616295b1318
SIGNER=https://github.com/NVIDIA/OpenShell/.github/workflows/release-publish.yml@refs/heads/main
RUNID=44149201744
CLI_TGZ=openshell-x86_64-unknown-linux-musl.tar.gz
GW_TGZ=openshell-gateway-x86_64-unknown-linux-gnu.tar.gz
RT_DIG=sha256:e57d07cd6cc1fc314b80368d6b51ec6fbf825fb62cd8f081312941180846866f
SUP_DIG=sha256:f1ec231b5dbe5b6a40c33acb2ac847995aabb959a56134ef6d7d7aa4f43199d3
WL_DIG=sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16
FAILS=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "PREFLIGHT ABORT: $*"; exit 1; }

[[ $RUN =~ ^[0-9]{4}-[0-9]{6}$ ]] || die "bad run id"
# ---------------------------------------------------------------- run root
[ -e /tmp/hx8 ] || mkdir -m 700 /tmp/hx8
[ -d /tmp/hx8 ] && [ ! -L /tmp/hx8 ] && [ "$(stat -c %u /tmp/hx8)" = "$(id -u)" ] || die "/tmp/hx8 not ours"
[ ! -e "$ROOT" ] || die "$ROOT already exists"
mkdir -m 700 "$ROOT" || die "mkdir root"
mkdir -p "$ROOT"/{dl,bin/cli,bin/gw,p2,baseline-pre,raw} "$ROOT"/iso/{home,cfg,state,data,run,sysgw}

# ---------------------------------------------------------------- P1 host
echo "## P1 $(date -u +%FT%TZ)"
[ "$(id -u)" != 0 ] && ok "rootless (uid $(id -u))" || bad "running as root"
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] && ok "cgroup v2" || bad "cgroup v2"
grep -q landlock /sys/kernel/security/lsm && ok "landlock in LSM list" || bad "landlock not in LSM list"
abi=$(python3 -I -c 'import ctypes; l=ctypes.CDLL(None, use_errno=True); r=l.syscall(444, None, 0, 1); print(r if r >= 0 else "errno%d" % ctypes.get_errno())')
[[ $abi =~ ^[0-9]+$ ]] && [ "$abi" -ge 3 ] && ok "landlock ABI $abi" || bad "landlock ABI $abi"
grep -qw user_notif /proc/sys/kernel/seccomp/actions_avail && ok "seccomp user_notif" || bad "seccomp user_notif"
[ -S "/run/user/$(id -u)/bus" ] && ok "user bus" || bad "user bus"
pv=$(podman --version) && [ "$pv" = "podman version 5.8.9" ] && ok "$pv" || bad "podman version: $pv"
[ -z "$(ss -Htln "sport = :$PORT")" ] && [ "$PORT" != 17670 ] && ok "port $PORT free" || bad "port $PORT"
HB=$(command -v herdr); hv=$("$HB" --version 2>&1)
[ "$hv" = "herdr 0.9.5" ] && [ "$(sha256sum "$HB" | cut -d' ' -f1)" = "$HERDR_SHA" ] && ok "$hv sha256 match" || bad "herdr: $hv"
uname -r

# ---------------------------------------------------------------- B0 (same listing code as demo.sh bl_one)
echo "## B0"
eval "$(awk 'index($0, "bl_one() {") == 1 { f = 1 } f { print } f && $0 == "}" { exit }' "$DEMO")"
SS=/usr/bin/ss
for f in openshell-config.txt openshell-state.txt ssh-meta.txt listeners.txt; do bl_one "$f" >"$ROOT/baseline-pre/$f"; done
(cd "$ROOT/baseline-pre" && sha256sum -- *.txt >SHA256SUMS) && ok "B0 captured ($(wc -l <"$ROOT/baseline-pre/listeners.txt") listener lines)" || bad "B0"

# ---------------------------------------------------------------- P2 release
echo "## P2"
t=$(gh api repos/ai-openshell/openshell/git/ref/tags/v0.1.9 --jq '.object.type + " " + .object.sha')
if [ "${t%% *}" = tag ]; then t="commit $(gh api "repos/ai-openshell/openshell/git/tags/${t##* }" --jq .object.sha)"; fi
[ "${t##* }" = "$TAG_SHA" ] && ok "tag v0.1.9 -> $TAG_SHA" || bad "tag v0.1.9 -> $t"
gh release download v0.1.9 -R ai-openshell/openshell -D "$ROOT/dl" -p "$CLI_TGZ" -p "$GW_TGZ" \
  -p openshell-checksums-sha256.txt -p openshell-gateway-checksums-sha256.txt || bad "release download"
for pair in "$CLI_TGZ:openshell-checksums-sha256.txt" "$GW_TGZ:openshell-gateway-checksums-sha256.txt"; do
  tg=${pair%%:*} cs=${pair##*:}
  want=$(awk -v n="$tg" '{ x = $2; sub(/^\*/, "", x) } x == n { print $1 }' "$ROOT/dl/$cs")
  have=$(sha256sum "$ROOT/dl/$tg" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$have" ] && ok "checksum $tg $have" || bad "checksum $tg want=$want have=$have"
done
: >"$ROOT/p2/attestation-diag.txt"
for tg in "$CLI_TGZ" "$GW_TGZ"; do
  gh attestation verify "$ROOT/dl/$tg" --owner NVIDIA --format json >"$ROOT/raw/att-$tg.json" 2>"$ROOT/raw/att-$tg.err"; rc=$?
  echo "$ROOT/dl/$tg owner=NVIDIA exit=$rc" >>"$ROOT/p2/attestation-diag.txt"
  { echo "exit=$rc"
    jq -r '.[0] | [.verificationResult.signature.certificate.buildSignerURI, .verificationResult.signature.certificate.sourceRepositoryURI,
      .verificationResult.signature.certificate.sourceRepositoryDigest, .verificationResult.signature.certificate.sourceRepositoryRef,
      .verificationResult.signature.certificate.runInvocationURI, .verificationResult.statement.predicateType] | @tsv' "$ROOT/raw/att-$tg.json" 2>/dev/null
  } >"$ROOT/p2/att-$tg.txt"
  line=$(sed -n 2p "$ROOT/p2/att-$tg.txt")
  [ "$rc" = 0 ] && [ "$(cut -f1 <<<"$line")" = "$SIGNER" ] && grep -q "/runs/$RUNID/" <<<"$line" && ok "attestation $tg ($(cut -f3 <<<"$line"))" || bad "attestation $tg rc=$rc $line"
done
for im in sandbox:$RT_DIG supervisor:$SUP_DIG; do
  n=${im%%:*} d=${im#*:}
  gh attestation verify "oci://ghcr.io/nvidia/openshell/$n@$d" --owner NVIDIA >/dev/null 2>"$ROOT/raw/att-oci-$n.err"; rc=$?
  echo "oci://ghcr.io/nvidia/openshell/$n@$d owner=NVIDIA exit=$rc" >>"$ROOT/p2/attestation-diag.txt"
  echo "exit=$rc first_error: $(grep -m1 -i error "$ROOT/raw/att-oci-$n.err")" >"$ROOT/p2/att-oci-nvidia_openshell_$n.txt"
  echo "INFO runtime image $n attestation exit=$rc (run 2 observed exit=1, 404: none published)"
done
logok=0
# run 3: `gh run view --log` returned nothing; the jobs API returned the log (job 134272530203, "Select Qualified Prerelease")
gh api --allow-escape-sequences repos/ai-openshell/openshell/actions/jobs/134272530203/logs >"$ROOT/p2/job-promote.log" 2>/dev/null
if grep -q "SOURCE_SHA: $TAG_SHA" "$ROOT/p2/job-promote.log" && grep -q 'refs/tags/v0.1.9' "$ROOT/p2/job-promote.log"; then logok=1; ok "promote job log SOURCE_SHA $TAG_SHA and refs/tags/v0.1.9 (jobs API)"; fi
[ "$logok" = 1 ] || for r in ai-openshell/openshell NVIDIA/OpenShell; do
  gh run view "$RUNID" -R "$r" --log 2>/dev/null | awk -F'\t' '$1 == "Select Qualified Prerelease"' >"$ROOT/p2/job-promote.log"
  if grep -q "SOURCE_SHA: $TAG_SHA" "$ROOT/p2/job-promote.log"; then logok=1; ok "promote job log SOURCE_SHA $TAG_SHA (via $r)"; break; fi
done
[ "$logok" = 1 ] || bad "promote job log SOURCE_SHA not found"
tar -xzf "$ROOT/dl/$CLI_TGZ" -C "$ROOT/bin/cli" --no-same-owner || bad "extract cli"
tar -xzf "$ROOT/dl/$GW_TGZ" -C "$ROOT/bin/gw" --no-same-owner || bad "extract gw"
for b in "cli/openshell:$CLI_SHA" "gw/openshell-gateway:$GW_SHA"; do
  p=$ROOT/bin/${b%%:*}
  [ -f "$p" ] && [ ! -L "$p" ] || { bad "missing $p (tar layout: $(tar -tzf "$ROOT/dl/$([ "${b%%/*}" = cli ] && echo "$CLI_TGZ" || echo "$GW_TGZ")" | tr '\n' ' '))"; continue; }
  chmod 0755 "$p"
  [ "$(sha256sum "$p" | cut -d' ' -f1)" = "${b##*:}" ] && ok "binary sha256 ${b%%:*}" || bad "binary sha256 ${b%%:*}"
done
ISO=(env -i "HOME=$ROOT/iso/home" "XDG_CONFIG_HOME=$ROOT/iso/cfg" "XDG_STATE_HOME=$ROOT/iso/state" "XDG_DATA_HOME=$ROOT/iso/data"
  "XDG_RUNTIME_DIR=$ROOT/iso/run" "OPENSHELL_SYSTEM_GATEWAY_DIR=$ROOT/iso/sysgw" PATH=/usr/bin:/bin TERM=dumb NO_COLOR=1)
cap() { local out=$1; shift; { timeout -k 5 30 "${ISO[@]}" "$@" 2>&1; echo "exit=$?"; } >"$ROOT/p2/$out.txt"; }
cap cli-version "$ROOT/bin/cli/openshell" --version
cap create-help "$ROOT/bin/cli/openshell" sandbox create --help
cap connect-help "$ROOT/bin/cli/openshell" sandbox connect --help
cap gateway-add-help "$ROOT/bin/cli/openshell" gateway add --help
cap gw-version "$ROOT/bin/gw/openshell-gateway" --version
cap gw-generate-certs-help "$ROOT/bin/gw/openshell-gateway" generate-certs --help
cap gw-config-help "$ROOT/bin/gw/openshell-gateway" config --help
for f in cli-version create-help connect-help gateway-add-help gw-version gw-generate-certs-help gw-config-help; do
  # committed copies have IPv4 addresses redacted: normalise both sides the same way before comparing
  ipn() { sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/IP_REDACTED/g' "$1"; }
  [ "$(ipn "$ROOT/p2/$f.txt")" = "$(ipn "$PREV/$f.txt")" ] && ok "p2 $f identical to run 3 (IPv4 normalised)" || { bad "p2 $f differs from run 3"; diff <(ipn "$PREV/$f.txt") <(ipn "$ROOT/p2/$f.txt") | head -20; }
done
grep -q -- 'Start the canonical main process without attaching to it' "$ROOT/p2/create-help.txt" &&
  grep -q -- '--no-keep' "$ROOT/p2/create-help.txt" && grep -q -- '--restart-policy' "$ROOT/p2/create-help.txt" &&
  grep -q -- '--tty' "$ROOT/p2/create-help.txt" && ok "create --help semantics (--detach/--tty/--no-keep/--restart-policy)" || bad "create --help semantics"
[ -z "$(ls -A "$ROOT/iso/cfg" "$ROOT/iso/state" "$ROOT/iso/data" "$ROOT/iso/sysgw" 2>/dev/null)" ] && ok "help/version calls wrote no isolated config/state" || echo "INFO help calls wrote: $(find "$ROOT/iso" -mindepth 2 | sed "s#$ROOT#<root>#" | tr '\n' ' ')"
# registry digests (anonymous token, never written to disk)
ACC='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
: >"$ROOT/p2/images.txt"
for spec in "nvidia/openshell/sandbox:0.1.9:$RT_DIG" "nvidia/openshell/supervisor:0.1.9:$SUP_DIG" "jlaska/herdrnetes-exec:$WL_DIG:$WL_DIG"; do
  IFS=: read -r name ref _ <<<"$spec"; want=${spec##*:}
  [ "$ref" = sha256 ] && ref=$WL_DIG
  tok=$(curl -fsS "https://ghcr.io/token?scope=repository:$name:pull" | jq -r .token); trc=$?
  hdr=$(curl -fsSI -H "Authorization: Bearer $tok" -H "Accept: $ACC" "https://ghcr.io/v2/$name/manifests/$ref"); crc=$?
  unset tok
  { echo "token_rc=$trc name=$name"; echo "== $name ref=$ref curl_exit=$crc"; grep -i -e '^HTTP' -e '^content-type' -e '^docker-content-digest' <<<"$hdr" | tr -d '\r'; } >>"$ROOT/p2/images.txt"
  got=$(grep -i '^docker-content-digest' <<<"$hdr" | tr -d '\r' | awk '{print $2}')
  [ "$got" = "sha256:${want#sha256:}" ] && ok "registry $name:$ref -> $got" || bad "registry $name:$ref -> '$got' want sha256:${want#sha256:}"
done
rm -rf "$ROOT/iso" "$ROOT/raw"
chmod 700 "$ROOT"
echo "## summary RUN=$RUN PORT=$PORT root=$ROOT fails=$FAILS"
ls -la "$ROOT" "$ROOT/bin/cli" "$ROOT/bin/gw" | sed "s#$HOME#~#g"
[ "$FAILS" = 0 ]
