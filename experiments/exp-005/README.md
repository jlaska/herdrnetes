# EXP-005 harness: repository lifecycle and lazy PVC provisioning

Proofs of concept for [REQ-004](../../docs/requirements.md) (shared workspace PVC, separate home) and
[REQ-010](../../docs/requirements.md) (future lazy per-repository PVCs without restarting Herdr).
Plan: [`docs/experiments/05-repository-storage.md`](../../docs/experiments/05-repository-storage.md).
Results go in [`RESULTS.md`](RESULTS.md). Tracking: issue #6.

The central distinction: **Kubernetes provisioning and mounting a PVC somewhere** is not the same as
**an already-running Herdr process being able to read that filesystem**. Every test below records
which of the two it shows.

## Baseline (observed 2026-11-18, read-only audit)

| Item | Value |
| --- | --- |
| Kubernetes | server v1.36.6, 3 schedulable nodes, no taints |
| Longhorn | v1.13.0 (v1 data engine), CSI attach required |
| StorageClass used | `longhorn` (default): RWO, `Immediate` binding, 3 replicas, `dataLocality=disabled`, ext4, reclaim `Delete` |
| Other classes (not used unless noted) | 2 × unreplicated `WaitForFirstConsumer` Longhorn classes; one `nfs.csi.k8s.io` class backed by an external NAS (reclaim `Retain`) |
| Longhorn RWX class | none |
| VolumeSnapshotClass | none defined |
| Live Herdr (untouched) | StatefulSet `herdr`, namespace `herdrnetes-exp` (PSA `restricted`), home PVC 5Gi + workspace PVC 20Gi, both `longhorn` RWO |
| Pinned image | `ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277` (`exp002-h095-c311`, Herdr 0.9.5) — matches the live pod's imageID |
| Image tools | Debian 13, uid 1000, git **2.47.3**, util-linux flock 2.41.5, python3 3.13.5, bash; no jq |
| Pod security (live, mirrored in scratch) | runAsNonRoot uid/gid 1000, fsGroup 1000, seccomp RuntimeDefault, drop ALL, no privilege escalation, read-only rootfs, no SA token |

git 2.47.3 predates `worktree.useRelativePaths` (2.48), so worktrees created inside the image record
absolute paths. Stable absolute paths are therefore a hard requirement, not a preference.

## Hypotheses

| ID | Hypothesis | Milestone | Falsified by |
| --- | --- | --- | --- |
| H1 | A repository can be lazily hydrated into the shared workspace PVC at a stable path (`/workspace/<id>`) from inside a running Herdr-equivalent pod, with no pod restart | M1 | restart required, or repo not usable at the path |
| H2 | Clone-to-staging on the same filesystem + `renameat2(RENAME_NOREPLACE)` + per-repo `flock` gives idempotent, concurrency-safe hydration that never exposes partial state as ready | M1/M4 | corrupt/duplicate repo, partial dir at the stable path, or state=ready for an unusable repo |
| H3 | `request-repo` never modifies an existing repository (dirty and untracked files preserved) | M1 | any change to worktree, index or refs of an existing repo |
| H4 | A pod's volume set cannot be changed after creation; a PVC created later never appears in a running pod's mount table | M2 | API accepts a volume patch, or mountinfo changes |
| H5 | A per-repo Longhorn PVC can be created, bound and mounted by an independent workspace pod, and its data survives pod replacement | M2 | bind/mount failure or data loss |
| H6 | A running Herdr-equivalent pod cannot read a per-repo PVC mounted only in another pod (no shared filesystem namespace), without privileged/host mounts | M2/M3 | the Herdr pod reads the files via its own filesystem |
| H7 | Two pods on **different** nodes cannot both use one Longhorn RWO volume (Multi-Attach); two pods on the **same** node can, and `flock` excludes across them | M4 | either behaviour differs |
| H8 | An unavailable per-repo volume affects only workloads that mount it | M4 | unrelated workspace or Herdr pod disrupted |

## Test matrix

Status values: PASS, FAIL, LIMITATION, BLOCKED, UNTESTED. Recovery: fully restored / recoverable
with manual action / lost. Nothing is marked PASS from documentation alone.

### M1 — shared PVC lazy hydration (scratch Herdr-equivalent pod)

| Test | Check |
| --- | --- |
| S01 | Repo absent before request |
| S02 | First request hydrates; `git fsck` clean; HEAD matches source |
| S03 | Repo at stable absolute path `/workspace/<id>` |
| S04 | Pod UID, container restartCount and Herdr server PID unchanged across S01–S10 |
| S05 | Repeated request is a no-op (`already_ready`, inode and mtime of `.git` unchanged) |
| S06 | Two repos hydrate independently |
| S07 | N concurrent requests for one repo: exactly one clone, all callers get ready, fsck clean |
| S08 | Failed clone (bad source): non-zero exit, nothing at stable path, state=failed, retry with good source succeeds |
| S09 | Clone killed (SIGKILL) mid-hydration: nothing at stable path; next request cleans staging and succeeds |
| S10 | Dirty + untracked files and a local commit preserved across re-request |
| S11 | Repo usable and identical after scratch pod delete/recreate (same PVC) |
| S12 | Home and workspace on separate PVCs; no repo/state data written to home |
| S13 | `git worktree add` inside the repo: record absolute gitdir paths (git 2.47.3) |

### M2 — per-repository Longhorn PVC + independent workspace pod

| Test | Check |
| --- | --- |
| P01 | Repo PVC absent initially |
| P02–P03 | Request creates the PVC; bind time recorded (`Immediate`) |
| P04–P05 | Workspace pod mounts it; repo hydrated with the M1 tool; attach/mount time recorded |
| P06–P07 | Workspace pod replaced: data, dirty and untracked changes survive |
| P08–P09 | Second repo gets its own PVC; each can be deleted/replaced independently |
| P10 | Scratch Herdr pod UID/restartCount unchanged throughout |
| P11 | Accessibility from the Herdr pod's filesystem: `ls`/`mountinfo` in the Herdr pod, plus an attempted volume patch (H4) and ephemeral container referencing a new claim |
| P12 | RWO constraints: same-node second pod vs different-node second pod (H7), events recorded; no VolumeAttachment manipulation |

### M3 — workspace indirection (analysis; small PoC only if it settles an open question)

Shared PVC · per-repo PVCs · hydrate/sync into shared PVC · remote workspace pod (exec) · NFS/RWX
namespace (comparison only — **no NFS deployment and no PVCs on the existing NFS class** without owner approval).

### M4 — failure and recovery

First/repeated/concurrent hydration, failed/interrupted clone, dirty worktree, multiple worktrees,
workspace-pod deletion, workload restart, RWO attachment conflict, unavailable repo volume (H8),
home/workspace separation. Most rows reuse M1/M2 runs; the remainder run as targeted tests.

## Safeguards

- Context is always passed explicitly (`--context <owner-designated>`); the default context is never changed.
- Namespace **`herdrnetes-exp005`** only. The live Herdr namespace `herdrnetes-exp` is never a target;
  tooling compares names exactly, never by prefix.
- Every resource carries:
  `herdrnetes.io/experiment=exp-005`, `herdrnetes.io/run-id=<run>`, `herdrnetes.io/component=<c>`,
  `herdrnetes.io/disposable=true`.
- Standalone manifests; `experiments/exp-002/deploy/base` is **not** reused because it declares the live namespace.
- No privileged pods, hostPath, cluster-scoped objects other than the scratch Namespace, RBAC, or in-cluster API credentials.
  The harness runs from the workstation via `kubectl`.
- 1Gi PVCs. No Longhorn/StorageClass changes, no VolumeAttachment edits, no force-detach.
- Synthetic Git repositories only; no credentials.
- Cleanup (`harness/cleanup.sh`) inventories by label, verifies namespace + run ID, prints a dry run,
  refuses unlabeled objects, requires `--confirm <run-id>`, saves evidence first, and verifies the live
  Herdr pod UID/restartCount before and after.
- Commits on the exp-005 branch are unsigned by owner decision (issue #29); no owner key is used.

## Layout

| Path | Purpose |
| --- | --- |
| `harness/request-repo` | M1 hydration tool (python3 stdlib, runs inside the pinned image) |
| `harness/` | workstation-side drivers (`kubectl exec`), cleanup |
| `manifests/` | scratch Namespace, Herdr-equivalent StatefulSet, workspace pod, PVC templates |
| `tests/` | local (no cluster) unit tests and cluster test scenarios |
| `evidence/` | committed, sanitized evidence only |
