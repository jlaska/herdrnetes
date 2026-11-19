# EXP-005 results

Scratch namespace `herdrnetes-exp005` on the owner-designated cluster (Kubernetes v1.36.6, Longhorn v1.13.0, class
`longhorn`). Image `ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277`
(Herdr 0.9.5, git 2.47.3, python 3.13.5). Node names are replaced with `<node-N>`. Raw sanitized evidence is in
[`evidence/`](evidence/), with one directory per run. Findings and recommendation are in
[`docs/experiments/05-repository-storage.md`](../../docs/experiments/05-repository-storage.md).

Local tests (`tests/run-local.sh`): 21/21 on the host (git 2.56.0) and 21/21 in the pinned image under Podman
(`--read-only --user 1000`, all capabilities dropped).

Live Herdr (`herdrnetes-exp/herdr-0`, read-only): UID `a3542452-…`, herdr restarts 0, Ovis restarts 4. This was
identical before and after every run and after cleanup.

## M1 — shared PVC (`m1-20261118a`): 0 failed

| ID | Result | Observed |
| --- | --- | --- |
| S01–S03 | PASS | absent → `hydrated` at `/workspace/<id>`; `show-toplevel` = path; `fsck --strict` clean |
| S04 | PASS | pod UID, restartCount 0, `herdr server` PID 7 unchanged across S01–S13 |
| S05 | PASS | `already_ready`; `.git` inode/mtime, index, HEAD, config unchanged |
| S06 | PASS | two repos hydrated independently |
| S07 | PASS | 8 concurrent: 1 `hydrated`, 7 `already_ready`, 1 clone, attempts=1 |
| S08 | PASS | bad source rc=5, nothing at path, state `failed`; retry `hydrated` attempt=2 |
| S09 | PASS | SIGKILL before promotion: target absent, staging present; rerun hydrated, staging removed |
| S10 | PASS | dirty/untracked/staged/local commit/stash identical (index mtime included) |
| S11 | PASS (data) | pod recreated (new UID), Ready 21s, all repos fsck clean, dirty state identical. Session survival not claimed |
| S12 | PASS | home and workspace on separate Longhorn devices; no repo artefacts in home |
| S13 | INFO | worktree `.git` = `gitdir: /workspace/<id>/.git/worktrees/<wt>` (absolute) |

## M2 — per-repo PVC (`m2-20261118a`): 0 failed

| ID | Result | Observed |
| --- | --- | --- |
| P01–P03 | PASS | PVC created, Bound in 2.9s |
| P04–P05 | PASS | workspace pod Ready 13.9s; ext4 Longhorn device at `/workspace`; hydrated, fsck clean |
| P06 | PASS | forced `<node-1>`→`<node-2>`: delete 1.0s, old VA gone 7.8s, new VA attached 17.7s, delete→Ready 20.3s |
| P07 | PASS | dirty/untracked/staged/stash/commit identical across the move |
| P08 | PASS | repo B has its own PVC/PV; not visible in A's pod |
| P09 | PASS | B pod+PVC deleted, PV gone in 11.1s (reclaim `Delete`); A unaffected |
| P10 | PASS | scratch Herdr UID/restarts/PID unchanged at every checkpoint |
| P11a | PASS | repo PVC absent from scratch Herdr `mountinfo` and filesystem |
| P11b | PASS | volume patch rejected: `pod updates may not change fields other than …` |
| P11c | PASS | ephemeral container mounting the new claim rejected: `volumeMounts[0].name: Not found` |
| P11d | INFO | control: ephemeral container mounting existing `workspace` accepted (dry-run) |
| P12a | PASS | same-node probe Ready; `flock -n` rc=75 while held, rc=0 after release |
| P12b | PASS | different-node probe Pending with `Multi-Attach` event over 120s; original consumer healthy |

All P11 patches were `--dry-run=server`. The scratch Herdr pod was never modified.

## M4 — targeted failure tests (`m4-20261118a`)

| ID | Result | Observed |
| --- | --- | --- |
| F06 | FAIL → fixed | the original tool (in the pod's M1 ConfigMap) adopted linked worktree `<id>-w1` as a repo and wrote `ready` state |
| F06r | PASS | fixed tool piped through `kubectl exec -i … python3 -`: both worktree ids rc=4 conflict, main repo `already_ready`; snapshots unchanged |
| F01 | PASS / LIMITATION | 200 MiB source, uninterrupted clone 26.0s. SIGKILL of `request-repo` at +0.08s during the clone: target absent, staging present; rerun hydrated, staging removed, fsck clean. Git helpers (`upload-pack`, `index-pack`, `pack-objects`) survived 4.96s (want ≤2s) |
| F03 | PASS (check corrected) | 2 pods × 4 concurrent on one RWO volume, same node: 1 `hydrated`, 7 `already_ready`, 1 clone, attempts=1, fsck clean. The harness first reported FAIL from a string mismatch (`rcs={'0': 8}` vs `rcs={'rc=0': 8}`) |
| F04 | PASS | PVC deleted under 2 running consumers: Terminating with `pvc-protection` ≥30s, pods and repo read/write unaffected; gone 39.6s after delete, PV gone 49.0s |
| F05 | PASS | pod on missing PVC Pending (`persistentvolumeclaim not found`); other pods unaffected |
| F02 | PASS (check corrected) | `kill -9` of `herdr server`: container exit 137, restarted in place (same pod UID, restarts 0→1) in 1.4s, Ready 4.8s. Interrupted request left target absent, rerun hydrated; M1 repos fsck clean, dirty snapshot and worktrees identical. The harness first reported FAIL because the PID repeats (7→7) in the new container |

Harness checks for F03 and F02 were corrected after the run; the raw data is unchanged. `raw/f05-pod.yaml` was withheld
by the redaction script (false positive on `automountServiceAccountToken`).

## Failure and recovery matrix

| Scenario | Class | Recovery | Evidence |
| --- | --- | --- | --- |
| First hydration | PASS | — | S02, P05 |
| Repeated hydration | PASS | — | S05, P06 |
| Concurrent hydration (one pod; two pods one node) | PASS | — | S07, F03 |
| Failed clone | PASS | fully restored by retry | S08 |
| Interrupted clone (before promotion; mid-clone; container crash) | PASS, LIMITATION (orphaned helpers ~5s) | fully restored by retry | S09, F01, F02 |
| Dirty worktree | PASS | — | S10, P07 |
| Multiple Git worktrees | PASS after fix; LIMITATION (absolute paths) | — | S13, F06, F06r |
| Workspace-pod deletion | PASS | fully restored | P06 |
| Workload restart (clean pod recreate; forced container crash) | PASS (repository state) / UNTESTED (sessions) | repos fully restored; processes lost | S11, F02 |
| RWO attachment conflict | PASS (clear failure) | original unaffected; delete the conflicting pod | P12b |
| Unavailable repository volume (missing PVC; PVC deleted under use) | PASS | others unaffected | F05, F04 |
| Unavailable volume from node/replica failure | UNTESTED | — | needs node disruption (out of scope) |
| Separate home/workspace | PASS | — | S12 |

## Cleanup

`harness/cleanup.sh` was run per run ID in order m4 → m2 → m1. Each run followed a dry run whose delete list the lead
checked against the approved scope.

**Defect found during cleanup:** the dry-run plan listed `persistentvolumeclaim/…`, but the delete loop iterated the
short kind `pvc`, so PVCs were planned and then silently skipped. The m2 confirmed run deleted the pod and ConfigMap,
left the PVC and kept the namespace. The executor stopped, as instructed, because the outcome diverged from the
approved plan. After the fix (`persistentvolumeclaim` in the loop), the m2 and m1 runs matched their dry runs exactly.
Lesson: a cleanup's dry run must be generated by the same code path that deletes.

Verification (`evidence/m4-20261118a/raw/cleanup-verify.txt`):
- `herdrnetes-exp005` NotFound 21s after the request.
- No PV with a claimRef in that namespace.
- No Longhorn volume with that namespace.
- No VolumeAttachment for the scratch PVs.
- Live `herdr-0` UID, restarts and both live PVCs (5Gi, 20Gi, Bound) unchanged.
