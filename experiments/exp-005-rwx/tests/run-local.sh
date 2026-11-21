#!/usr/bin/env bash
# Run the EXP-005-RWX local tests (no cluster, no kubectl contact). Needs uv (PyYAML is supplied ephemerally).
# Optional: also run inside the pinned image under Podman when IN_IMAGE=1 (read-only rootfs, uid 1000, caps dropped).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${IMAGE:-ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277}
rc=0
uv run --with pyyaml python -m unittest discover -s "$here/tests" -p 'test_*.py' "$@" || rc=1
if [ "${IN_IMAGE:-0}" = 1 ] && command -v podman >/dev/null; then
  # PyYAML is not in the image: only the stdlib-only suites run there.
  podman run --rm --read-only --user 1000 --cap-drop=ALL --security-opt no-new-privileges --entrypoint python3 \
    -v "$here":/opt/exp005rwx:ro,Z --tmpfs /tmp --env HOME=/tmp -w /tmp "$IMAGE" -m unittest -v \
    discover -s /opt/exp005rwx/tests -p 'test_podprobe.py' || rc=1
fi
exit $rc
