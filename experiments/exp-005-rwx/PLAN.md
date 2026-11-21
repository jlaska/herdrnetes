# EXP-005-RWX plan: Longhorn RWX comparison (PREPARE; executed once as run `20261121a`)

**Status: PREPARE plan, executed unchanged once on 2026-11-21 as run `20261121a`; results in [RESULTS.md](RESULTS.md).** The plan text below is kept as
reviewed. Tracking issue: [#32](https://github.com/jlaska/herdrnetes/issues/32) (follow-up to EXP-005 / #6, findings
FIND-058..065). [ADR-0001](../../docs/decisions/ADR-0001-trusted-mvp.md) is unchanged; nothing here proposes changing it.
Distinction used throughout: **accepted decision** (ADR-0001), **owner-approved conditions** (issue #32), **hypotheses**
(README), **observed evidence** ([RESULTS.md](RESULTS.md), run `20261121a`), **proposals** (this plan, for owner review).

Execution requires the owner's explicit go-ahead on the PR that carries this directory.

Companion documents: [RESEARCH.md](RESEARCH.md) (documentation and issue-tracker research behind the predictions below) and
[PREFLIGHT.md](PREFLIGHT.md) (read-only preflight observations). Both are inputs; this plan separates their claims from what the run will measure.

## 1. Approved scope (issue #32, owner decision 2026-11-19) and how the plan honours it

| Condition | Plan |
| --- | --- |
| One disposable 1Gi RWX PVC on the **existing** `longhorn` class; no new StorageClass; never the NAS `nfs.csi.k8s.io` class | `manifests/pvc.yaml` is the only claim; preflight STOPs if the class is missing, is not `driver.longhorn.io`, or its reclaim policy is not `Delete` |
| Up to two scratch pods, ordinary pods | `manifests/pod.yaml` rendered twice (`rwx-a`, `rwx-b`); no controller, no operator |
| Dedicated, uniquely labelled namespace | `herdrnetes-exp005-rwx-<run-id>`, labels `herdrnetes.io/experiment=exp-005-rwx`, `herdrnetes.io/run-id=<run-id>`, PSA `restricted` |
| Different nodes | required `podAntiAffinity` on `kubernetes.io/hostname`; no node names in committed files |
| Longhorn share-manager observed **read-only** | R13 uses `get` only, by exact name or label; never edit/delete/restart; failover settings untouched |
| No disruptive tests | see section 12 (out of scope) |
| Guarded cleanup tied to the run-id, with verification | section 7 and R14; live Herdr UID/restarts compared before and after |
| Synthetic repositories only, no credentials, no egress | repositories are generated inside the pods; sources are `file://` paths on the RWX mount |
| Output routing (issue #32, "Output" section: Opus orchestrates/reviews, Sonnet implements, Haiku bounded commands) | process instruction from the issue, not a scope boundary; this plan and harness are the Sonnet deliverable and Opus review precedes any execution |
| Scratch pods away from live Herdr (review requirement) | second required anti-affinity term against `app.kubernetes.io/name=herdr` in `HERDR_NS`; R00 stops if fewer than 2 candidate nodes remain |

### Owner decisions recorded (PR #35 review, 2026-11-20)

From the owner's review of `dedc4752e7e2f0ae00faf32bef8304af81094e1a` (NO-GO for execution at that commit). **These are planning decisions, not an execution grant**: a new explicit authorization (run id plus window) is required before anything is created, and ADR-0001 is unchanged.

| ID | Decision | Where reflected |
| --- | --- | --- |
| D-1 | Reuse the exact EXP-005 pinned image digest; no new image | section 3 |
| D-2 | Namespaced default-deny NetworkPolicy **enabled by default** (opt out only with `--no-network-policy`) after static confirmation that the NFS mount is node-mediated and the tests need no pod egress | section 2.1, section 8 |
| D-3 | Run id `20261120a` reserved as **provisional**; the actual start window is chosen only after the corrected code is reviewed | section 6, section 14 |
| D-4 | A failed UID-1000 write or non-root git-clone gate is a valid **negative result**: stop and record; no privilege or StorageClass workaround | R02, section 9 |
| D-5 | Stop on newly degraded/faulted *unrelated* volumes; other robustness changes are INFO; **an unreadable inventory is always a STOP** | section 9 items 3 and 15 |
| D-6 | The 4-second test-only pause hook is allowed for R05 round one; round two is unpaused validation; no production integration | R05 |
| D-7 | Sanitized evidence is committed only after independent review of the withheld list, redaction results and identifiers; failure records are preserved as observed | section 11 |
| D-8 | 1 GiB logical (3-replica) scratch volume and a nominal 30-60 minute window accepted; hung pods are never force-cleaned | section 9 item 13 |
| D-9 | Execution date/window deferred until the corrected SHA and renewed approval; outside 06:30-08:30 UTC and outside observed maintenance | section 14 |
| D-10 | The actual tuppr upgrade-CR vocabulary is verified in read-only preflight; unknown, empty/unavailable or active state blocks, nothing is assumed idle | R00, section 9 item 12 |

Review blockers fixed in this revision (all with failure-injection regression tests in `tests/test_failclosed.py`): **A** cleanup verification is tri-state and fails closed (exit 6 UNVERIFIED, exit 5 RESIDUE); **B** health, node, Longhorn-inventory and upgrade-controller reads fail closed in R00 and between tests; **C** R02 positively proves an NFSv4 mount, identity/security assertions and the non-root git smoke on **both** pods before any later test may start.

## 2. Exact resource inventory

### 2.1 Created by the harness (all carry `herdrnetes.io/experiment=exp-005-rwx` and `herdrnetes.io/run-id=<run-id>`)

| # | Kind | Name | Notes |
| --- | --- | --- | --- |
| 1 | Namespace | `herdrnetes-exp005-rwx-<run-id>` | PSA enforce/audit/warn = `restricted`; `herdrnetes.io/disposable=true` |
| 1 | PersistentVolumeClaim | `rwx-scratch` | `ReadWriteMany`, 1Gi, `storageClassName: longhorn`, Filesystem |
| 2 | Pod | `rwx-a`, `rwx-b` | image pinned by digest; `restartPolicy: Never`; see section 8. Pod `rwx-b` is deleted and recreated once (R12) |
| 1 | NetworkPolicy | `default-deny-all` | **enabled by default** (owner decision D-2; opt out with `--no-network-policy`): deny all ingress and egress. The NFS mount is made by the kubelet/CSI on the node, not from the pod network namespace, and `kubectl exec` is mediated by the API server and kubelet, so the tests need no pod network (static reasoning; R02's successful mount and probes are the confirmation) |

That is the whole list: **1 PVC, 2 pods**, plus the namespace and one NetworkPolicy. No ConfigMap (probe scripts
are streamed over `kubectl exec` stdin), no Service, no Secret, no ServiceAccount, no RBAC, no cluster-scoped object.

### 2.2 Created by Kubernetes or Longhorn as a consequence (expected; verified read-only, never modified by us)

| Where | Object | Created by | Removed by |
| --- | --- | --- | --- |
| namespace | ServiceAccount `default`, ConfigMap `kube-root-ca.crt` | Kubernetes | namespace deletion |
| cluster | PersistentVolume `pvc-<uid>` (reclaim `Delete`) | CSI provisioner | PVC deletion |
| cluster | VolumeAttachment(s) (CSI `attachRequired=true`) | attach/detach controller | pod/PV removal |
| `longhorn-system` | Longhorn `Volume` (name = PV name), Engine, Replicas (class default: 3) | Longhorn manager | PV deletion |
| `longhorn-system` | **ShareManager CR**, **share-manager pod** `share-manager-<pv>`, **Service** (and Endpoints/EndpointSlice) named `<pv>` | Longhorn, because the volume is `rwx` | removed by Longhorn when the volume detaches/is deleted |
| `longhorn-system` | Longhorn-internal attachment tickets, events | Longhorn | with the volume |
| any | Kubernetes Events | various | TTL |

If anything *else* appears (for example a second PV, an extra Longhorn volume, a PVC outside the namespace), R13/R14 record it and
the run stops.

### 2.3 Read-only (never mutated)

Nodes, StorageClass `longhorn`, CSIDriver `driver.longhorn.io`, Longhorn volumes/nodes/settings/share-managers/pods, the live Herdr pod
(UID and restart counts only; namespace and pod name from `HERDR_NS`/`HERDR_POD`, defaults `herdrnetes-exp`/`herdr-0`), VolumeAttachments.
Secrets are never read (the read guard refuses them).

## 3. Image and tooling

**Image:** `ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277`.
Source: the digest EXP-005 used ([RESULTS.md](../exp-005/RESULTS.md), `experiments/exp-005/manifests/workspace-pod.yaml`),
so Git behaviour is comparable (git 2.47.3, python 3.13.5, util-linux `flock` 2.41.5, bash, Debian 13). The pods override the entrypoint, so
`herdr` is not started. The same unmodified `experiments/exp-005/harness/request-repo` is streamed into the pods, so R04/R05/R07 test the
prototype as built (its sha256 is recorded in the evidence summary).

Probes (`harness/podprobe.py`, stdlib only) are streamed with `kubectl exec -i … python3 -I - <cmd>`, so nothing is copied into the image
or the volume except the synthetic test data.

## 4. Test matrix R00-R14

Status vocabulary: PASS / FAIL for checks with a fixed expectation; INFO for measurements; LIMITATION for a measurement with a stated
caveat. A refuted hypothesis is a valid result: only the **stop conditions** in section 9 abort the run. Hypotheses H-RWX-n are defined in
the [README](README.md). Every operation is performed as UID 1000 inside the pods; nothing is done as root.

| ID | Objective | Procedure | Expected | Pass/fail criteria | Evidence captured | Links |
| --- | --- | --- | --- | --- | --- | --- |
| R00 | Baseline, read-only preflight, **cluster identity and maintenance guards** | UTC outside 06:30-10:30 (tuppr window 07:00Z + 3 h + margin); nodes all Ready and uncordoned; upgrade-controller CRs (tuppr `TalosUpgrade`/`KubernetesUpgrade`, found by listing CRDs) all `Completed` (empty/missing/other phase blocks; both expected CRDs must be present and non-empty in successfully read lists, otherwise "state unavailable" stops); context exists; **identity: every `longhorn-manager` image tag == `RWX_EXPECT_LONGHORN` (default `v1.13.0`, recorded), namespace `HERDR_NS` exists, exactly one pod labelled `app.kubernetes.io/name=herdr` owned by a StatefulSet**; >= 2 Ready/schedulable/untainted nodes **excluding the Herdr node**; server version; namespace absent; class `longhorn` exists, provisioner `driver.longhorn.io`, reclaim `Delete`; CSIDriver `fsGroupPolicy`; a **successfully read, non-empty** Longhorn volume inventory with none degraded/faulted, all `longhorn-system` pods Running, all Longhorn nodes Ready/Schedulable; Longhorn settings read (`rwx-volume-fast-failover` must exist; storage-network settings); `auth can-i` must answer `yes`; **every one of these reads is fail-closed: an error, timeout, empty or malformed answer STOPs, it is never treated as healthy, empty or idle**; Herdr baseline (UID, restarts) | Healthy; correct cluster; class allows RWX claims; CSIDriver `ReadWriteOnceWithFSType`; quiet maintenance state | PASS if every precondition holds; any failure (including a wrong context) is a STOP before anything is created | `preflight.json` (sanitized): versions, node aliases, identity block (expected/observed tags, Herdr node alias, candidate nodes), UTC time, class parameters, Longhorn health counts, Herdr UID prefix and restarts | REQ-004, FIND-058, H-RWX-1 |
| R01 | Provision RWX PVC; two pods on different nodes, neither on the Herdr node | apply namespace, [NetworkPolicy], PVC; wait Bound (120 s); apply pod A, wait Ready (300 s), wait share-manager Running (180 s); apply pod B, wait Ready; compare nodes | PVC Bound; share-manager appears (it may land on any node, including the Herdr node: Longhorn-controlled, INFO); pods Ready on different non-Herdr nodes | PASS if all within timeouts and nodes differ; else STOP (collect, cleanup) | timings; PVC/PV; pod placement (aliases); events; Longhorn volume `accessMode`/robustness; share-manager state | REQ-004, REQ-010, FIND-062, FIND-063, H-RWX-1 |
| R02 | **Positive filesystem/identity gate on BOTH pods**; mount, owner/mode, fsGroup observation; UID 1000 write gate | per pod: `identity` (uid/gid/groups/umask/NoNewPrivs/CapEff), `/proc/self/mountinfo` for `/rwx` (fstype, source, NFS options), `statvfs`, root stat; gate = create+write+fsync, read back, rename file, owner==caller, mkdir+rename dir, create in subdir, symlink, unlink/rmdir **at the mount root**; **git smoke as UID 1000 (Longhorn #10621: non-root `git clone` onto RWX hit permission denied while other operations worked):** `git init` a tiny source on `/rwx`, `git clone file://…` onto `/rwx`, commit in the clone, `git fsck --strict`, stderr recorded; then create `/rwx/work/{sources,ws,locks,worktrees,pp,scratch,perf}` | fstype `nfs4` with `vers=4.1` exactly (4.0, 4.2, 3 or a missing `vers` stop), mounted at `/rwx` itself, same export on both pods; fsGroup **not** applied (hypothesis); root writable by UID 1000; created files owned numerically by 1000 | **STOP gate (per pod, both required; R03-R14 never start otherwise):** `/rwx` not an NFSv4 mount (`fstype nfs4`, `vers` missing or not exactly `4.1`, source missing or different between pods), uid/gid != 1000/1000, NoNewPrivs != 1, effective capabilities not empty, any gate step failing or missing (including the non-root git smoke), root owner/group outside {0,1000}, created-file owner != 1000, or any probe output missing/unparseable => STOP, collect, cleanup. No chown, no root container, no PSA relaxation, no Longhorn/StorageClass change. fsGroup applied or not is INFO | `raw/r02-*.json` (identity, mountinfo, gate per pod) | REQ-004, FIND-064, H-RWX-2 |
| R03 | Cross-node visibility, close-to-open | ping-pong over the shared dir (each side uses only its own monotonic clock): writer creates `ping.<i>` (O_EXCL, fsync, close) and waits for `pong.<i>`; reader polls by `open`, by `listdir`, by `stat` (3 iterations, 75 s timeout); in-place update variant (truncate+rewrite one file, reader re-reads); 20 iterations, both directions | `open`/`listdir`: sub-second RTT, no timeout, no content mismatch; `stat`-only may lag (attribute/negative-dentry cache) | `open`/`listdir`/in-place: PASS if 0 timeouts and 0 content mismatches; `stat`: INFO (lag recorded) | per-direction RTT median/max, timeouts, mismatches | REQ-004, REQ-010, H-RWX-3 |
| R04 | Sequential hand-off with real `request-repo` | A creates synthetic repo `h1` (300 files, 5 commits) as a bare source; poll until B sees it; B hydrates `file:///rwx/work/sources/h1.git` into `/rwx/work/ws/h1`; A re-requests; 3 rounds of alternating commits (B commits, A must see HEAD; then A commits, B must see HEAD); `git fsck --strict` on both | B `hydrated` (cross-node first clone), A `already_ready`; every commit visible to the other node; heads and commit counts agree; fsck clean | PASS only if all hold | source-visibility delay; `request-repo` JSON (incl. `promotion`); commit-visibility latencies; fsck from both nodes | REQ-004, REQ-010, FIND-058, FIND-059, H-RWX-4 |
| R05 | Concurrent hydration across nodes | source `big` (3000 files, 5 commits). Round 1: 4 `request-repo c1` on A + 4 on B concurrently, `REQUEST_REPO_TEST_PAUSE_AFTER_CLONE=4` to widen the critical section (existing test hook); round 2: same for `c2` without the hook; then A hydrates `d1` while B hydrates `d2`, each verified from the other node | 1 `hydrated`, 7 `already_ready`, `attempts=1`, all rc 0; different repos independent; fsck clean everywhere | PASS if counts and fsck as stated (otherwise the cross-node lock guarantee of FIND-059 does not carry over) | action/rc/attempt tallies; fsck results; per-process JSON | REQ-010, FIND-059, H-RWX-5 |
| R06 | Cross-node `flock` and `fcntl` mutual exclusion | holder process on one node holds an exclusive lock for 14 s; contender on the other node: 3 s non-blocking-with-timeout try, then 60 s blocking try; `flock` in both directions, `fcntl` once | contender is refused while held, acquires after the holder exits (about the remaining hold time) | PASS if refused while held AND acquired after release | errno, waited seconds, holder HELD event | REQ-004, FIND-059, FIND-063, H-RWX-6 |
| R07 | `renameat2(RENAME_NOREPLACE)` availability and fallback | probe on both pods (and an emptyDir control): file to absent, file to existing, dir to absent, dir to existing empty dir via `renameat2`; plain `rename` onto an empty dir (silently replaces) and onto an existing **non-empty** dir; collect `promotion` values from R04/R05. No probe pre-creates an empty promotion target | **Predicted** (RESEARCH.md): EINVAL for any renameat2 flag on the Linux NFS client, so `request-repo` reports `rename-fallback`; plain rename onto a non-empty dir fails ENOTEMPTY/EEXIST | PASS if no probe replaced an existing file under NOREPLACE, plain rename onto a non-empty dir was refused (ENOTEMPTY/EEXIST), and every hydration promoted by some method; support/errno itself is INFO | errno table per pod and control (incl. non-empty-dir cases); promotion methods observed | FIND-059, H-RWX-7 |
| R08 | Same-repo concurrent Git, `index.lock`/ref-lock, and `O_EXCL` race | repo `race` hydrated; both pods run 25 add+commit iterations on the **same** worktree simultaneously (start time agreed via pod A's clock); failures classified (`index.lock`, ref lock, nothing-to-commit, other); then fsck and commit count == initial + successes. O_EXCL: both pods race to create 300 names; each name must exist exactly once, creators disjoint | Some `index.lock` collisions (Git does not wait); **no lost update**; fsck clean; O_EXCL exactly-once | PASS if fsck clean AND count matches AND O_EXCL exactly-once; collision counts are INFO | failure classification and samples; commit counts; O_EXCL win sets | REQ-004, FIND-060, H-RWX-8 |
| R09 | Worktrees across pods, stable absolute paths | on `h1`: A `worktree add wt-a`; B lists it, runs status, commits inside it; A sees the commit; inspect linked `.git` file (absolute gitdir); concurrent `worktree add` wt-c (A) and wt-d (B); B removes wt-c; A prunes; both list identically; fsck; **INFO sub-step (R09-move):** on a separate repo, add a worktree, rename the parent repo directory within `/rwx`, observe the broken absolute gitdir link, run `git worktree repair`, observe recovery | works from both pods because both mount at `/rwx` (identical absolute paths); `.git` file absolute; renaming the parent breaks the worktree until repaired. Rule: **create worktrees after promotion, at the final path** | PASS if all git commands succeed, lists are identical on both nodes, final fsck clean (a lock error in the concurrent add is recorded and retried sequentially) | list output, `.git` file text, concurrent-add rc/stderr | REQ-004, REQ-006, FIND-064, H-RWX-9 |
| R10 | POSIX edge semantics | umask 022/002/077 file+dir modes; `chmod 444` then `access(W_OK)`; `chmod g+s` on own dir; mmap write+msync read by the other node (sha256); 20 fsync latencies; hardlink, symlink, atomic `os.replace`, `user.*` xattr, fallocate; `O_APPEND` from both nodes (2x500 lines) analysed for lost/garbled lines | mmap content identical cross-node; hardlink/symlink/replace work; O_APPEND **may** lose or interleave lines across clients (NFS) | mmap and basics: PASS/FAIL; everything else INFO | mode table, fsync ms, append analysis | REQ-004, H-RWX-3 |
| R11 | Small-file performance | `big` (3000 files, ~1 KiB each): per run clone, `status`, `checkout alt` (touches all files), `status`, `checkout main`, `fsck`, `rm -r`, plus 3000-file create/stat/read/delete; 5 runs on pod A, 5 on pod B (sequential, not concurrent), and the same 5 on an emptyDir control; medians/min/max | RWX slower than emptyDir by a factor that is measured | INFO with medians; LIMITATION recorded: **no RWO control PVC is approved and EXP-005 recorded no small-file timings, so the comparison is RWX vs emptyDir only; the emptyDir is node-local ephemeral storage, not Longhorn ext4, so it bounds rather than measures the RWO gap** | `raw/r11-*.json`, `r11-summary.json`, source-creation time | REQ-004, REQ-010, H-RWX-10 |
| R12 | Ordinary pod delete/recreate | pod B takes an exclusive `flock` and holds it; B writes data (sha recorded); A starts a 150 s heartbeat writer; **graceful** `kubectl delete pod rwx-b` (default grace, no `--force`); A tries the lock (150 s timeout); recreate B from the same manifest; wait Ready; re-run gate; verify data sha, fsck from both nodes, lock re-acquirable, A heartbeat gaps and errors | lock freed promptly; same data; fsck clean; no I/O errors on A; new pod UID; different node from A | PASS only if all hold | seconds to gone/lock-free/Ready; heartbeat max gap and errors; pod events (FailedMount etc.) | REQ-006, REQ-009, FIND-063, FIND-065, H-RWX-11 |
| R13 | Share-manager lifecycle, image and objects (read-only) | at ~14 checkpoints: share-manager pod (UID, phase, restarts, node alias, **image tag and imageID**), Longhorn **replica node aliases**, scratch pod phase/restart counts, Herdr restarts, ShareManager CR state, Service present, Longhorn volume state/robustness/accessMode, engine/replica counts; plus global invariants after every test | one share-manager pod, unchanged UID and restarts, Running throughout; all objects named after the PV; Herdr and other volumes unchanged | PASS if stable at every checkpoint and invariants hold | `observe/*.json` | REQ-009, FIND-063, H-RWX-12 |
| R14 | Guarded cleanup and verification | section 7; then read-only verify, **tri-state (PRESENT / ABSENT / UNKNOWN)**: namespace, PVC, PV, Longhorn volume, ShareManager CR, share-manager pod (exact name and selector), Service, VolumeAttachments (300 s budget; the last poll decides); Herdr UID/restarts and other volumes unchanged | all eight ABSENT; PV removed by reclaim `Delete` | PASS only if every item is positively ABSENT (clear NotFound or a valid empty list) and invariants hold. Any PRESENT object or failed/timed-out delete = RESIDUE (exit 5); any UNKNOWN (Forbidden, refused, 5xx, timeout, empty/malformed output, wrong schema) = UNVERIFIED (exit 6); both are reported and **nothing is deleted by the harness** | `cleanup/plan.txt`, `cleanup/verify.json` (per-item state and reason, unknown list), `cleanup/residue.json` | FIND-062, H-RWX-12 |

Estimated wall time for the full run: 30-60 minutes (R03 `stat` mode and R11 dominate).
Volume budget: three source repos and clones are well under 100 MiB of the 1 GiB; the harness stops at 85 % usage.

### 4.1 Research-informed predictions (from [RESEARCH.md](RESEARCH.md); predictions, not observations)

- Longhorn's share-manager chmods the export root `0777 root:root` with `Squash=None`, so UID 1000 writes are *likely* fine (R02). Longhorn issue #10621
  (nfs-ganesha regression) saw non-root `git clone` onto RWX fail while other operations worked; whether it affects the 1.13 ganesha build is unknown, hence the R02 git smoke step.
- The Linux NFS client returns `EINVAL` for any `renameat2` flag, and `rename(2)` onto a non-empty directory fails `ENOTEMPTY`/`EEXIST`. An **empty target directory must never be pre-created**
  (rename would replace it silently). `request-repo`'s `rename-fallback` (`lexists(target)` then `os.rename`, under the per-repo `flock`) therefore rests on the lock alone.
- `flock` is emulated by NFSv4 byte-range locks; after an unreclaimed share-manager restart locks are lost or I/O errors occur, so `flock` alone should not be the only promotion guard in production (documentation point; failover is **not** tested).
- Concurrent opens of one file over NFSv4.1 can hang in D state (Longhorn #11907/#12478, nfs-ganesha #1327): the reason for the hang stop condition and for keeping scratch pods off the Herdr node.
- Promotion by rename breaks linked worktrees' absolute gitdir paths unless `git worktree repair` is run: create worktrees after promotion at the final path (R09 INFO sub-step).

### 4.2 Preflight observations

The read-only preflight performed before this plan is recorded in [PREFLIGHT.md](PREFLIGHT.md). Summary used here: Longhorn v1.13.0 on three Talos nodes, CSIDriver `fsGroupPolicy=ReadWriteOnceWithFSType`,
`rwx-volume-fast-failover=false` (90 s NFS grace), no existing ShareManagers or Longhorn RWX volumes, a kubeconfig without a current context and with more than one Longhorn cluster (hence the identity guard), and a tuppr
upgrade controller with a 07:00Z daily window followed on 2026-11-19 by node restarts at 07:16-07:48Z (hence the maintenance-window guard). R00 takes a fresh baseline at execution.

## 5. Safe creation sequence

Nothing below happens without `--execute --confirm-run-id <id>`.

1. `rwx plan` (offline): review inventory, manifests and matrix.
2. `rwx preflight --live` (read-only): R00 with `KCTX` set explicitly (the kubeconfig has no current context). Checks the maintenance window, node health, `Completed` upgrade CRs, and the **cluster identity guard** (Longhorn manager tag, Herdr namespace/pod). Any failed precondition ends here; nothing is created.
3. Validate rendered manifests (labels, namespace, allowed kinds) in the harness, before each `kubectl apply -f -`.
4. Apply Namespace (labelled, PSA `restricted`). From this point the run is "created" and any stop triggers collect + cleanup.
5. NetworkPolicy `default-deny-all` (default on; `--no-network-policy` opts out).
6. Apply PVC; wait Bound (120 s). On timeout: collect events and describe output, STOP.
7. Apply pod A; wait Ready (300 s); wait for the Longhorn-created share-manager pod to be Running (180 s).
8. Apply pod B (anti-affinity forces another node); wait Ready; assert different nodes (STOP if equal or Pending). Both pods are also kept off the Herdr node by the second anti-affinity term.
9. R02 gate (write gate plus git smoke; STOP on failure), then R03-R13. Before and after every test: maintenance window, node health, upgrade CRs, scratch containers (running, 0 restarts), Herdr UID/restarts, other Longhorn volumes, disk usage.
10. Collect final snapshot, guarded cleanup, verification (R14).

## 6. Commands (for the owner; none have been run; run id `20261120a` is provisional, see D-3)

```text
rwx plan --run-id 20261120a                                    # offline
KCTX=<ctx> rwx preflight --run-id 20261120a --live              # read-only
KCTX=<ctx> rwx run --run-id 20261120a --execute --confirm-run-id 20261120a
KCTX=<ctx> rwx cleanup --run-id 20261120a --live                # dry-run plan
KCTX=<ctx> rwx cleanup --run-id 20261120a --execute --confirm-run-id 20261120a
```

`rwx` is `experiments/exp-005-rwx/harness/rwx`. Without flags nothing is executed. Optional runtime-only environment:
`RWX_NODE_SELECTOR=key=value`, `RWX_REDACT_EXTRA=<cluster-name>,<domain>`, `HERDR_NS`, `HERDR_POD`, `RWX_EXPECT_LONGHORN` (default `v1.13.0`).
The kubeconfig has no current context and several clusters: `KCTX` is mandatory and is checked against the identity guard.

## 7. Guarded cleanup sequence

Dry-run by default; real execution needs `--execute --confirm-run-id <same id>`. The planning code that prints the commands is the same code that
runs them (lesson from EXP-005's cleanup defect).

1. Read the Namespace; require `herdrnetes.io/experiment=exp-005-rwx`, `herdrnetes.io/run-id=<id>` and the exact name `herdrnetes-exp005-rwx-<id>`. Otherwise **refuse**.
2. List namespaced objects. **Refuse** (delete nothing) if any object lacks both labels, carries another run-id, or is not a Pod, PVC or NetworkPolicy (system `default` ServiceAccount and `kube-root-ca.crt` excepted).
3. Print the plan and every command.
4. For each Pod, then NetworkPolicy, then PVC: re-read the labels, then `kubectl delete <kind> <name> --wait=true --timeout=120s`. No `--force`, `--grace-period`, `--now`, `--all`, selector or cascade options exist in the allow-list.
5. Delete the Namespace (labels re-read first).
6. Read-only verification, polling for up to 300 s, **fail closed with a tri-state per object**: ABSENT only for a clear `Error from server (NotFound)` on a single-object get or a well-formed empty list from a known-correct query; PRESENT for a match; UNKNOWN for everything else (Forbidden, connection refused, 5xx, "server doesn't have a resource type", timeout, empty stdout, malformed/truncated JSON, wrong kind/schema). Objects: namespace, PVC, PV (list by claimRef and exact name), Longhorn volume (list by namespace and exact name), ShareManager CR, share-manager pod (exact name `share-manager-<pv>` and `longhorn.io/share-manager=<pv>` selector), Service, VolumeAttachments. The PV name is taken from the PVC before deletion (or `--pv-name pvc-<uuid>` from earlier evidence for a standalone run); without a known name the share-manager objects are UNKNOWN. Live Herdr and unrelated volumes must be positively readable and unchanged. A polling pass never promotes an earlier or later UNKNOWN: the last pass decides.
7. Outcome and exit code: all ABSENT and invariants hold = clean (0); any PRESENT object, or a delete that failed or timed out = **RESIDUE (5)**; no PRESENT but any UNKNOWN = **UNVERIFIED (6)**; refused by the label/kind guard = 4; clean but Herdr or an unrelated volume changed = 7. Evidence (`cleanup/verify.json`) lists every item's state and reason and which items were unknown and why. PVs, Longhorn objects and VolumeAttachments are never mutated by the harness; the owner decides what to do with residue.

## 8. Kubernetes security controls

| Control | Value |
| --- | --- |
| Pod Security | namespace `enforce/audit/warn=restricted` |
| Identity | `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000` (+ `OnRootMismatch`); whether it is applied to the RWX volume is **measured** (CSIDriver `fsGroupPolicy=ReadWriteOnceWithFSType` is expected to skip it) |
| Container | `allowPrivilegeEscalation: false`, `privileged: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault` |
| API access | `automountServiceAccountToken: false`, `enableServiceLinks: false`; no RBAC objects |
| Host | no `hostPath`, `hostNetwork`, `hostPID`, `hostIPC`, no `nodeName`; no init containers; no `chown` anywhere |
| Volumes | only the RWX PVC (`/rwx`) and an `emptyDir` (`/tmp`, 256Mi) |
| Resources | requests `cpu 50m`, `memory 64Mi`, `ephemeral-storage 64Mi`; limits `cpu 1`, `memory 512Mi`, `ephemeral-storage 512Mi` |
| Placement | two required `podAntiAffinity` terms on `kubernetes.io/hostname`: (1) among pods of this run, (2) against pods labelled `app.kubernetes.io/name=herdr` in namespace `HERDR_NS` (via `namespaceSelector` on `kubernetes.io/metadata.name`), to keep NFS-client hangs/mount issues away from the live Herdr node; optional runtime-only `RWX_NODE_SELECTOR`. Share-manager placement is Longhorn-controlled and may be the Herdr node (INFO) |
| Restart policy | `restartPolicy: Never`: a container restart must not mask a failure; the harness records restart counts at each checkpoint and stops if a scratch container terminates |
| Image | pinned by digest; no pull secrets; `imagePullPolicy: IfNotPresent` |
| Network | default-deny (ingress and egress) NetworkPolicy applied by default; the tests need no pod network; no credentials exist in the namespace |
| Harness | mutation allow-list (apply of own manifests; graceful delete of named Pod/PVC/NetworkPolicy; delete of the scratch Namespace); label guard before every delete; reads refuse Secrets; `exec` only into `rwx-a`/`rwx-b`; no `--dry-run=server`; no `--force`/`--grace-period`/finalizer edits exist in the allow-list |

## 9. Stop conditions (mandatory)

On any of these the harness records the reason, collects sanitized evidence, runs the guarded cleanup and exits 3 (4 if cleanup refuses, 5 on residue). It **never** responds by
escalating privileges, running a root or unrestricted container, adding a chown init container, relaxing PSA, or changing Longhorn or StorageClass settings.

1. R02 gate: UID 1000 cannot create/write/fsync/rename/mkdir/symlink/unlink at the mount root, **or the git smoke (init, `git clone file://`, commit, fsck) fails** (Longhorn #10621; stderr recorded), the caller is not uid/gid 1000, root or created-file ownership is unexpected.
2. Live Herdr pod UID or any container restart count differs from the baseline taken in R00.
3. Any Longhorn volume other than the scratch volume becomes `degraded` or `faulted` (other robustness changes are recorded as INFO; see open question 5).
4. Share-manager pod not Running within 180 s of pod A being Ready.
5. The two pods are on the same node, or pod B stays Pending.
6. PVC not Bound within 120 s; a pod not Ready within 300 s.
7. Any operation would touch an object lacking `herdrnetes.io/run-id=<id>` or `experiment=exp-005-rwx`, or in a different namespace (the guard raises `Refused`).
8. Preflight preconditions fail (missing class, wrong provisioner, reclaim policy not `Delete`, unhealthy Longhorn volumes or system pods, namespace already exists, Herdr baseline unreadable, fewer than two Ready/schedulable/untainted nodes **excluding the Herdr node**).
9. Volume usage reaches 85 %.
10. Cleanup refuses (unexpected or unlabelled objects): nothing is deleted and the owner is told.
11. **Cluster identity mismatch (R00):** `longhorn-manager` image tag differs from the expected value (`RWX_EXPECT_LONGHORN`, default `v1.13.0`, recorded), the `HERDR_NS` namespace is missing, or the number of pods labelled `app.kubernetes.io/name=herdr` is not exactly one (or it is not StatefulSet-owned).
12. **Maintenance window:** UTC time within 06:30-10:30, or any tuppr `TalosUpgrade`/`KubernetesUpgrade` CR whose phase is not `Completed` (an empty or missing phase is unknown, not idle), or any node NotReady or cordoned. CRDs are found by listing CRDs. Both expected CRDs (`talosupgrade`, `kubernetesupgrade`) must appear in a successfully read list, and each must list at least one object (both exist in PREFLIGHT.md); a missing CRD, an empty CR list or an unreadable CRD/CR list is "upgrade controller state unavailable" and stops. Evaluated in R00 and before and after every test.
13. **Suspected NFS I/O hang:** any `kubectl exec`/probe timeout, a probe process left running after its timeout, a lock holder that does not report, or a pod still Terminating after the delete timeout. No further tests run; evidence is collected (pod describe/events, share-manager state, read-only); graceful cleanup is attempted. If a pod or PVC remains Terminating after the delete timeout the harness reports **residue** to the owner (exit 5): it never uses `--force` or `--grace-period=0` and never edits finalizers.
14. **Scratch container terminated or restarted** (`restartPolicy: Never`), or a scratch pod leaves `Running`.
15. **Fail-closed reads (owner decision D-5):** any required read in R00 or between tests (Longhorn volume/node/pod/setting inventories, StorageClass, CSIDriver, node list, CRD and CR lists, Herdr baseline, scratch pods, disk usage, share-manager observations) that returns an error, timeout, empty/malformed output or an unexpected schema, or an empty Longhorn volume inventory where volumes existed at baseline. Nothing unreadable is ever treated as healthy, empty, unchanged or idle.
16. **R02 positive gate failure** on either pod (not NFSv4/4.1+, wrong identity or security, non-root git smoke failed, probe output unparseable): R03-R14 never start.

## 10. Expected Longhorn share-manager side effects

Longhorn selects RWX from the PVC access mode. When pod A first attaches the volume, Longhorn (not this harness) creates, in `longhorn-system`:
a ShareManager CR named after the volume, a share-manager pod (`share-manager-<pv>`) that mounts the volume and exports it over NFS, and a Service
(plus Endpoints/EndpointSlice) named after the volume; the pods mount the export via the CSI driver on their nodes. They disappear when the volume is
detached or deleted. We only `get` them, by exact name or `longhorn.io/share-manager=<pv>`. The harness records: share-manager UID, phase, restart count and node
alias at every checkpoint, so a share-manager restart or reschedule during the run would be visible (and fails R13). Placement of the share-manager relative to the pods is recorded as INFO
(it may share a node with a pod, **including the Herdr node**, because Longhorn, not Kubernetes scheduling of our pods, decides; that is not a stop condition). R13 also records the share-manager image tag/imageID and the replica node aliases. Documentation-level behaviour (failover grace periods, `rwx-volume-fast-failover`) is **not** tested: it
stays a documentation/inference item from the Longhorn 1.13 docs, not observed evidence.

## 11. Evidence and sanitization

Written under `experiments/exp-005-rwx/evidence/<run-id>/` only at execution time (nothing exists now). Raw text is sanitized in memory and scanned before it is
written; a file that still matches a leak pattern is replaced by `<name>.WITHHELD` (reasons only). The sanitizer:

- node names (read from the cluster at run time) become `<node-N>`; the alias map is kept outside the repository (`$XDG_STATE_HOME/herdrnetes-exp005-rwx/`);
- IPv4/IPv6, MAC addresses, API server URLs, internal domains (`.local .internal .lan .home .corp .intranet .localdomain`), the kube context name, `/home/<user>`, and any literal in `RWX_REDACT_EXTRA` (cluster name, domain) are replaced;
- bearer tokens, `token=`/`password=`/`secret=` values, JWTs, GitHub/GitLab/AWS-style tokens and private-key blocks are replaced.

Layout: `preflight.json`, `results.tsv`, `timings.tsv`, `summary.json`, `commands.txt`, `raw/`, `observe/`, `collect-*/`, `cleanup/`.
Every result row cites the exact digest, git/python versions (R02 `identity`), kernel, Kubernetes and Longhorn versions (R00). Results are then summarised in a new
`RESULTS.md` with `[cluster]`/`[docs]`/`[inferred]` tags; new findings would be `FIND-066+` proposed for owner review.

## 12. Out of scope (follow-ups, not approved)

Forced share-manager deletion or restart; node drain or outage; network or storage fault injection; force-deleting pods; changing `rwx-volume-fast-failover` or any Longhorn
setting; a StorageClass with `nfsOptions`/`migratable`; failover grace-period (90 s / 30 s) measurement; RWO control PVC; real or private repositories; network repository sources; the
live Herdr pod. Propose separately with a disruption and rollback assessment if the results justify it.

## 13. Mapping to the issue #32 sketch, and deviations

The issue comment lists the drafted tests as: provisioning; two pods on different nodes; cross-node hydration visibility delay; repeat and 4+4 concurrent `request-repo`;
cross-node `flock`; `renameat2(RENAME_NOREPLACE)`; `O_EXCL` and `index.lock` races; worktree use across nodes; mmap/fsync; small-file git timings; ordinary pod delete/recreate;
share-manager lifecycle read-only; guarded cleanup. It does not number them, except that R01 is the provisioning gate and R02 the write gate. This plan numbers them as above (R00 preflight added).
Deviations, for owner review:

1. Namespace is `herdrnetes-exp005-rwx-<run-id>` (per the preparation brief) rather than the `herdrnetes-rwx032` mentioned in the issue comment.
2. Repeat and concurrent hydration are split into R04 (sequential hand-off, repeat) and R05 (4+4 concurrency); "hydration visibility delay" is measured inside R04 (source visibility) and R03 (ping-pong).
3. The `O_EXCL` race is grouped with the same-repo Git race (R08); `mmap/fsync` are grouped with other POSIX edges (R10).
4. The comparison with RWO ext4 is against an **emptyDir control** only: no RWO control PVC (one PVC approved) and EXP-005 holds no small-file timings.
5. Namespaced default-deny NetworkPolicy, now enabled by default (owner decision D-2).
6. Disk-usage (85 %) and Longhorn-volume invariants added as stop conditions (conditions in the brief).
7. Opus review additions: cluster identity guard, Herdr-node exclusion, maintenance-window and node-health guards, hang handling with residue reporting, git-clone smoke in the R02 gate, `restartPolicy: Never`, non-empty-dir rename probe, optional worktree-repair sub-step, share-manager image and replica nodes in R13.

## 14. Open questions for the owner (still open)

Resolved by the PR #35 review and moved to "Owner decisions recorded" above: image, NetworkPolicy, run id, negative-result policy, robustness rule, pause hook, evidence retention, volume/time budget.

1. **Execution date and time window** (D-3, D-9): not approved. It must be outside 06:30-10:30 UTC (the guard window: tuppr starts at 07:00Z and runs up to 3 h, see PREFLIGHT.md) and outside any observed maintenance; it will follow review of the corrected code.
2. **Guard window width:** D-9 names 06:30-08:30 UTC. The harness keeps the **stricter 06:30-10:30 UTC** guard (a superset of D-9) because PREFLIGHT.md records a 3 h tuppr maintenance window (`0 2 * * *` local = 07:00Z in November), which ends at 10:00Z, plus 30 minutes margin on each side. It only narrows when a run may start; say if D-9's shorter window should be used instead.
3. **Upgrade-CR vocabulary** (D-10): only `Completed` is treated as idle (the one value observed in PREFLIGHT.md); an empty, missing or any other phase blocks. Both `talosupgrade` and `kubernetesupgrade` CRDs must be present in a successfully read CRD list and each must list at least one object (PREFLIGHT.md observed one `Completed` object of each); otherwise the state is "unavailable" and the run stops. Read-only preflight at execution records the phases actually observed; confirm that `Completed` is the complete idle vocabulary.
