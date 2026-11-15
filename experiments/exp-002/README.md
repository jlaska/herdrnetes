# EXP-002 harness: trusted Herdr on Kubernetes

Experimental, reversible deployment of one trusted Herdr server. This is not a production deployment. Results go in
[`RESULTS.md`](RESULTS.md); findings go in [`docs/experiments/02-kubernetes-deployment.md`](../../docs/experiments/02-kubernetes-deployment.md).

| Path | Purpose |
| --- | --- |
| `image/Containerfile`, `image/build.sh` | Immutable image with pinned Herdr, Claude Code and Codex. `build.sh <variant> [push]` |
| `image/entrypoint.sh` | Prepares the home volume, reconciles integration hooks, and starts `herdr server` with an allowlisted environment |
| `image/smoke.sh` | Local podman test under pod-like constraints (non-root, read-only rootfs, no capabilities) |
| `deploy/base/` | Cluster-agnostic kustomize base: Namespace (PSA `restricted`), ServiceAccount (no token), NetworkPolicy, StatefulSet + 2 PVCs, ConfigMap |
| `harness/scenario.sh` | Drives the pod with `kubectl exec` from a workstation, outside the pod it disrupts |
| `evidence/` | Committed, redacted evidence only (image manifests, digests, timings) |

## Image variants

Each variant changes one component relative to the baseline `h095-c311`.

| Variant | Herdr | Claude Code | Codex |
| --- | --- | --- | --- |
| `h095-c311` | 0.9.5 | 2.1.311 | 0.169.0 |
| `h094-c311` | 0.9.4 | 2.1.311 | 0.169.0 |
| `h080-c311` | 0.8.0 | 2.1.311 | 0.169.0 |
| `h095-c325` | 0.9.5 | 2.1.325 | 0.169.0 |

## Deploy (GitOps)

The GitOps repository is private. Its convention is `clusters/base/apps/<app>/` plus
`clusters/overlays/<cluster>/apps/<app>/`, picked up by a matrix ApplicationSet as `<cluster>-<app>`.
Commits must be GPG-signed by the owner.

1. Copy `deploy/base/` into the GitOps repo as `clusters/base/apps/herdrnetes-exp/`.
2. Add an overlay `clusters/overlays/<cluster>/apps/herdrnetes-exp/kustomization.yaml`:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../../../../base/apps/herdrnetes-exp
   images:
     - name: herdrnetes-herdr
       newName: ghcr.io/jlaska/herdrnetes-herdr
       digest: sha256:<digest from evidence/images/<variant>.digest>
   ```

3. Commit with a signature and push. Argo CD creates `<cluster>-herdrnetes-exp`.
4. Image upgrade or rollback (scenarios D/E) means changing only `digest:` in the overlay, then committing and pushing.

## Remove

1. Remove the overlay directory, then commit and push. The ApplicationSet uses `preserveResourcesOnDeletion`, so the
   namespace may remain.
2. Delete the namespace explicitly: `kubectl delete namespace herdrnetes-exp`. StatefulSet PVCs use
   `whenDeleted: Retain`. They are deleted with the namespace, which **destroys Herdr state and workspaces**.
   Export anything you want to keep first (`scenario.sh backup`).

## Run scenarios

```bash
export CTX=<kube-context> EXP_EVIDENCE=$HOME/.local/share/exp002   # raw evidence stays private
H=experiments/exp-002/harness/scenario.sh
bash $H setup r1                 # 2 repos, 3 workspaces, 6 panes, labels, cd, env var, sleep, background server
bash $H agent r1 haiku           # needs Claude credentials in the pod (owner login)
bash $H disrupt r1 delete        # B: graceful pod replacement; also grace1 | force | kill | oom | external
bash $H ask r1 after-delete      # codeword recall
uv run --script experiments/exp-001/compare.py diff $EXP_EVIDENCE/r1/baseline $EXP_EVIDENCE/r1/after-delete
```

Raw evidence (pane screens, `session.json`, Herdr logs, state backups) can contain conversation text and session IDs.
Keep it outside the repository and commit only redacted summaries.
