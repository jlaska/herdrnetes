#!/usr/bin/env bash
# Run the request-repo tests on the host and inside the pinned image (podman, read-only rootfs).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${IMAGE:-ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277}
declare -A res
run() { # name cmd...
  local name=$1; shift
  if "$@" >"${TMPDIR:-/tmp}/exp005-$name.log" 2>&1; then res[$name]=PASS; else res[$name]=FAIL; fi
  tail -4 "${TMPDIR:-/tmp}/exp005-$name.log"
}
if command -v uv >/dev/null; then py=(uv run python); else py=(python3); fi
run host "${py[@]}" -m unittest discover -s "$here/tests" -p 'test_*.py'
if command -v podman >/dev/null; then
  run image podman run --rm --read-only --user 1000 --cap-drop=ALL --security-opt no-new-privileges \
    --entrypoint python3 -v "$here":/opt/exp005:ro,Z --tmpfs /tmp --tmpfs /workspace:rw,mode=1777 \
    -w /tmp "$IMAGE" -m unittest discover -s /opt/exp005/tests -p 'test_*.py'
else
  res[image]=SKIP
fi
echo "== summary =="; rc=0
for k in host image; do echo "$k: ${res[$k]}"; [ "${res[$k]}" = FAIL ] && rc=1; done
exit $rc
