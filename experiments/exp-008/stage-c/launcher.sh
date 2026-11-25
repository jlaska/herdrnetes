# shellcheck shell=bash
# EXP-008 Stage C: sourced by stagec.sh. Builds the fixed `sandbox create` options (CREATE) and the
# bootstrap argv (LAUNCH) for M1. No credential is involved: the provider is attached by NAME and the
# sandbox sees only OpenShell's placeholder.
#
# OpenShell v0.1.9 execs the argv after `--` directly (no shell), with cwd /sandbox, and `--upload`
# cannot be combined with a command (crates/openshell-cli/src/main.rs:1486; run.rs:541-545). The task
# files therefore travel inside the argv: a deterministic tar of task/{launch.sh,step.sh,prompt.txt,
# settings.json}, base64-encoded, whose sha256 the bootstrap verifies before extracting. The package
# sha256 is recorded in evidence; its contents are in this repository.
pkg_build() { # pkg_build <out.tar>
  local t; t=$(mktemp -d)
  cp "$HERE/task/launch.sh" "$HERE/task/step.sh" "$HERE/task/prompt.txt" "$HERE/task/settings.json" "$t/"
  chmod 0644 "$t"/*; chmod 0755 "$t/launch.sh" "$t/step.sh"
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$t" -cf "$1" launch.sh prompt.txt settings.json step.sh
  rm -rf "$t"
}
BOOT='set -eu; umask 077; mkdir -p /sandbox/c/pkg; printf %s "$0" | base64 -d >/sandbox/c/pkg.tar; printf "%s  /sandbox/c/pkg.tar\n" "$1" | sha256sum -c --status; printf %s "$1" >/sandbox/c/pkg.sha256; tar -xf /sandbox/c/pkg.tar -C /sandbox/c/pkg; exec /bin/sh /sandbox/c/pkg/launch.sh'
create_args() {
  pkg_build "$L/pkg.tar"
  PKG_SHA=$(sha256sum "$L/pkg.tar" | cut -d' ' -f1)
  echo "pkg_sha256=$PKG_SHA pkg_bytes=$(stat -c %s "$L/pkg.tar")" >"$E/obs/c0-pkg.txt"
  CREATE=(--from "$IMG" --provider "$PROV" --detach --tty --restart-policy never --no-auto-providers --label "exp008.run=$RUN")
  LAUNCH=(/bin/sh -c "$BOOT" "$(base64 -w0 "$L/pkg.tar")" "$PKG_SHA")
}
