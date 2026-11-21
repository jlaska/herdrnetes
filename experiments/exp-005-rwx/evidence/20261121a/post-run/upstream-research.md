# Upstream research: Longhorn RWX teardown EXT4/JBD2 errors (desk research, 2026-11-21)

Web/GitHub research only; no cluster contact. Tags: [issue] upstream tracker, [docs] Longhorn documentation, [inferred] reading of
source on the `master` branch (**not** verified against the v1.13.0 tag) or reasoning.

## Issues and PRs

- [issue, CLOSED, milestone v1.6.0, backports 1.4.4 / 1.5.2] longhorn/longhorn#6829 "IO error occurs when detaching RWX volume"
  <https://github.com/longhorn/longhorn/issues/6829>. Same signature (`Buffer I/O error ... lost sync page write`, `JBD2: Error -5 ...
  updating journal superblock`, `Aborting journal`), affected 1.3.3/1.4.3/1.5.1. Maintainer diagnosis: "volume engine is deleted before
  cleaning up the share-manager pod". Fix: longhorn-manager PR #2194 <https://github.com/longhorn/longhorn-manager/pull/2194> and
  share-manager PR #85 <https://github.com/longhorn/longhorn-share-manager/pull/85> (both merged 2023-10-05) add an `Unmount` gRPC
  (unexport + unmount) before the share-manager is detached.
- [issue, OPEN, Backlog] longhorn/longhorn#5717 "Improve manageability of share manager pod behaviors"
  <https://github.com/longhorn/longhorn/issues/5717>: proposes shutdown NFS -> unmount -> device teardown; deferred.
- [issue, CLOSED v1.6.0] longhorn/longhorn#5961 <https://github.com/longhorn/longhorn/issues/5961>: share-manager on a read-only mount
  (different cause, similar ext4 read-only symptom).
- No issue found for the literal strings "Couldn't clean up the journal" or "device offline" in an RWX teardown context; the v1.11.0,
  v1.11.1, v1.12.0 and v1.13.0 release notes mention nothing about unmount/journal ordering. Searches: GitHub issue search
  (`gh`/REST) and web search for "Couldn't clean up the journal", "device offline", lazy umount, share-manager unmount,
  aborting journal, RWX detach journal.

## Teardown sequence (source reading, `master`, [inferred])

- `share_manager_controller.go` `syncShareManagerVolume`: when the share-manager is no longer required it calls
  `unmountShareManagerVolume` (best-effort RPC), then removes the attachment ticket (detach), then sets state Stopping.
- When the Volume CR has a deletionTimestamp, `volume_controller.go` calls `DeleteShareManager` directly; the share-manager deletion
  path (`cleanupShareManagerPod`) deletes the pod and does not wait for the Unmount RPC. The #6829 ordering fix therefore does not
  appear to cover **volume deletion**: engine teardown can race the share-manager's unmount.
- share-manager on SIGTERM: context cancel -> ganesha exit -> deferred plain (non-lazy) `UnmountVolume`. No `preStop` and no
  non-default `terminationGracePeriodSeconds` seen in the pod spec builder.

## Docs

- [docs] RWX volumes <https://longhorn.io/docs/1.11.1/nodes-and-volumes/volumes/rwx-volumes>: no teardown ordering or
  scale-to-zero semantics described; abnormal share-manager termination "may result in ... data loss" (general statement).

## Implications ([inferred])

- With reclaim `Delete` the data is discarded, so the journal error is likely benign for this run.
- For an RWX volume that is only **detached** (scale to zero) and later reattached, the graceful path (Unmount RPC before detach,
  #6829) should leave ext4 clean; a racing or forced stop could lose unflushed writes and require journal replay. Not measured.
