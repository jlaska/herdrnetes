# Teardown timeline: Longhorn RWX volume pvc-99f1fb06 (EXP-005-rwx), 2026-11-21 UTC

Source: Loki (via lq.py helper), read-only. Node aliases: <node-1> = rwx-b node, <node-2> = share-manager / engine / rwx-a node, <node-3> = third node. PVC = pvc-99f1fb06-bb34-4170-8c35-b10ba31713fd. All times UTC, ms precision, from the log line's own container/process timestamp unless marked "ingest".

## 0. Timestamp caveat (important)

Kernel lines shipped by Talos carry an embedded timestamp that LAGS the Loki ingest time and the container clocks by a varying 1.6-2.6 s (sawtooth, seen on every kernel line from 18:30 on, e.g. 1.75-1.99 s on EDID lines at 18:47:25-27, 2.59 s on the EXT4 burst). The embedded 18:47:26.22 therefore cannot be placed on the same axis as the container logs.
Independent calibration at mount time: share-manager logged mkfs done at 17:20:36.847 and the kernel "EXT4-fs (sdz): mounted filesystem" line has embedded 17:20:34.389 (before mkfs even started) but Loki ingest 17:20:36.879. So the embedded stamp is early by ~2.5 s there too.
Bound for the unmount burst: kernel message "comm umount" must be at or after share-manager's "Unmounting volume" (18:47:28.684) and cannot be after its own Loki ingest (18:47:28.812; the whole 16-line burst has the identical ingest ms, i.e. one batch). So real time of the EXT4 error burst is in [18:47:28.684, 18:47:28.812] [inferred from bounds; the exact position inside that 128 ms window is not recoverable]. The embedded 18:47:26.22 is NOT used below.

## 1. Timeline (decisive lines only)

| UTC time | Node | Component | Event |
|---|---|---|---|
| 18:47:17.972 | <node-2> | longhorn-csi-plugin | NodeUnpublishVolume (rwx-a pod); unmounted 17.982 |
| 18:47:18.076-.198 | <node-2> | longhorn-csi-plugin | NodeUnstageVolume; NFS globalmount unmounted 18.198 (kubelet UnmountDevice succeeded 18.199) |
| 18:47:18.184 | <node-2> | share-manager (ganesha) | NFS client of <node-2> removed from recovery backend |
| 18:47:20.642-21.034 | <node-1> | longhorn-csi-plugin | NodeUnpublishVolume (20.642/20.662); NodeUnstageVolume (20.748); globalmount unmounted 21.034 |
| 18:47:21.018 | <node-2> | share-manager (ganesha) | NFS client of <node-1> removed; last NFS client gone |
| 18:47:21.657-24.659 | <node-1> | csi-provisioner | DeleteVolume attempts fail 3x: "persistentvolume ... is still attached to node <node-1>" (K8s VolumeAttachment still present) |
| 18:47:25.337 | <node-1> | csi controller | ControllerUnpublishVolume node-1; longhorn-manager detach POST 25.454 |
| 18:47:26.048 | <node-1> | csi controller | ControllerUnpublishVolume node-2; detach POST 26.067 |
| 18:47:28.659 | <node-1> | csi controller | DeleteVolume (PV reclaim Delete) |
| 18:47:28.682 | <node-3> | longhorn-manager | "Deleted volume PVC" (API DELETE /v1/volumes/PVC) -- TRIGGER |
| 18:47:28.683 | <node-2> | longhorn-manager (share-manager ctrl) | "Unmounting volume in share manager pod" (state=running) |
| 18:47:28.683 / .684 | <node-2> | share-manager | "Unexporting volume" / "Unmounting volume" (ganesha SIGHUP export reload, VFS unclaim .725) -- umount of ext4 STARTS |
| 18:47:28.694 | <node-2> | longhorn-manager (volume ctrl) | "Removing share manager for deleted volume" (volume state=attached, shareState=running) |
| 18:47:28.716 | <node-2> | longhorn-manager (engine ctrl) | "Deleting engine instance" PVC-e-0 -- ENGINE DELETE issued 32 ms after umount began, share-manager had not finished |
| 18:47:28.717-.718 | <node-2> | instance-manager | InstanceDelete; "trying to stop process PVC-e-0"; engine gets SIGINT ("Received signal interrupt to shutdown") |
| 18:47:28.728 / .737 / .753 | <node-2>/<node-1>/<node-3> | longhorn-manager + instance-manager | all 3 replica processes deleted/SIGINT in parallel (cleanupRequired=true) |
| 18:47:28.732-.756 | <node-2> | instance-manager [engine] | "Error reading from wire ...: EOF" x4 (replica data connections gone) |
| 18:47:28.743 | <node-2> | instance-manager (engine process, iscsidev.LogoutTarget) | "Shutting down iSCSI device for target iqn...:PVC" -- initiator-side iSCSI logout on <node-2> |
| 18:47:28.779 | <node-1> | csi-attacher | PV finalizer removed |
| 18:47:28.812 | <node-2> | kernel (ingest time) | burst: "EXT4-fs (sdz): unmounting filesystem", "device offline error, dev sdz ... WRITE", "Buffer I/O error", "JBD2: I/O error ... sdz-8", "Aborting journal", "ext4_put_super:1312: comm umount: Couldn't clean up the journal", "Remounting filesystem read-only" (embedded stamp 18:47:26.22 is skewed, see section 0) |
| 18:47:28.820 | <node-2> | share-manager | "Volume is unexported and unmounted" (umount call returned; no error logged) |
| 18:47:28.820 | <node-2> | longhorn-manager (share-manager ctrl) | "Removing volume attachment ticket: share-manager-controller-PVC to detach the volume"; "Stopping share manager since it is no longer required" -- the NORMAL detach path, now moot because engine is already being deleted |
| 18:47:28.825 | <node-2> | longhorn-manager | "Deleting share manager pod" |
| 18:47:28.845 | <node-2> | share-manager | "received signal terminated" (SIGTERM); "NFS server is shutting down" |
| 18:47:28.864 | <node-2> | share-manager | "NFS server exited with error ... signal: killed" |
| 18:47:28.939 | <node-2> | ext-iscsid (ingest time) | "Connection34:0 to [target: iqn...:PVC ...] is shutdown." (no embedded timestamp) |
| 18:47:28.963 | <node-2> | instance-manager [engine] | "Shutting down iSCSI target iqn...:PVC" (target-side) |
| 18:47:28.965-.971 | <node-2> | instance-manager [engine] | "Failed to write ... use of closed network connection"; "iSCSI device /dev/longhorn/PVC shutdown"; ERROR "Error when shutting down backend ... failed to close replica ...: connection refused" (replicas already dead) |
| 18:47:28.978-29.018 | <node-2> | instance-manager | engine process exit status 1, state=error, unregistered |
| 18:47:30.376 | <node-2> | longhorn-manager | "Stopping monitoring because the engine no longer exists" |
| 18:47:30.683 | <node-1> | csi-plugin | "Volume PVC does not exist" |

(Not shown: pod/NetworkPolicy deletes by the harness; kubelet-level kill of the share-manager pod containers not separately captured.)

## 2. Conclusion

[log-observed]
- Both NFS clients unmounted cleanly and FIRST: <node-2> NodeUnpublish 17.972 / NodeUnstage 18.198; <node-1> NodeUnpublish 20.642 / NodeUnstage 21.034. Ganesha removed both clients (18.184, 21.018). No client was still mounted when the ext4 error occurred.
- Sequence that matters: Longhorn volume DELETE (28.682) -> share-manager unmount started (28.684) -> engine instance delete issued (28.716) -> engine SIGINT (28.718) -> replicas killed (28.728-.753, engine sees EOF 28.732) -> engine-side iSCSI LogoutTarget (28.743) -> kernel EXT4 burst (ingest 28.812) -> share-manager reports unmounted (28.820) -> share-manager ticket detach + pod delete (28.820/.825) -> SIGTERM to share-manager (28.845) -> iscsid session shutdown (ingest 28.939) -> iSCSI target shutdown (28.963).
- The engine delete and the share-manager unmount were issued by two different Longhorn controllers (share-manager controller vs volume/engine controller) on the same longhorn-manager within 33 ms of each other, both as a reaction to the volume DELETE. The share-manager's own "detach ticket" step (the normal ordered path) only ran at 28.820, i.e. after the engine was already being torn down.
- The kernel reported "device offline" on sdz for the journal-superblock write during the umount, and the replicas/engine were already stopped at that moment.

[inferred]
- Yes, this is an ordering race: the block device (engine + iSCSI session) went away while share-manager's ext4 umount was still flushing the journal. The initiator was Longhorn itself, not Kubernetes/kubelet and not the share-manager: the volume controller's "Removing share manager for deleted volume" + engine DeleteInstance path ran concurrently with, instead of after, the share-manager unmount. Trigger chain: harness PVC delete -> PV (reclaim Delete) -> external-provisioner CSI DeleteVolume (28.659) -> longhorn-manager Delete (28.682). The K8s-side gate (VolumeAttachment for node-1/node-2 cleared at 25.3/26.0) does not cover the share-manager's internal attachment ticket, so DeleteVolume was allowed while the volume was still attached and mounted by the share-manager pod. This mechanism is consistent with all lines but is an interpretation of log ordering, not proof from source code.
- Which exact event set sdz to "offline" (engine process kill / replica loss at 28.732, or the engine's iSCSI logout at 28.743) cannot be determined from the logs; both occur inside the same 128 ms window that contains the kernel burst, and the kernel timestamp skew prevents resolving order at that resolution.
- umount returned success to share-manager (28.820) despite the kernel "Couldn't clean up the journal"; ext4_put_super errors do not make umount fail. The fs was being destroyed (volume deletion with Delete reclaim), so the data-integrity impact is nil in this case, but the alert is a true positive for an ungraceful block-device removal, and the same ordering would matter on any RWX volume deleted while its share-manager is running (and potentially on other forced detach paths).
- The embedded kernel timestamp (18:47:26.22) that suggested the error preceded the DeleteVolume is an artifact of Talos kmsg timestamp lag, per section 0. If it were real there would be an unlogged umount at ~26.2 with no share-manager or longhorn-manager trace; no such evidence exists.

## 3. Was ext4 healthy before teardown?

[log-observed] Yes, as far as logs show.
- Attach 17:20:31: iSCSI session operational (ext-iscsid 17:20:33.522 ingest); kernel scsi host29 / sd 29:0:0:1 [sdz] 1.00 GiB attached (benign "Power-on or device reset occurred" at attach). Write cache disabled.
- 17:20:36: share-manager found no filesystem ("appears to be unformatted") and ran mkfs.ext4 (-F -m0), mounted (kernel: "mounted filesystem a229bc87-... r/w with ordered data mode", ingest 17:20:36.879), resized (no-op), started ganesha. So a fresh fs: no fsck, no journal recovery, no `needs_recovery` messages.
- 17:20-18:47: zero kernel lines for sdz other than the attach/mount lines (query for sdz|EXT4|JBD2|iscsi|scsi|Buffer I/O|offline over 17:15-19:00 on <node-2> returned only attach, mount, and the teardown burst).
- No share-manager or instance-manager errors during the run. Warnings only: benign start-up items (ganesha config WARN, dbus CRIT "dbus_bus_get failed", longhorn-manager "Failed to check if replica ... transitioned to mode RW ... cannot parse timestamp" at 17:20:40 on first start, "Recovering volume metafile" at replica creation, snapshot controller "volumeattachment not found" 17:20:06 before attach). At 18:26:29 ganesha logged 10x "could not get create_handle object error The file no longer exists" (stale NFS file handles from clients, INFO level, consistent with test deletes of files); and 18:44:38 a "No need for unmount not a mount point" info on <node-1>. None involve block-device errors.

## 4. Gaps

- Kernel timestamp skew (1.6-2.6 s, sawtooth) prevents fine ordering inside the 28.684-28.812 window; ext-iscsid lines have no embedded timestamp (only ingest time 28.939, which may lag the real event).
- No kernel `sd 29:0:0:1` removal / "Synchronizing SCSI cache" / session-teardown lines were found at teardown (kernel log set at that level appears unshipped or filtered), so the transition of sdz to "offline" is not directly logged.
- The share-manager's umount command result/duration is not logged beyond the 28.684 start and 28.820 completion; no log shows the kernel umount syscall time.
- Kubelet-level pod kill of the share-manager pod container (SIGTERM timing from kubelet) was not separately examined; SIGTERM is taken from share-manager's own log (28.845).
- Longhorn source was not consulted: the claim that the share-manager unmount and engine deletion are independent concurrent controllers is inferred from log ordering and controller names only.
- Not checked: whether the same race reproduces on a clean (non-delete) share-manager stop, or whether Longhorn's Delete of a volume with a running share-manager is a known/accepted behaviour (suggest checking upstream longhorn issues for "ext4_put_super" / RWX delete, and testing: scale workloads to 0, wait for share-manager pod to be gone, then delete the PVC, and compare kernel logs).
