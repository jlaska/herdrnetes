# shellcheck shell=bash
# EXP-008 Stage C4: sourced by stagec4.sh. Builds the fixed `sandbox create` options (CREATE) and the
# bootstrap argv (LAUNCH) for M1, as ../stage-c/launcher.sh does for C0-C3 (unchanged there).
#
# Differences from C0-C3 (and nothing else):
#   - the package carries the C4 launcher and step.sh (task/launch.sh, task/step.sh in this directory); the
#     prompt and settings are the C0-C3 files, byte-identical (../stage-c/task/prompt.txt, settings.json);
#   - the bootstrap is the C0-C3 bootstrap (BOOT below is asserted equal by tests/launch4-test.sh). It runs
#     again on `sandbox start`, rewrites pkg.tar/pkg.sha256/pkg/ with the same verified content, and execs the
#     state-aware launcher, which then selects Resume.
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
BOOT='set -eu; umask 077; mkdir -p /sandbox/c/pkg; printf %s "$0" | base64 -d >/sandbox/c/pkg.tar; printf "%s  /sandbox/c/pkg.tar\n" "$1" | sha256sum -c --status; printf %s "$1" >/sandbox/c/pkg.sha256; tar -xf /sandbox/c/pkg.tar -C /sandbox/c/pkg; exec /bin/sh /sandbox/c/pkg/launch.sh'
create_args() {
  pkg_build "$L/pkg.tar"
  PKG_SHA=$(sha256sum "$L/pkg.tar" | cut -d' ' -f1)
  echo "pkg_sha256=$PKG_SHA pkg_bytes=$(stat -c %s "$L/pkg.tar")" >"$E/obs/c0-pkg.txt"
  CREATE=(--from "$IMG" --provider "$PROV" --detach --tty --restart-policy never --no-auto-providers --label "exp008.run=$RUN" --label "exp008.stage=c4")
  LAUNCH=(/bin/sh -c "$BOOT" "$(base64 -w0 "$L/pkg.tar")" "$PKG_SHA")
}
