#!/usr/bin/env bash
# Build the EXP-003 Ovis sidecar image locally with podman and record its identity.
#
#   build.sh            # local build only; there is deliberately no push mode here
#
# Release-asset SHA-256s are those of Ovis v0.5.4 (commit b9d079808f0b0565fa9c380237d92f81d1164e0d),
# taken from the signed ovis-server.json and cross-checked against GitHub's asset digests.
# The Containerfile re-verifies them and the manifest's Ed25519 signature at build time.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${IMAGE_REPO:-ghcr.io/jlaska/herdrnetes-ovis}

OVIS_VERSION=0.5.4
OVIS_PUBKEY='C8+dOD0gpFHoy008ZqHO89vXutaLqlt5uWyIh250OiY=' # RELEASE_PUBLIC_KEY, scripts/server-manifest.ts
OVIS_MANIFEST_SHA256=e28a43b3cde31d91383fb6799dc401cc760a070332f2a921cba65bcf5cb42156
OVIS_SERVER_SHA256=12178c9a5511df7f01de92cc84bec35f416afa22c7f5873731cb67b1fb955a19   # ovis-server-linux-x64
OVIS_DIST_SHA256=a1fa10be4a2ce8a98f7e762d1bcaa6f725e607975c484e8f232debab15f7d752     # ovis-dist.tar.gz
OVIS_PTY_SHA256=044eb0dca08d844a9564d9a5f23129d538b755fd6fd4747f7966494d46676bd2      # ovis-pty-sidecar-linux-x64

name=o054-h095
tag="$REPO:exp003-$name"
podman build --platform linux/amd64 \
  --build-arg "OVIS_VERSION=$OVIS_VERSION" --build-arg "OVIS_PUBKEY=$OVIS_PUBKEY" \
  --build-arg "OVIS_MANIFEST_SHA256=$OVIS_MANIFEST_SHA256" --build-arg "OVIS_SERVER_SHA256=$OVIS_SERVER_SHA256" \
  --build-arg "OVIS_DIST_SHA256=$OVIS_DIST_SHA256" --build-arg "OVIS_PTY_SHA256=$OVIS_PTY_SHA256" \
  -t "$tag" -f "$HERE/Containerfile" "$HERE"

out="$HERE/../evidence/images"
mkdir -p "$out"
podman run --rm --entrypoint sh "$tag" -c 'cat /usr/share/herdrnetes/ovis-manifest.txt; echo "--- herdr image manifest"; cat /usr/share/herdrnetes/manifest.txt' >"$out/$name.manifest.txt"
podman image inspect --format '{{.Id}}' "$tag" >"$out/$name.image-id"
echo "$tag (local id $(cat "$out/$name.image-id"); not pushed)"
