# EXP-005: Repository lifecycle and PVC provisioning

**Status:** Milestones 1–4 executed in a disposable scratch namespace (`herdrnetes-exp005`) on the owner-designated
cluster on 2026-11-18/19 (runs `m1-20261118a`, `m2-20261118a`, `m4-20261118a`). The live Herdr StatefulSet, its PVCs,
GitOps, Longhorn and StorageClasses were not changed. The live pod's UID and restart counts were identical before and
after every run. All scratch resources were removed with the guarded cleanup. NFS/RWX was compared on paper only.
**Owner decision (2026-11-19):** the recommendation in §5 is accepted as an experiment finding for the trusted MVP
([review](https://github.com/jlaska/herdrnetes/pull/30#pullrequestreview-5978272077),
[decisions](https://github.com/jlaska/herdrnetes/issues/6#issuecomment-7014093054)). It is not a new architecture
decision and not approval to install `request-repo` in live Herdr. **ADR-0001 is unchanged**: it already chooses one
shared workspace PVC and defers per-repository volumes. Tracking issue:
[#6](https://github.com/jlaska/herdrnetes/issues/6). Harness, results and sanitized evidence:
[`experiments/exp-005/`](../../experiments/exp-005/README.md), [`RESULTS.md`](../../experiments/exp-005/RESULTS.md).

Explore lazy per-repository provisioning/hydration without restarting the unified Herdr pod. Compare shared NFS
namespaces, Kubernetes PVC mounting constraints, and separate workspace pods/indirection. Record tradeoffs in isolation,
Git worktree behavior, backup, and failure recovery. The initial shared PVC remains the MVP baseline.

**Requirements:** REQ-004, REQ-010 (also REQ-009, REQ-011 for hand-offs). **Findings:** FIND-058–FIND-065.

Evidence tags used below: **[cluster]** observed in the scratch namespace; **[local]** observed on the workstation or in
the pinned image under Podman; **[docs]** established by documentation or Kubernetes source; **[inferred]** not tested.

## 1. Baseline (read-only audit, 2026-11-18)

Kubernetes v1.36.6, 3 schedulable nodes. Longhorn v1.13.0, default `longhorn` StorageClass: RWO, `Immediate`,
3 replicas, ext4, reclaim `Delete`. No RWX volume in use and no VolumeSnapshotClass. (Longhorn selects RWX from the
PVC access mode, so the existing class may serve RWX claims; that was not tested here and is #32.) One existing `nfs.csi.k8s.io` class
backed by an external NAS (not used). Live Herdr: one StatefulSet, PSA `restricted`, uid 1000, read-only rootfs, no
service-account token, 5Gi home + 20Gi workspace RWO PVCs. Pinned image
`ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277`
(Herdr 0.9.5, git **2.47.3**, python 3.13.5, util-linux flock 2.41.5). The scratch workload used this digest, the live
security context and the image's own entrypoint (real `herdr server`), with 1Gi PVCs.

## 2. Prototypes

- **`request-repo <id> <source>`** (python3 stdlib, runs inside the existing pod): per-repo `flock` under
  `/workspace/.herdr-repos/locks`; clone into `.herdr-repos/staging/<id>@<pid>.<rand>` on the same filesystem; promote
  with `renameat2(RENAME_NOREPLACE)`; write `state/<id>.json` after promotion; never run a writing Git command on an
  existing repository. Exit codes distinguish conflict, source mismatch, clone failure and lock timeout.
- **Per-repo PVC driver** (`m2-cluster.sh`): a workstation-side script creates PVC `repo-<id>` and an independent
  workspace pod that mounts it at `/workspace`, then hydrates with the same tool. No controller, no in-cluster
  credentials, no RBAC.

## 3. Findings

- **FIND-058 — The existing shared workspace PVC supports lazy hydration with no Herdr restart.** [cluster, M1]
  The repo appeared at a stable `/workspace/<id>` in the running scratch Herdr pod. Pod UID, restartCount (0) and the
  `herdr server` PID were unchanged across S01–S10, S12 and S13. Repos survived pod delete/recreate on the same PVCs (Ready in 21s):
  fsck clean, dirty state byte-identical (repository data only; Herdr sessions were not measured). Home and workspace are separate Longhorn devices with no cross-writes.
  Synthetic repos were small, so hydration timing is not representative (LIMITATION). REQ-004 satisfied; the REQ-010
  goal "new repository without restarting Herdr" is met **as a directory**, not as a volume.

- **FIND-059 — Staging + `RENAME_NOREPLACE` + per-repo `flock` gives idempotent, concurrency-safe hydration that never
  exposes partial state.** [cluster, local]
  - **Repeats:** repeated requests are no-ops (S05).
  - **Concurrency:**
    - 8 concurrent requests in one pod: 1 clone, 7 `already_ready` (S07).
    - 8 concurrent requests from **two pods on one node** sharing one RWO volume: 1 clone, 7 `already_ready`,
      `attempts=1` (F03).
  - **Failures and interruptions:**
    - A failed clone leaves nothing at the path and retries cleanly (S08).
    - SIGKILL before promotion (S09), during the clone (F01) and a container crash mid-hydration (F02) all leave nothing
      at the path. The next request removes the stale staging and hydrates.
  - **Local pitfalls the design avoids:** plain `rename(2)` silently replaces an *empty* target directory [docs], and
    `mv -T -n` exits 0 without moving [local, development observation, not in committed evidence]. The tool's
    behaviour is covered by `test_conflict_empty_dir_not_replaced`.

- **FIND-060 — Preserving dirty work requires avoiding Git's optional index writes.** [local, cluster]
  Plain `git status` rewrites the index, so the first preservation test failed on the index mtime [local, development
  observation; the failing run is not in committed evidence]. Read paths use only
  `git rev-parse` / `git config --get` with `GIT_OPTIONAL_LOCKS=0`. With that, dirty, untracked and staged files, local
  commits and stashes were identical, index mtime included, across re-requests (S10), a cross-node pod move (P07) and a
  container crash (F02).

- **FIND-061 — A PVC created after a pod starts cannot become visible to that pod; Kubernetes rejected both
  non-privileged routes tried, and no other is known.** [cluster, docs]
  - **Volume patch:** a server-dry-run patch adding a volume to the running Herdr pod was rejected:
    `spec: Forbidden: pod updates may not change fields other than spec.containers[*].image, …`.
    `ValidatePodUpdate` lists no volume fields.
  - **Ephemeral container:** one mounting the new claim was rejected with
    `spec.ephemeralContainers[0].volumeMounts[0].name: Not found`. The identical request mounting an existing volume
    was accepted, which rules out a syntax error.
  - **Mount propagation:** `Bidirectional` propagation is the only mechanism that would carry a later mount into a
    running container, and it requires a privileged container, which is incompatible with PSA `restricted` and
    ADR-0001 [docs].
  - **Observed state:** the repo PVC never appeared in the Herdr pod's `mountinfo` (P11).
  - **Symlinks:** a symlink to a path mounted only in another pod does not provide access; each pod resolves it in
    its own mount namespace [docs; not separately tested].

  REQ-010's "PVC per repository without restarting Herdr" therefore cannot be met for the Herdr process itself.

- **FIND-062 — Per-repo Longhorn PVCs work as standalone workspace pods, not as Herdr integration.** [cluster, M2/M4]
  - **Timings:**
    - Bind 2.9s (`Immediate`).
    - Workspace pod Ready ~14s.
    - Cross-node move delete→Ready 20.3s: old VolumeAttachment gone 7.8s, new one attached 17.7s.
    - PV removed 11s after PVC deletion.
  - **Durability and independence:**
    - Data and dirty state survived the move.
    - A second repo got its own PVC/PV and was deleted without touching the first.
  - **Failure isolation:**
    - Deleting a PVC under running consumers is deferred by `kubernetes.io/pvc-protection` (Terminating ≥30s, pods
      unaffected) and completes after the consumers go (F04).
    - A pod referencing a missing PVC stays Pending (`persistentvolumeclaim not found`) without affecting others (F05).

  What this buys is per-repo lifecycle, backup and restore granularity, and quota. It does **not** make the files
  available to the running Herdr (FIND-061).

- **FIND-063 — Longhorn RWO is per node, not per pod.** [cluster]
  - **Same node:** a second pod on the same node mounted the volume, and `flock` excluded across pods (P12a, F03).
  - **Different node:** the pod stayed Pending with a `Multi-Attach` event while the original consumer was unaffected
    (P12b). A clear failure, recovered by deleting the probe.

  Implication: future agent pods **co-located on Herdr's node** could mount the existing shared workspace PVC
  [inferred], at the cost of pinning them to that node. Every RWO volume one pod uses must also attach to one node.

- **FIND-064 — Worktree directories look like repository roots, and git 2.47.3 records absolute paths.** [cluster, local]
  - **Absolute paths:** the image's git predates `worktree.useRelativePaths` (2.48), so worktrees store absolute
    `/workspace/...` gitdir links (S13). They survived pod recreation and a container crash (S11, F02). Any future
    remount at a different path would break them until `git worktree repair` [local].
  - **Adoption bug:** the first `request-repo` adopted a linked worktree `<id>-w1` as a new managed repo and wrote
    `ready` state for it (F06, original tool) [cluster]. Fixed: a managed repo's `--absolute-git-dir` must equal
    `<target>/.git`. The fixed tool returned conflict for both worktrees and `already_ready` for the main repo, with
    no changes (F06r) [cluster]. Unit-tested on the host and in the image [local].

- **FIND-065 — Interruption leaves repo data fully restored; process cleanup is imperfect, and PIDs are not restart
  evidence.** [cluster]
  - **Container crash (F02):** killing the `herdr server` (exit 137) restarted the container in place (same pod UID,
    restartCount 0→1, Ready in 4.8s). Repos, worktrees and dirty state were intact; the interrupted request recovered
    on retry. **Session/agent recovery was not measured** (EXP-001/EXP-002 scope).
  - **Orphaned helpers (F01, LIMITATION):** `PR_SET_PDEATHSIG` stops only the direct `git clone` child. Its
    `upload-pack`/`index-pack`/`pack-objects` helpers outlived the killed tool by ~5s before exiting on their own. They
    only touch the abandoned staging directory, so correctness held.
  - **Harness checks:** the M4 summary records 4 FAILs, kept unedited: F06 (real, fixed), F01-kill (the helper limit
    above) and two false FAILs, corrected after the run from unchanged raw data
    ([CORRECTIONS.md](../../experiments/exp-005/evidence/m4-20261118a/CORRECTIONS.md)):
    - F03 compared the wrong status string.
    - F02 compared server PIDs, which repeat (7→7) in a restarted container's new PID namespace.

    S04's PID check is valid only within one container lifetime, which is how it was used.

## 4. Workspace indirection comparison (Milestone 3)

| Approach | New repo visible to running Herdr, no restart, no privilege | Main benefit | Main cost |
| --- | --- | --- | --- |
| **A1 Shared PVC + lazy directory hydration** | **Yes** [cluster] | Simplest; one PVC; no Kubernetes permissions for Herdr | One backup/restore unit; one quota; RWO pins sharers to one node |
| A2 Independent per-repo PVCs | No, needs pod replacement (FIND-061) [cluster] | Per-repo lifecycle, restore, quota, isolation primitive | 3 Longhorn replicas × N volumes; ~14–20s attach per pod; a provisioner needs `pvc/create` + `pods/create` |
| A3 Hydrate/sync into the shared PVC | Yes, but it is A1 plus a second copy [inferred] | Bridge from a future agent-owned volume | Two sources of truth; copied worktrees carry stale absolute paths; reconcile logic. Not justified |
| A4 Remote workspace pod (exec/SSH) | No: files are only in the remote pod; panes would have to run there [cluster P11, inferred] | Natural isolation unit for REQ-011 | `pods/exec` is cluster-sensitive, or adds sshd/keys/network path; this is execution, not storage |
| A5 One NFS/RWX volume, repos as subdirectories | Yes, by construction [inferred, not deployed] | Multi-node sharing for future agent pods | No RWX volume in use; whether the existing class serves one is untested (#32). Share-manager failover pauses IO for every repo, then up to a 90s (30s fast) lock-reclaim grace, after which unreclaimed locks return IO errors [docs; cited from the Longhorn 1.9 docs, not yet re-checked against 1.13]. git-over-NFS behaviour untested |

## 5. Recommendation (accepted by the owner as an experiment finding, 2026-11-19; not an ADR change)

1. **Shared PVC, lazy hydration, no restart?** Yes (FIND-058/059/060), measured in the pinned image with a real
   `herdr server`.
2. **What do per-repo Longhorn PVCs accomplish?** Independent lifecycle, deletion, restore and quota per repository,
   and an isolation primitive (FIND-062). Nothing for the running Herdr.
3. **Can their contents reach the running Herdr without pod replacement?** No, not without privileged mount propagation
   (FIND-061). Refuted for Kubernetes-native, PSA-restricted pods.
4. **Which indirection is viable?**
   - A1 now.
   - A5 is the only other option that gives a running process dynamic access; it needs a measured test first.
   - A2/A4 are viable only when the consumer is a pod created *after* the volume, i.e. independent execution.
5. **Tradeoffs:**
   - A1 has one blast radius and one restore unit, with strong local consistency (ext4, `flock`, atomic rename).
   - A2 shrinks the blast radius but adds attach latency and node pinning, and needs a privileged-in-effect
     provisioner.
   - A5 trades RWO pinning for NFS failover semantics.
6. **Does per-repo storage materially improve backup/lifecycle/isolation?** Lifecycle and isolation: yes for
   independently scheduled pods. Backup: only once a backup target or VolumeSnapshotClass exists; neither is
   configured today.
7. **Trusted MVP:** keep **one shared workspace PVC (ADR-0001 unchanged)** and adopt `request-repo`-style lazy
   hydration into it. Stable `/workspace/<id>` paths are mandatory (FIND-064). Herdr needs no Kubernetes API access.
   The `request-repo` prototype accepts only local file sources and is **not production-ready**; hardening is
   [#34](https://github.com/jlaska/herdrnetes/issues/34).
8. **Wait for EXP-006:**
   - per-repo PVCs;
   - workspace/agent pods;
   - any RWX layer;
   - the co-located-agent option from FIND-063.

   All of these only pay off once agents run in pods separate from Herdr (REQ-009/REQ-011).
9. **A storage controller would be justified only by:** independent agent pods that must mount a repo they did not
   create; per-repo quota or backup policy; multi-tenant isolation; or RWO co-location becoming unschedulable. Even
   then, test A5 with per-repo `subPath` mounts first. Hydration itself never needed a controller.
10. **Assumptions:**
    - **Confirmed:** pod volumes are immutable; RWO volumes attach per node; staging plus atomic rename is safe on
      ext4 (not tested over NFS); Longhorn PVC lifecycle works.
    - **Refuted:** that per-repo PVCs could give the running Herdr a new repository without restart.
    - **New:** RWO allows same-node multi-pod sharing; worktree directories can be mistaken for repos; Git's optional
      index writes threaten dirty-state preservation; PIDs are not restart evidence.

## 6. Traceability

| ID | Evidence | Links |
| --- | --- | --- |
| FIND-058 | M1 S01–S13 | REQ-004, REQ-010, ADR-0001 |
| FIND-059 | S05, S07, S08, S09, F01, F02, F03 | REQ-004, REQ-010 |
| FIND-060 | S10, P07, F02 | REQ-004 |
| FIND-061 | P11a–d; Kubernetes `ValidatePodUpdate`; volumes docs | REQ-010, ADR-0001 |
| FIND-062 | P01–P10, F04, F05 | REQ-010, REQ-009 |
| FIND-063 | P12a/b, F03 | REQ-009, REQ-011 |
| FIND-064 | S13, F06, F06r, unit tests | REQ-004, REQ-006 |
| FIND-065 | F01, F02 | REQ-004, REQ-009 |

## 7. Follow-ups

Recorded as issues linked from #6:
- [#31](https://github.com/jlaska/herdrnetes/issues/31): EXP-006 hand-off covering co-located agent pods on the shared
  RWO PVC versus per-repo PVCs, plus provisioner RBAC.
- [#32](https://github.com/jlaska/herdrnetes/issues/32): a measured Longhorn RWX comparison. The owner approved one
  disposable 1Gi RWX PVC on the **existing** `longhorn` class after a read-only preflight; a new StorageClass, Longhorn
  setting changes and failover injection are not approved. Separate from this experiment.
- [#33](https://github.com/jlaska/herdrnetes/issues/33): workspace backup granularity and crash consistency, since no
  backup target or VolumeSnapshotClass is configured.
- [#34](https://github.com/jlaska/herdrnetes/issues/34): `request-repo` hardening before real use: network sources with
  EXP-004 credentials, free-space checks, orphaned Git helpers, real repository sizes.
