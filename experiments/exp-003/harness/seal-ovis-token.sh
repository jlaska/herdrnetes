#!/usr/bin/env bash
# Generate a random Ovis login token, seal it for the experiment namespace and keep the
# plaintext only in an owner-only file outside this repository, so you can paste it into
# Ovis's login page. Nothing is printed or written to the repo in clear text.
# Run this yourself in a terminal; do not run it from an agent session.
#
#   seal-ovis-token.sh <sealed-secrets-cert.pem> <output.sealed.yaml> [plaintext-file]
#
# plaintext-file defaults to ~/.local/share/exp003/ovis-token (mode 0600). An existing file is
# not overwritten (it may be the token of a Secret already in the cluster): move it away first.
# Rotating = new token, new SealedSecret, then restart the Ovis container (or the pod).
set -euo pipefail
cert=${1:?sealed-secrets public cert} out=${2:?output file}
plain=${3:-${XDG_DATA_HOME:-$HOME/.local/share}/exp003/ovis-token}

repo=$(cd "$(dirname "$0")/../../.." && pwd -P)
mkdir -p "$(dirname "$plain")" && chmod 700 "$(dirname "$plain")"
plain=$(cd "$(dirname "$plain")" && pwd -P)/$(basename "$plain")
case "$plain" in "$repo"/*) echo "refusing to write the plaintext token inside the repository ($plain)" >&2; exit 1 ;; esac
[ ! -e "$plain" ] || { echo "$plain already exists; move it away to generate a new token" >&2; exit 1; }
[ -r "$cert" ] || { echo "cannot read $cert" >&2; exit 1; }

umask 077
# 32 random bytes, base64url without padding (43 characters).
token=$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')
[ "${#token}" -ge 40 ] || { echo "token generation failed" >&2; exit 1; }
printf '%s' "$token" |
  kubectl create secret generic herdr-ovis-token -n herdrnetes-exp \
    --from-file=OVIS_TOKEN=/dev/stdin --dry-run=client -o yaml |
  kubeseal --cert "$cert" --format yaml >"$out.tmp"
mv "$out.tmp" "$out"
printf '%s\n' "$token" >"$plain"
chmod 600 "$plain"
unset token
echo "wrote $out ($(wc -c <"$out") bytes, encrypted for namespace herdrnetes-exp)"
echo "plaintext token (mode 0600, outside the repo): $plain"
