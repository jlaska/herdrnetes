# shellcheck shell=bash
# EXP-008 Stage C4: sourced by stagec4.sh. Builds the fixed `sandbox create` options (CREATE) and the
# bootstrap argv (LAUNCH) for M1, as ../stage-c/launcher.sh does for C0-C3 (unchanged there).
#
# Differences from C0-C3 (and nothing else):
#   - the package carries the C4 launcher and step.sh (task/launch.sh, task/step.sh in this directory); the
#     prompt and settings are the C0-C3 files, byte-identical (../stage-c/task/prompt.txt, settings.json);
#   - the bootstrap is the C0-C3 bootstrap with ONE change, the transport (corrective PR after run 1127-1814,
#     where OpenShell v0.1.9 refused the 40,960-byte inline element: "spec.command[3] exceeds 32768 byte limit").
#     The deterministic tar is gzip-compressed (-n: no name, no timestamp) before base64. The bootstrap decodes,
#     decompresses, verifies the sha256 of the ORIGINAL tar, and only then extracts and execs the launcher. Every
#     other byte is the C0-C3 bootstrap (tests/launch4-test.sh asserts the exact delta). It runs again on
#     `sandbox start`, rewrites pkg.tar.gz/pkg.tar/pkg.sha256/pkg/ with the same verified content, and execs the
#     state-aware launcher, which then selects Resume. The pinned image provides gzip 1.13, GNU tar 1.35,
#     coreutils 9.7 (base64, sha256sum) and dash as /bin/sh (static layer inspection; README section 4, item 18).
#   - before any create request, launch_check verifies the argv shape, every element against OpenShell's
#     32,768-byte per-element limit, the encoded payload against the 24,576-byte experimental budget, that the
#     payload decodes to the original tar, and that an independent rebuild gives identical tar and gzip bytes.
#   - CREATE never contains --no-keep (the only CLI option that marks a sandbox ephemeral, so that the gateway
#     auto-deletes it after a failed main process; OpenShell v0.1.9 run.rs:672-677, compute/mod.rs:6267-6290).
C4TASK=$HERE/task
C0TASK=$HERE/../stage-c/task
pkg_build() { # pkg_build <out.tar>
  local t; t=$(mktemp -d)
  cp "$C4TASK/launch.sh" "$C4TASK/step.sh" "$C0TASK/prompt.txt" "$C0TASK/settings.json" "$t/"
  chmod 0644 "$t"/*; chmod 0755 "$t/launch.sh" "$t/step.sh"
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$t" -cf "$1" launch.sh prompt.txt settings.json step.sh
  rm -rf "$t"
}
PAYLOAD_BUDGET=24576 # encoded package element budget (owner, 2026-11-27)
ARG_ELEM_MAX=32768   # OpenShell v0.1.9 per-element limit on the sandbox command (observed, run 1127-1814)
pkg_gz() { gzip -9 -n -c <"$1" >"$2"; } # pkg_gz <tar> <out.gz>: deterministic (no name, no mtime)
BOOT='set -eu; umask 077; mkdir -p /sandbox/c/pkg; printf %s "$0" | base64 -d >/sandbox/c/pkg.tar.gz; gzip -dc /sandbox/c/pkg.tar.gz >/sandbox/c/pkg.tar; printf "%s  /sandbox/c/pkg.tar\n" "$1" | sha256sum -c --status; printf %s "$1" >/sandbox/c/pkg.sha256; tar -xf /sandbox/c/pkg.tar -C /sandbox/c/pkg; exec /bin/sh /sandbox/c/pkg/launch.sh'
create_args() {
  pkg_build "$L/pkg.tar"
  PKG_SHA=$(sha256sum "$L/pkg.tar" | cut -d' ' -f1)
  pkg_gz "$L/pkg.tar" "$L/pkg.tar.gz"
  local b64; b64=$(base64 -w0 "$L/pkg.tar.gz")
  echo "pkg_sha256=$PKG_SHA pkg_bytes=$(stat -c %s "$L/pkg.tar") gz_sha256=$(sha256sum "$L/pkg.tar.gz" | cut -d' ' -f1) gz_bytes=$(stat -c %s "$L/pkg.tar.gz") payload_bytes=$(printf %s "$b64" | LC_ALL=C wc -c)" >"$E/obs/c0-pkg.txt"
  CREATE=(--from "$IMG" --provider "$PROV" --detach --tty --restart-policy never --no-auto-providers --label "exp008.run=$RUN" --label "exp008.stage=c4")
  LAUNCH=(/bin/sh -c "$BOOT" "$b64" "$PKG_SHA")
}
nbytes() { printf %s "$1" | LC_ALL=C wc -c; }
launch_check() { # launch_check <out>: local, before any create request. Records sizes, hashes and pass/fail only.
  local out=$1 x b max=0 sizes="" pb dec over=0 det=no why=() d
  [ "${#LAUNCH[@]}" = 5 ] || why+=(argc)
  [ "${LAUNCH[0]:-}" = /bin/sh ] && [ "${LAUNCH[1]:-}" = -c ] && [ "${LAUNCH[2]:-}" = "$BOOT" ] || why+=(shape)
  [[ ${LAUNCH[3]:-} =~ ^[A-Za-z0-9+/]+=*$ ]] || why+=(payload-not-base64)
  [[ ${LAUNCH[4]:-} =~ ^[0-9a-f]{64}$ ]] && [ "${LAUNCH[4]}" = "${PKG_SHA:-}" ] || why+=(sha-element)
  for x in "${CREATE[@]}" "${LAUNCH[@]}"; do b=$(nbytes "$x"); [ "$b" -gt "$max" ] && max=$b; [ "$b" -le "$ARG_ELEM_MAX" ] || over=1; done
  [ "$over" = 0 ] || why+=(element-over-limit)
  for x in "${LAUNCH[@]}"; do sizes="$sizes${sizes:+,}$(nbytes "$x")"; done
  pb=$(nbytes "${LAUNCH[3]:-}"); [ "$pb" -le "$PAYLOAD_BUDGET" ] || why+=(payload-over-budget)
  dec=$(printf %s "${LAUNCH[3]:-}" | base64 -d 2>/dev/null | gzip -dc 2>/dev/null | sha256sum | cut -d' ' -f1)
  [ "$dec" = "${PKG_SHA:-}" ] || why+=(payload-does-not-decode-to-pkg)
  d=$(mktemp -d "$L/rebuild.XXXXXX") && pkg_build "$d/p.tar" && pkg_gz "$d/p.tar" "$d/p.tar.gz" \
    && [ "$(sha256sum <"$d/p.tar" | cut -d' ' -f1)" = "${PKG_SHA:-}" ] && [ "$(base64 -w0 "$d/p.tar.gz")" = "${LAUNCH[3]:-}" ] && det=yes
  [ -n "${d:-}" ] && rm -rf "$d"; [ "$det" = yes ] || why+=(not-deterministic)
  echo "launch_check=$([ "${#why[@]}" = 0 ] && echo pass || echo fail) argc=${#LAUNCH[@]} launch_elem_bytes=$sizes max_elem_bytes=$max elem_limit=$ARG_ELEM_MAX payload_bytes=$pb payload_budget=$PAYLOAD_BUDGET decodes_to_pkg_sha256=$([ "$dec" = "${PKG_SHA:-}" ] && echo yes || echo no) deterministic=$det reasons=$(IFS=,; echo "${why[*]:-none}")" >"$out"
  [ "${#why[@]}" = 0 ]
}
