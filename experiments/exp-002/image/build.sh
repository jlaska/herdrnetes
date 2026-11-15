#!/usr/bin/env bash
# Build one EXP-002 image variant with podman and record its identity.
#
#   build.sh <variant> [push]
#
# Variants differ in exactly one component so each GitOps change tests one
# thing (EXP-002 scenarios D/E/H). Release-asset SHA-256s were taken from
# GitHub's asset digests and match the binaries hashed locally in EXP-001.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${IMAGE_REPO:-ghcr.io/jlaska/herdrnetes-herdr}

CODEX_VERSION=0.169.0
CODEX_SHA256=9af4d751fce183faedea629437d5252dbf458eeb04130cf4f97be844621ea985

case "${1:?variant}" in
h095-c311) HERDR_VERSION=0.9.5 CLAUDE_VERSION=2.1.311 ;;
h094-c311) HERDR_VERSION=0.9.4 CLAUDE_VERSION=2.1.311 ;;
h080-c311) HERDR_VERSION=0.8.0 CLAUDE_VERSION=2.1.311 ;;
h095-c325) HERDR_VERSION=0.9.5 CLAUDE_VERSION=2.1.325 ;;
*) echo "unknown variant $1" >&2; exit 2 ;;
esac
case "$HERDR_VERSION" in
0.9.5) HERDR_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d ;;
0.9.4) HERDR_SHA256=493304fbefb0ed0ea0455f373b47f48d24e8774bc7974f4c916ad2e937675b23 ;;
0.8.0) HERDR_SHA256=b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28 ;;
esac

tag="$REPO:exp002-$1"
podman build --platform linux/amd64 \
  --build-arg "HERDR_VERSION=$HERDR_VERSION" --build-arg "HERDR_SHA256=$HERDR_SHA256" \
  --build-arg "CLAUDE_VERSION=$CLAUDE_VERSION" \
  --build-arg "CODEX_VERSION=$CODEX_VERSION" --build-arg "CODEX_SHA256=$CODEX_SHA256" \
  -t "$tag" -f "$HERE/Containerfile" "$HERE"

out="$HERE/../evidence/images"
mkdir -p "$out"
podman run --rm --entrypoint cat "$tag" /usr/share/herdrnetes/manifest.txt >"$out/$1.manifest.txt"
if [ "${2:-}" = push ]; then
  podman push --digestfile "$out/$1.digest" "$tag"
  echo "$tag@$(cat "$out/$1.digest")"
else
  podman image inspect --format '{{.Id}}' "$tag" >"$out/$1.image-id"
  echo "$tag (local id $(cat "$out/$1.image-id"))"
fi
