# EXP-005-RWX results: run `20261121a` (issue #32)

**Executed** 2026-11-21, 17:20:06-18:47:34 UTC, at pinned commit `994071c0a6fcb412bceae7eb384d39f9615a54ac` (harness, manifests
and tests unchanged; this file and `evidence/` were added afterwards). Authorization:
[#32 comment 7066214683](https://github.com/jlaska/herdrnetes/issues/32#issuecomment-7066214683); D-A baseline amended by the
owner in session: [comment 7066394209](https://github.com/jlaska/herdrnetes/issues/32#issuecomment-7066394209); handoff:
[comment 7067604836](https://github.com/jlaska/herdrnetes/issues/32#issuecomment-7067604836).
[ADR-0001](../../docs/decisions/ADR-0001-trusted-mvp.md) is unchanged. All findings below are **proposals for owner review**,
not accepted. Tags: **[cluster]** observed in this run, **[docs]** documentation/upstream tracker, **[inferred]** reasoning.

Sanitized evidence: [`evidence/20261121a/`](evidence/20261121a/). Node names are `<node-N>`: `<node-1>` = pod `rwx-b`,
`<node-2>` = pod `rwx-a` **and** the share-manager, `<node-3>` = live Herdr (no scratch pod).

## Environment

Talos v1.14.6, kernel 6.18.63-talos, Kubernetes v1.36.6 (3 nodes); Longhorn v1.13.0 (share-manager
`longhornio/longhorn-share-manager:v1.13.0@sha256:53950f78b7af38b8a943c298cd3020622191a4661a13036f69d83c154cc8690d`), StorageClass
`longhorn` (3 replicas, dataEngine v1, ext4, reclaim `Delete`), CSIDriver `fsGroupPolicy=ReadWriteOnceWithFSType`,
`rwx-volume-fast-failover=false`. Scratch image
`ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277`; `request-repo`
sha256 `b1729a554579740e47c031fb1fd9bd2a9dd20c01fc950bf683c5ec470d71fa29`. Mount: `nfs4`, `vers=4.1`, no `ac*`/`lookupcache`/`noac`
options shown (client defaults apply) ([`raw/r02-mountinfo-*.json`](evidence/20261121a/raw/)).

## Preflight and safety

- R00 PASS twice (17:16Z standalone, [`preflight-standalone/`](evidence/20261121a/preflight-standalone/); 17:20:06Z in-run). Identity, nodes,
  upgrade CRs (`Completed`), class, CSIDriver, Herdr baseline (UID prefix `fe7cd780`, 0 restarts) all as required.
- **D-A deviation:** fresh inventory 72 attached/healthy + 8 detached/unknown (rehearsal: 70 + 10); 0 degraded/faulted, 0
  attached-unknown, 0 transitional. Owner amended the baseline in session. Unrelated Longhorn devices were attached and mounted on `<node-2>` shortly
  before R00 (5 GiB and 4 GiB at 17:09Z, 1 GiB at 17:14Z; [`post-run/kernel-d-a-context.txt`](evidence/20261121a/post-run/kernel-d-a-context.txt)) [cluster].
  Other workloads changing attachment is a plausible cause of the 70->72 shift [inferred]; the rehearsal did not record volume names, so which
  volumes changed is not established. The harness summary line reads "80 volumes healthy"; `preflight.json` correctly records `healthy: 72, unknown: 8`.
- An operator-side read-only watcher ([`operator/`](evidence/20261121a/operator/), not part of the harness) polled every 20 s from 17:19:50Z to 18:47:39Z: 0 alerts;
  the only non-baseline volume was the scratch volume.
- No harness stop condition fired. Exit code 1 = two R03 FAIL rows; cleanup rc 0.

## Result matrix (raw, unedited: [`results.tsv`](evidence/20261121a/results.tsv))

32 PASS, 2 FAIL, 26 INFO, 1 LIMITATION, 0 UNTESTED.

| ID | Result | Observed [cluster] |
| --- | --- | --- |
| R01 | PASS | PVC Bound 4.23 s; pod A Ready 35.5 s, share-manager Running 0.4 s later, pod B Ready 10.5 s; pods on `<node-2>`/`<node-1>`, not the Herdr node |
| R02 | PASS | both pods uid/gid 1000, NoNewPrivs, CapEff empty; `nfs4` `vers=4.1`, same export; UID-1000 write gate and non-root `git init/clone/commit/fsck` passed (Longhorn #10621 not reproduced); `fsGroup` not applied (root `0777` uid 0 gid 0) |
| R03 | 2 FAIL, 6 INFO/PASS | ~30 s visibility lag; see FIND-066 |
| R04 | PASS | B `hydrated` (`promotion=rename-fallback`, 4.8 s), A `already_ready`; 6 alternating commits visible on the other node in 0.18-0.25 s; heads agree; `fsck --strict` clean |
| R05 | PASS | 4+4 cross-node `request-repo`, with and without the 4 s pause: 1 `hydrated`, 7 `already_ready`, all rc 0, `attempts=1`; different repos hydrate independently; fsck clean |
| R06 | PASS | `flock` both directions and `fcntl` A->B: contender refused `EWOULDBLOCK` while held, acquired 10.4-10.7 s later when the 14 s holder exited |
| R07 | PASS | `RENAME_NOREPLACE` unsupported on both pods (`EINVAL` to absent targets, `EEXIST` to existing ones); emptyDir control supports it; plain `rename` onto a non-empty dir `ENOTEMPTY`; plain `rename` onto an **empty** dir replaced it; all hydrations used `rename-fallback` |
| R08 | PASS | same-repo concurrent commits: 24 ok, 25 `index.lock`, 1 nothing-to-commit; 26/26 commits present; fsck clean. `O_EXCL` over 300 names: 197/103, overlap 0, missing 0 |
| R09 | PASS | worktree add/list/status/commit/remove/prune consistent across pods; linked `.git` = absolute `gitdir: /rwx/...`; concurrent add rc 0/0; fsck clean. R09-move (INFO): parent rename broke the worktree (rc 128, `fatal: not a git repository`, the **pre-repair** stderr), `git worktree repair` rc 0, status rc 0 afterwards |
| R10 | PASS + INFO | mmap+msync identical cross-node; hardlink/symlink/`os.replace` ok; `user.*` xattr `ENOTSUP`; umask modes as expected, gid 1000; fsync 4 KiB median 2.9 ms (A) / 3.5 ms (B); **O_APPEND: 500 of 1000 lines survived** (FIND-067) |
| R11 | LIMITATION | see FIND-069 |
| R12 | PASS | graceful delete of `rwx-b` gone 1.6 s, its `flock` free for A immediately; recreated Ready 6.3 s (new UID); data sha equal; fsck clean before/after; UID-1000 gate passed on the new pod; A heartbeat max gap 0.22 s, 0 errors |
| R13 | PASS | one share-manager pod, UID/restarts unchanged, Running at 13 checkpoints; Service and ShareManager CR present; 1 engine, 3 replicas on 3 nodes |
| R14 | PASS (API) | all 8 objects positively ABSENT after 12.4 s; Herdr unchanged; re-verified independently at 18:48:16Z. **Kernel-level teardown was not clean** (FIND-070), which R14 cannot observe |

## Proposed findings and their limits

### FIND-066: ~30 s cross-node visibility lag for new and rewritten files (H-RWX-3 partly refuted)

- **Observed [cluster]** ([`raw/r03-*.json`](evidence/20261121a/raw/)), 20 iterations per mode and direction, 30 s per-iteration timeout (75 s for `stat`). Each
  RTT = ping becomes visible to the reader + pong becomes visible to the writer.

  | Mode | A->B (A writes, B on `<node-1>` reads) | B->A (B writes, A on the share-manager node reads) |
  | --- | --- | --- |
  | new name, `open` | 20/20 timeouts | 20/20 at 30.004-30.014 s |
  | new name, `listdir` | 20/20 at 30.003-30.012 s | 11/20 < 25 ms, 9/20 at ~30.01 s |
  | in-place rewrite, `open` | 19/20 at 29.99-30.01 s, 1 timeout | 5/20 < 1 s, 15/20 at ~30.0 s |
  | new name, `stat` | 1 at 30.01 s, 2/3 timeouts at 75 s | 3/3 timeouts at 75 s |

  Content mismatches: 0. Git operations were **not** affected: R04 commit visibility 0.18-0.25 s, R05/R06/R08/R12 cross-node results correct.
- **Interpretation:** for new names this is consistent with the Linux NFS client's negative-dentry / directory-attribute caching
  (default `acdirmin=30`, `lookupcache=all`) [inferred, docs: nfs(5)]. The in-place rewrite lag is **not** explained by client close-to-open
  semantics alone (re-open should revalidate) and may involve server-side (nfs-ganesha) attribute caching [inferred, unverified].
- **Limits:** one run, one cluster, n=20 per cell; the 30 s probe timeout coincides with the lag, so the two FAIL rows and their PASS
  counterparts are not meaningful as pass/fail and the true lag beyond 30 s (A->B open) is unknown; NFS cache parameters in effect were not read
  (`/proc/self/mountstats` not captured); the direction asymmetry (fast results only when the reader is on the share-manager node) is
  observed but its cause is not established; `stat` mode has n<=3. Why Git is unaffected is [inferred] (Git mostly re-reads existing paths
  under locks rather than polling for new names); not separately measured.
- **Implication for review:** do not rely on cross-pod polling for newly created files (e.g. readiness markers, mailbox files)
  on Longhorn RWX without explicit revalidation; Git hand-off is fine at observed latencies.

### FIND-067: concurrent `O_APPEND` from two NFS clients loses records

- **Observed [cluster]** ([`raw/r10-append.json`](evidence/20261121a/raw/r10-append.json)): A and B each appended 500 fixed-length 9-byte lines
  (`pa:NNNNN\n`, `pb:NNNNN\n`) to one file from a common start time, 0 write errors, fsync before close. Result: 500 lines, all `pa`, 0
  garbled, all 500 `pb` lines missing.
- **Interpretation:** each NFS client computes the append offset from its own view of the file size, so both writers wrote at the same
  offsets and one overwrote the other; the identical record length made the loss total and invisible as garbling [inferred]. open(2)
  documents that `O_APPEND` on NFS "may lead to corrupted files" with concurrent appenders [docs: open(2)].
- **Limits:** a single trial; which writer survives, and whether loss is total or partial with variable-length records or other timing, is
  not established. No lock was used (by design).
- **Implication:** shared append-only logs/journals across pods on RWX are unsafe without locking or per-writer files.

### FIND-068: `request-repo` always uses `rename-fallback` on RWX; correctness rests on the per-repo `flock`

- **Observed [cluster]:** `RENAME_NOREPLACE` unsupported on the NFS mount (R07); every R04/R05 hydration reported `promotion=rename-fallback`; the
  cross-node `flock` held and released correctly (R05: exactly one clone in 4+4 concurrency twice; R06 both directions); plain `rename` onto an
  empty directory replaced it silently (R07).
- **Limits:** lock correctness is shown only for graceful holder exit (R06, R12). Share-manager restart/failover (NFSv4 lock reclaim, 90 s grace
  with `rwx-volume-fast-failover=false`) was **out of scope and not tested**; behaviour there is [docs]/[inferred] only. Two nodes, one run.
- **Implication:** on RWX, `request-repo`'s promotion is only as safe as the NFS lock; a pre-created empty target would be silently replaced.

### FIND-069: small-file Git on RWX is one to two orders of magnitude slower than local emptyDir

- **Observed [cluster]** ([`r11-summary.json`](evidence/20261121a/r11-summary.json)), medians of 5 sequential runs, 3000 x ~1 KiB files:

  | Operation | RWX pod A (share-manager node) | RWX pod B | emptyDir (pod A) | A / emptyDir |
  | --- | --- | --- | --- | --- |
  | clone | 16.05 s | 42.00 s | 0.31 s | 52x |
  | checkout (all files) | 14.43 s | 31.21 s | 0.27 s | 53x |
  | status (clean) | 0.12 s | 0.26 s | 0.03 s | 3.7x |
  | fsck | 1.02 s | 5.94 s | 0.12 s | 8.4x |
  | create 3000 files | 10.76 s | 15.24 s | 0.11 s | 98x |
  | stat / read / delete 3000 | 0.22 / 0.42 / 0.73 s | 1.30 / 2.63 / 3.99 s | 0.006 / 0.031 / 0.041 s | 37x / 13x / 18x |

- **Limits (LIMITATION):** no RWO control (only one PVC approved) and EXP-005 recorded no small-file timings, so the RWX-vs-RWO gap is
  **not measured**; emptyDir is node-local ephemeral storage, a lower bound, not Longhorn ext4. Shared, busy homelab cluster; synthetic repos;
  one run. The A/B difference (B 1.4-6x slower) correlates with B not sharing a node with the share-manager [inferred; not isolated].

### FIND-070: Longhorn RWX volume deletion detaches the block device while the share-manager is still unmounting ext4

- **Observed [cluster]** ([`post-run/kernel-scratch-device.txt`](evidence/20261121a/post-run/kernel-scratch-device.txt),
  [`post-run/teardown-timeline.md`](evidence/20261121a/post-run/teardown-timeline.md)): during guarded cleanup the share-manager node `<node-2>` logged,
  for the scratch device (`sdz`, 1 GiB, attached 17:20:31Z, mounted by the share-manager after `mkfs.ext4` at 17:20:36Z):
  `EXT4-fs (sdz): unmounting filesystem` -> `device offline error ... WRITE` -> `Buffer I/O error ... lost sync page write` ->
  `JBD2: I/O error when updating journal superblock` -> `Aborting journal` -> `EXT4-fs error ... ext4_put_super ... comm umount: Couldn't clean up the journal`
  -> `Remounting filesystem read-only`. This fired the `NodeExt4FilesystemError` alert (critical).
- **Ordering [cluster, Loki container logs, ms]:** both NFS clients unmounted cleanly at 18:47:17.97 (`<node-2>`) and 18:47:20.64 (`<node-1>`);
  CSI `DeleteVolume` 28.659; longhorn-manager "Deleted volume" 28.682; share-manager "Unmounting volume" **28.684**; engine instance delete
  **28.716**; replicas killed 28.728-28.753; engine iSCSI logout 28.743; kernel error burst ingested 28.812; share-manager "unexported and
  unmounted" 28.820; share-manager pod deleted 28.825. Kernel embedded timestamps (18:47:26.22) run 1.6-2.6 s behind container logs on this
  node and are not used for ordering.
- **Interpretation:** an ordering race on the **volume-deletion** path: Longhorn's volume/engine controllers tore down the engine 32 ms after
  the share-manager began its ext4 unmount, without waiting for it [inferred from log order and controller names]. Longhorn #6829 (same
  JBD2 signature on RWX *detach*, fixed in v1.6.0 by an unmount-before-detach RPC) is the closest upstream match; a reading of
  longhorn-manager `master` suggests the deletion path bypasses that ordering [docs/issue + inferred; not verified against the v1.13.0 tag]
  ([`post-run/upstream-research.md`](evidence/20261121a/post-run/upstream-research.md)).
- **Health after the event [cluster]:** no further EXT4/JBD2/I/O/NFS kernel errors on any node 18:47:40Z-19:00Z; 7-day history shows no other
  EXT4/JBD2 errors (two earlier `device offline` READ errors on detach, 2026-11-19 and 2026-11-20); all nodes and Longhorn nodes/disks Ready;
  72/8 volumes; 0 ShareManagers; instance-managers 0 restarts; no Warning events; Herdr unchanged
  ([`post-run/health-1900Z.txt`](evidence/20261121a/post-run/health-1900Z.txt), [`post-run/kernel-errors-scan.txt`](evidence/20261121a/post-run/kernel-errors-scan.txt)).
  ext4 showed no error, recovery or fsck message between mount and teardown.
- **Impact:** none on surviving data: the filesystem belonged to a volume being deleted (reclaim `Delete`) [cluster]. The alert is a true
  kernel error but a **false positive for corruption of a live volume**.
- **Limits:** one occurrence, one teardown style (pods deleted, then PVC `--wait`, then namespace). Whether a plain **detach** (scale to zero,
  volume kept) races the same way, and whether that could lose unflushed writes, is **not tested** and is the open risk [inferred]. The
  exact kernel unmount instant within 28.684-28.812 and whether the engine kill or the iSCSI logout took the device offline cannot be
  resolved from the logs. No direct node access (mount table) was available for this cluster; health is inferred from API state and logs.
- **Harness gap:** R14 verifies API objects only; it cannot see kernel-level teardown errors. A future cleanup check could include a
  read-only kernel-log query for the share-manager node (proposal; pin unchanged).

## Hypotheses

| ID | Outcome |
| --- | --- |
| H-RWX-1 | supported (R00, R01) |
| H-RWX-2 | supported (R02); `fsGroup` not applied, root `0777` |
| H-RWX-3 | **partly refuted**: close-to-open data integrity held (0 mismatches, mmap ok), but visibility of new/rewritten files lags ~30 s (FIND-066); `O_APPEND` loss confirmed (FIND-067) |
| H-RWX-4 | supported (R04) |
| H-RWX-5 | supported (R05) |
| H-RWX-6 | supported (R06) |
| H-RWX-7 | supported, with mixed errnos (`EINVAL` to absent, `EEXIST` to existing targets) |
| H-RWX-8 | supported (R08) |
| H-RWX-9 | supported (R09); rename-then-repair behaviour confirmed (R09-move) |
| H-RWX-10 | measured (FIND-069), RWO gap not measured |
| H-RWX-11 | supported (R12) |
| H-RWX-12 | supported at API level (R13, R14); kernel-level teardown not clean (FIND-070) |

## Harness observations (not fixed; pin preserved)

- R00 summary wording "80 volumes healthy" (D-A: must not be reported that way).
- R03 per-iteration timeout (30 s) equals the observed lag; exec budget margin ~630/720 s per mode; `timeouts=w/r` label reads like a fraction.
- R02 summary says "NFSv4.1+" while the gate checks exactly `4.1` (the gate is correct).
- R09-move prints the pre-repair stderr next to the post-repair rc, which reads as ambiguous.
- Sanitizer redacts the public tuppr CRD group to `<internal-host>-operations.com` and labels a MAC as `<ip6>`.
- Herdr invariant compares UID/restart counts only; an in-container OOM kill would not be detected (an unrelated pod on the Herdr node hit memcg OOM at 17:24:40Z).

## Requirements and architecture implications (for owner review; no document changed)

- REQ-004/REQ-010: RWX supports the shared-repository Git workflows tested (hydration, locking, worktrees, recreation) with correct results,
  at a 1-2 orders of magnitude small-file performance cost and ~30 s new-file visibility lag across pods.
- REQ-009: RWX teardown on deletion is not kernel-clean in Longhorn v1.13.0 (FIND-070); detach-without-delete is untested.
- ADR-0001 (one shared RWO workspace PVC) is unaffected; nothing here proposes changing it.

## Follow-ups (not authorized)

1. R03 rerun with a >= 90 s timeout and `/proc/self/mountstats` capture, to measure the true lag and cache parameters.
2. Detach-without-delete teardown (scale to zero, wait for share-manager gone, then inspect kernel logs) to bound FIND-070's risk.
3. Upstream: consider reporting FIND-070 to Longhorn with the sanitized timeline.
4. Harness fixes listed above (require re-review and a new pin).
