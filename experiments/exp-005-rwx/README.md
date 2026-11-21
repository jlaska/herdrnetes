# EXP-005-RWX: scoped Longhorn RWX comparison (issue #32)

**Status: EXECUTED once (run `20261121a`, 2026-11-21, 17:20-18:47 UTC) at the unchanged pinned commit
`994071c0a6fcb412bceae7eb384d39f9615a54ac`.** Results and proposed findings FIND-066..070 (for owner review, not accepted) are in
[RESULTS.md](RESULTS.md); sanitized evidence is in [`evidence/20261121a/`](evidence/20261121a/). The text below this paragraph is the PREPARE-phase
description and is kept unchanged as the plan that was executed.

Follow-up to [EXP-005](../exp-005/RESULTS.md) (issue #6, findings FIND-058..065) under issue
[#32](https://github.com/jlaska/herdrnetes/issues/32): measure whether one disposable 1Gi `ReadWriteMany` PVC on the
**existing** `longhorn` StorageClass supports the shared-repository behaviours EXP-005 only compared on paper (architecture
option A5 in [docs/experiments/05-repository-storage.md](../../docs/experiments/05-repository-storage.md)). This is an
optional scratch experiment. [ADR-0001](../../docs/decisions/ADR-0001-trusted-mvp.md) is **unchanged**; the trusted MVP keeps one
shared RWO workspace PVC. Requirements touched: REQ-004, REQ-006, REQ-009, REQ-010 (see [requirements](../../docs/requirements.md)).

**Execution history.** The owner's review of the first PREPARE commit (PR #35, 2026-11-20) put execution on hold until three
fail-closed code paths were corrected; this revision contains those corrections. Execution was then authorized for 2026-11-21
([#32 comment 7066214683](https://github.com/jlaska/herdrnetes/issues/32#issuecomment-7066214683)) and run once. No further run is authorized.

Companion documents: [RESEARCH.md](RESEARCH.md) (documentation/issue research and the predictions it supports) and
[PREFLIGHT.md](PREFLIGHT.md) (read-only preflight observations).

Start with [PLAN.md](PLAN.md): exact resource inventory, the R00-R14 matrix, safe creation and guarded cleanup sequences,
security controls, expected Longhorn share-manager side effects, stop conditions and open questions.

## Owner decisions recorded (PR #35 review, 2026-11-20)

Planning decisions only; **not an execution grant**. Full table in [PLAN.md](PLAN.md#owner-decisions-recorded-pr-35-review-2026-11-20).

- Reuse the pinned EXP-005 image digest (D-1).
- The namespaced default-deny NetworkPolicy is **enabled by default** (D-2); `--no-network-policy` opts out.
- Run id `20261120a` is reserved as provisional; the execution date/window is **not approved** and follows review of this corrected code (D-3, D-9).
- A failed UID-1000 write or non-root git-clone gate is a valid negative result: stop and record, no workaround (D-4).
- Stop on degraded/faulted unrelated volumes only; an unreadable inventory is always a stop (D-5).
- The 4 s R05 pause hook is accepted (D-6); sanitized evidence is committed only after independent review (D-7); the 1 GiB / 30-60 minute budget is accepted and hung pods are never force-cleaned (D-8).
- The real tuppr phase vocabulary is verified in preflight; unknown, empty or active blocks (D-10). Only `Completed` is treated as idle, and both upgrade CRDs must be present with at least one object.

Still open: execution date/window, the 06:30-10:30 UTC guard (stricter than D-9's 06:30-08:30 because PREFLIGHT records a 3 h tuppr window) and confirmation of the upgrade-CR vocabulary (PLAN §14). The NFS gate is exactly `vers=4.1`.

## Hypotheses (to be measured, not assumed)

| ID | Hypothesis | Tests | Falsified by |
| --- | --- | --- | --- |
| H-RWX-1 | The existing `longhorn` class provisions a 1Gi RWX PVC with no new class or setting change; Longhorn creates a share-manager automatically; two pods on different nodes mount it. | R00, R01 | PVC not Bound, provisioning error, share-manager not Running, pods not schedulable on two nodes |
| H-RWX-2 | `/rwx` is an NFSv4.1+ mount on both pods. With CSIDriver `fsGroupPolicy=ReadWriteOnceWithFSType`, `fsGroup: 1000` is **not** applied to the RWX volume, yet UID 1000 can create, write and rename at the export root, files it creates are owned by uid 1000, and a non-root `git clone` onto the volume works (Longhorn #10621 regression absent). | R02 | the NFSv4 check, write gate or git smoke fails on either pod (then the run STOPS; that is a valid negative result) |
| H-RWX-3 | Cross-node close-to-open semantics hold for new files and in-place updates seen through `open()`/`readdir`; `stat`-only polling of an absent name may lag (attribute cache). mmap+msync data and hardlink/symlink/atomic replace work; `O_APPEND` from two clients is **not** guaranteed atomic. | R03, R10 | timeouts or stale content through `open()`; mmap mismatch |
| H-RWX-4 | Git clone/commit/fsck are consistent across nodes in sequential hand-off, and the unmodified EXP-005 `request-repo` works on the mount (Git's ownership check passes). | R04 | a stale or corrupt repo, fsck failure, "dubious ownership" |
| H-RWX-5 | `request-repo`'s per-repo `flock` serialises hydration across nodes: 4+4 concurrent requests give 1 `hydrated`, 7 `already_ready`, `attempts=1`; different repos hydrate independently. | R05 | more than one clone, rc 4/6, fsck failure |
| H-RWX-6 | `flock` and `fcntl` locks are enforced across nodes and released when the holder exits. | R06 | contender acquires while held, or never acquires after release |
| H-RWX-7 | `renameat2(RENAME_NOREPLACE)` fails with `EINVAL` on the NFS mount (predicted in the issue and by the research; unverified), so `request-repo` takes its flock-guarded `rename-fallback`, which stays correct under the lock (its guarantee rests on the lock alone); plain rename onto a non-empty dir fails ENOTEMPTY/EEXIST. | R07 | NOREPLACE works (then `promotion=renameat2`), or the fallback replaces an existing target |
| H-RWX-8 | Concurrent Git on one repository yields explicit `index.lock`/ref-lock errors but **no lost commit** and a clean fsck; `O_EXCL` creation is exactly-once across nodes. | R08 | commit count mismatch, fsck failure, double creation |
| H-RWX-9 | Worktrees work across pods because both mount at the same absolute path (`/rwx`); the linked `.git` file holds an absolute path (FIND-064). | R09 | worktree list/commit not consistent across pods |
| H-RWX-10 | Small-file Git and file operations on RWX are materially slower than on local emptyDir; magnitude measured. Not comparable with RWO (no RWO control). | R11 | (measurement only) |
| H-RWX-11 | Graceful deletion of one pod releases its locks promptly; the recreated pod mounts the same data (fsck clean) and the other node sees no I/O errors. | R12 | locks stuck, data loss, I/O errors on the surviving node |
| H-RWX-12 | The share-manager, Service/endpoints, ShareManager CR and Longhorn volume exist only as a consequence of the PVC, stay unchanged for the whole run, and all disappear after guarded cleanup (reclaim `Delete`); live Herdr is unaffected. | R13, R14 | share-manager restart/reschedule, residue after cleanup, Herdr change |

## Contents

| Path | Purpose |
| --- | --- |
| [PLAN.md](PLAN.md) | inventory, R00-R14 matrix, sequences, controls, stop conditions, open questions |
| `manifests/` | `namespace.yaml`, `pvc.yaml`, `pod.yaml` (rendered for `rwx-a` and `rwx-b`), optional `networkpolicy.yaml`; `${RUN_ID}`/`${NAMESPACE}` templates |
| `harness/rwx` | CLI (cluster identity, Herdr-node, maintenance-window, hang guards; fail-closed reads and cleanup verification): `plan`, `preflight`, `create`, `run`, `collect`, `recreate`, `cleanup`, `sanitize`; offline dry run by default |
| `harness/rwxlib.py` | guarded kubectl wrapper, mutation allow-list, invariants, cleanup planner, sanitizer, evidence writer |
| `harness/scenarios.py` | orchestration of R00-R14 |
| `harness/podprobe.py` | stdlib in-pod probes, streamed over `kubectl exec` stdin |
| `tests/` | local unit tests (no cluster); `tests/run-local.sh` |
| `evidence/20261121a/` | sanitized evidence of the executed run (see [RESULTS.md](RESULTS.md)) |

The harness reuses, without copying, `experiments/exp-005/harness/request-repo` and the EXP-005 image digest
(`ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277`).

## Running the local tests (no cluster)

```text
experiments/exp-005-rwx/tests/run-local.sh        # uv run --with pyyaml python -m unittest discover ...
rwx plan                                          # prints what would be created; contacts nothing
```

Local verification (2026-11-20, no cluster): `tests/run-local.sh` ran 274 tests, all OK (138 of them fail-closed regressions in `tests/test_failclosed.py`, run alone with `uv run --with pyyaml python -m unittest discover -s tests -p test_failclosed.py`) (unit tests for the guards, sanitizer,
manifests, cleanup planner and in-pod probes, plus an end-to-end simulation of R00-R14 and of the stop conditions against a
simulated kubectl backed by local processes). `uvx ruff check` and `shellcheck` are clean. The simulation is not evidence about
Longhorn/NFS behaviour; it only checks the harness logic. All test git invocations are hermetic (`GIT_CONFIG_GLOBAL=/dev/null`,
`GIT_CONFIG_NOSYSTEM=1`; no signing key, SSH agent or user git configuration is ever used).

Modes of every `rwx` subcommand: no flag = offline dry run (kubectl is never executed); `--live` = read-only cluster contact;
`--execute --confirm-run-id <same id>` = mutations. Execution requires the owner's explicit go-ahead on the PR.
