#!/usr/bin/env bash
# Offline proof that the overlay only adds the Ovis container and its volumes.
# Prints the full diff of `kustomize build` output (base vs overlay), and fails if the
# herdr container spec, any other resource, or the StatefulSet outside containers/volumes changed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
kustomize build "$HERE/../../exp-002/deploy/base" >"$tmp/base.yaml"
kustomize build "$HERE" >"$tmp/overlay.yaml"
diff -u "$tmp/base.yaml" "$tmp/overlay.yaml" || true
uv run --quiet --with pyyaml python -I - "$tmp/base.yaml" "$tmp/overlay.yaml" <<'PY'
import sys, copy, json, yaml
def load(p):
    return [d for d in yaml.safe_load_all(open(p)) if d]
b, o = load(sys.argv[1]), load(sys.argv[2])
key = lambda r: (r["kind"], r["metadata"]["name"])
bm, om = {key(r): r for r in b}, {key(r): r for r in o}
assert bm.keys() == om.keys(), ("resource set changed", set(bm) ^ set(om))
bad = [k for k in bm if k != ("StatefulSet", "herdr") and bm[k] != om[k]]
assert not bad, ("other resources changed", bad)
bs, os_ = bm[("StatefulSet", "herdr")], copy.deepcopy(om[("StatefulSet", "herdr")])
ps = os_["spec"]["template"]["spec"]
ovis = [c for c in ps["containers"] if c["name"] == "ovis"]; assert len(ovis) == 1
assert ps["containers"][0]["name"] == "herdr", "herdr must stay the first (default) container"
ps["containers"] = [c for c in ps["containers"] if c["name"] != "ovis"]
ps["volumes"] = [v for v in ps["volumes"] if v["name"] not in ("ovis-state", "ovis-tmp")]
assert bs == os_, "StatefulSet differs outside the ovis container and its volumes"
h_b = [c for c in bs["spec"]["template"]["spec"]["containers"] if c["name"] == "herdr"][0]
h_o = [c for c in om[("StatefulSet", "herdr")]["spec"]["template"]["spec"]["containers"] if c["name"] == "herdr"][0]
assert json.dumps(h_b, sort_keys=True) == json.dumps(h_o, sort_keys=True)
print("OK: herdr container byte-identical (canonical JSON); only container 'ovis' and volumes ovis-state/ovis-tmp added")
PY
