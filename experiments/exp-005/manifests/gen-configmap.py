#!/usr/bin/env python3
"""Emit the request-repo ConfigMap (JSON, which is valid YAML) to stdout.
usage: gen-configmap.py <run-id> [configmap-name]   (default name request-repo; reads ../harness/request-repo)"""
import json, os, sys
run_id = sys.argv[1]
cm_name = sys.argv[2] if len(sys.argv) > 2 else "request-repo"
here = os.path.dirname(os.path.abspath(__file__))
body = open(os.path.join(here, "..", "harness", "request-repo")).read()
print(json.dumps({"apiVersion": "v1", "kind": "ConfigMap",
    "metadata": {"name": cm_name, "namespace": "herdrnetes-exp005", "labels": {
        "herdrnetes.io/experiment": "exp-005", "herdrnetes.io/run-id": run_id,
        "herdrnetes.io/component": "request-repo", "herdrnetes.io/disposable": "true"}},
    "data": {"request-repo": body}}, indent=1))
