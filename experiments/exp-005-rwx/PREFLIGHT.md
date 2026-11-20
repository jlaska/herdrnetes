# EXP-005-RWX read-only preflight (R00 dry inspection, 2026-11-20 UTC)

Note: Read-only kubectl inspection performed by a Haiku sub-agent. No resources were created, modified, or deleted; no exec, logs, or debug pods. Node names are aliased; contexts are aliased.

- Run start (UTC): 2026-11-20T02:11:59Z (first command). Last data collection about 02:40Z.
- Mode: read-only (`get`, `describe`, `version`, `api-resources`, `top`, `auth can-i --list` and `auth can-i` for checks only). No writes, no pods created, no exec/logs, no dry-run, no repo writes.
- Sanitization: cluster/context names, node hostnames, IPs, internal DNS names and URLs are replaced by aliases. Node aliases follow `kubectl get nodes` name order (node-1..node-3). Context alias `context-1` = the kubeconfig context for the expected cluster.
- Helper: every command ran through a read-only wrapper script (not included). It pins `--context` and allows only `get|describe|version|api-resources|top|auth can-i|config current-context|get-contexts`. The wrapper body names the context in the clear (scratch only, not in this report).

## Context selection

- `kubectl config current-context` exits 1: **no current-context is set** in `~/.kube/config`. A bare `kubectl` call falls back to `localhost:8080` and fails. Every check therefore used an explicit `--context`.
- Three contexts exist: `context-1`, `context-2`, `context-3`.
  - `context-1`: **matches the expected cluster**. Has namespace `herdrnetes-exp` (Herdr StatefulSet `herdr`), Longhorn v1.13.0, 3 Talos nodes, Kubernetes v1.36.6.
  - `context-2`: Longhorn v1.13.0 and 3 nodes, Kubernetes v1.36.6, but **no Herdr namespace**. Not used.
  - `context-3`: 1 node, **no Longhorn**, no Herdr namespace. Not used.
- Selection criterion: presence of the Herdr StatefulSet. The repo docs do not name a context.

## Commands run (sanitized; `K` = `kc.sh`, which expands to `kubectl --context <context-1>` plus the arguments shown)

| # | Command (args after `kubectl --context <context-1>`) | Item |
|---|---|---|
| 1 | `config current-context` (no context flag) | 1 |
| 2 | `config get-contexts -o name` | 1 |
| 3 | `version -o json` | 1 |
| 4 | `get nodes -o wide` and `get nodes -o json` (parsed locally) | 1, 6 |
| 5 | `get namespaces --show-labels` (failed on the bare call, re-run per context) and `get ns -l herdrnetes.io/experiment`, `get ns herdrnetes-exp005` (per context) | 9 |
| 6 | `get storageclass -o json` (parsed locally) | 3 |
| 7 | `get csidriver driver.longhorn.io -o json` | 4 |
| 8 | `-n longhorn-system get pods -o wide` and `-o json` (parsed locally) | 2 |
| 9 | `-n longhorn-system get deploy`, `get ds` (jsonpath image) | 2 |
| 10 | `-n longhorn-system get settings.longhorn.io -o json` (filtered locally), `get settings.longhorn.io current-longhorn-version` | 2, 5 |
| 11 | `-n longhorn-system get nodes.longhorn.io -o json` | 6 |
| 12 | `-n longhorn-system get volumes.longhorn.io`, `engines.longhorn.io`, `replicas.longhorn.io`, `sharemanagers.longhorn.io` (`-o json`, counted locally) | 7 |
| 13 | `get pods -o name` filtered for `share` in `longhorn-system` | 7 |
| 14 | `get pvc -A -o json` and `get pv -o json` (RWX filtered locally) | 7 |
| 15 | `-n longhorn-system get engineimages.longhorn.io -o json`, `get recurringjobs.longhorn.io` | 2, 8 |
| 16 | `-n herdrnetes-exp get ns`, `get sts herdr` (jsonpath), `get sts,pods -o wide`, `get pvc`, `get networkpolicy` (count), `get pod herdr-0 -o json` (parsed locally) | 8, 10 |
| 17 | `get events -A --field-selector type=Warning`, `-n herdrnetes-exp get events` | 2, 8 (warnings) |
| 18 | `top nodes` | 1 |
| 19 | `auth can-i --list -n herdrnetes-exp`; `auth can-i create namespace`; `auth can-i create persistentvolume`; `auth can-i patch storageclass` | informational (RBAC) |
| 20 | `api-resources` (filtered for `tuppr`, `upgrade`); `get talosupgrades,kubernetesupgrades.<tuppr-api-group> -o json` | 1, warnings |
| 21 | `get volumes.longhorn.io` joined to PVs locally to map unhealthy volumes to claims | 7, warnings |
| 22 | `-n <unrelated-ns-1> get pods`, `-n <unrelated-ns-2> get pods` | warnings |
| 23 | `-n longhorn-system get pod <weekly-trim pod> -o jsonpath` (lastState only; `describe` and `logs` not needed) | warnings |

## Observations

### 1. Cluster and nodes (context-1)

| Item | Value |
|---|---|
| Client version | v1.36.5 (linux/amd64) |
| Server version | v1.36.6 |
| Node count | 3 (all `control-plane` role labels, all Ready) |
| Kubelet | v1.36.6 on all three |
| OS / kernel / runtime | Talos v1.14.6; kernel 6.18.63-talos; containerd 2.3.7; amd64 |
| Taints | none on any node |
| Unschedulable / cordoned | none |
| Conditions (all nodes) | Ready=True; NetworkUnavailable=False; MemoryPressure=False; DiskPressure=False; PIDPressure=False |
| Ready since (UTC) | node-1 2026-11-19T07:16:01Z; node-3 2026-11-19T07:34:59Z; node-2 2026-11-19T07:48:41Z |
| Maintenance-looking labels/annotations on nodes | none |
| Capacity per node | 16 CPU; ~31.0 GiB RAM; ephemeral 497608304Ki |
| `kubectl top nodes` | node-1 10% CPU, 64% mem; node-2 14% CPU, 21% mem; node-3 6% CPU, 47% mem |
| Upgrade controller (tuppr) | TalosUpgrade and KubernetesUpgrade both `Completed` (Ready transition 2026-11-03T00:06:51Z). Both have maintenance window `0 2 * * *` (local time zone), duration 3h, parallelism 1 (see warnings). |

### 2. Longhorn version and health

| Item | Value |
|---|---|
| longhorn-manager image | `docker.io/longhornio/longhorn-manager:v1.13.0` (DaemonSet, 3 pods, all Running) |
| Engine image | `docker.io/longhornio/longhorn-engine:v1.13.0`; EngineImage `ei-2f3240cb` state `deployed` on 3 nodes |
| Instance manager | `docker.io/longhornio/longhorn-instance-manager:v1.13.0` (3 pods, Running) |
| Share-manager image | `docker.io/longhornio/longhorn-share-manager:v1.13.0` (pre-pulled by longhorn-manager init on all nodes) |
| CSI images | csi-attacher v4.13.0; csi-provisioner v6.3.0; csi-resizer v2.2.1; csi-snapshotter v8.6.0; csi-node-driver-registrar v2.18.0; livenessprobe v2.20.0 |
| UI | `docker.io/longhornio/longhorn-ui:v1.13.0` |
| `settings.current-longhorn-version` | `v1.13.0` |
| `settings.latest-longhorn-version` | `v1.12.1` (see warnings) |
| csi-plugin (3 DaemonSet pods) | 3/3 Running on each node |
| longhorn-driver-deployer / global-manager | 1 pod / 3 pods, all Running, 0 restarts |
| Pod restarts | longhorn-manager on node-3: 10 (last Completed, exit 0, finished 2026-11-19T07:33:32Z); its `pre-pull-share-manager-image` init: 8 (last Error, exit 137, finished 07:33:52Z); engine-image on node-3: 11 (last Error, exit 137, finished 07:33:52Z). No restarts on any other Longhorn pod except the weekly-trim job (below). |

### 3. StorageClasses

| Name | Provisioner | reclaimPolicy | volumeBindingMode | allowVolumeExpansion | default |
|---|---|---|---|---|---|
| `longhorn` | driver.longhorn.io | Delete | Immediate | true | **true** |
| `longhorn-static` | driver.longhorn.io | Delete | Immediate | true | - |
| `longhorn-unreplicated-besteffort` | driver.longhorn.io | Delete | WaitForFirstConsumer | true | false |
| `longhorn-unreplicated-strictlocal` | driver.longhorn.io | Delete | WaitForFirstConsumer | true | false |
| a NAS-backed NFS StorageClass (provisioner nfs.csi.k8s.io, reclaim Retain; not used) | nfs.csi.k8s.io | Retain | Immediate | not set | - |

`longhorn` parameters (full):

```
backupTargetName: default
dataEngine: v1
dataLocality: disabled
disableRevisionCounter: "true"
fromBackup: ""
fsType: ext4
numberOfReplicas: "3"
staleReplicaTimeout: "30"
unmapMarkSnapChainRemoved: ignored
```

No `nfsOptions`, `migratable`, or `diskSelector`/`nodeSelector` parameters are set on `longhorn`. Those are not listed, so their defaults apply.

### 4. CSIDriver `driver.longhorn.io`

| Field | Value |
|---|---|
| attachRequired | true |
| fsGroupPolicy | **ReadWriteOnceWithFSType** |
| podInfoOnMount | true |
| volumeLifecycleModes | [Persistent] |
| storageCapacity | false |
| requiresRepublish | false |
| seLinuxMount | false |

### 5. Longhorn settings relevant to RWX

| Setting | Value |
|---|---|
| rwx-volume-fast-failover | `false` |
| endpoint-network-for-rwx-volume | `""` (empty) |
| share-manager-related settings | **none exist** (no setting name contains `share-manager` or `nfs`) |
| storage-over-provisioning-percentage | `100` |
| storage-minimal-available-percentage | `20` |
| replica-soft-anti-affinity | `false` |
| replica-zone-soft-anti-affinity | `true` |
| replica-disk-soft-anti-affinity | `true` |
| node-down-pod-deletion-policy | `do-nothing` |
| default-replica-count | `{"v1":"3","v2":"3"}` |
| replica-auto-balance | `disabled` |
| auto-salvage | `true` |
| allow-live-engine-upgrade-on-same-image-commit | `false` |
| concurrent-automatic-engine-upgrade-per-node-limit | `0` |
| total settings | 120 |

### 6. Longhorn nodes (nodes.longhorn.io) and scratch headroom

All three nodes: `Ready=True`, `Schedulable=True`, `allowScheduling=True`, `evictionRequested=False`, disk type filesystem, default disk only.

Prerequisite conditions (all three nodes, all True):

- `RequiredPackages`: all required packages installed (`dmsetup`, `cryptsetup`, `nfs-common`, `iscsiadm`)
- `NFSClientInstalled`: True
- `Multipathd`: True
- `KernelModulesLoaded`: True (`dm_crypt`)
- `MountPropagation`: True

Disk capacity (GiB; `storageMaximum` = 474.56 on each node; `storageReserved` = 142.37 on each node):

| Node | storageAvailable | storageScheduled | Longhorn schedulable headroom (see formula) | Minimal-available floor (20% of max = 94.91) |
|---|---|---|---|---|
| node-1 | 258.50 | 268.29 | **63.90** | margin 163.6 |
| node-2 | 300.10 | 287.29 | **44.90** | margin 205.2 |
| node-3 | 247.27 | 289.29 | **42.90** | margin 152.4 |

Formula: headroom = (storageMaximum − storageReserved) × over-provisioning% − storageScheduled = 332.19 × 1.00 − scheduled. The binding limit is over-provisioning, not free disk.

Scratch need: a 1 GiB RWX-backing volume with 3 replicas = 3 GiB raw, one replica per node with `replica-soft-anti-affinity=false`. This fits easily. Minimum per-node headroom is about 42.9 GiB (node-3).

### 7. Longhorn volumes, engines, replicas, share managers, PVCs

| Item | Count / state |
|---|---|
| Volumes (volumes.longhorn.io) | 80 total. robustness/state: 70 healthy/attached; **10 unknown/detached** (see warnings). accessMode: all `rwo`. dataEngine: all `v1`. Replicas: 41 with 3, 39 with 1. |
| Engines | 80: 70 running, 10 stopped |
| Replicas | 162: 148 running (desired running); 14 stopped (desired stopped) |
| **ShareManager CRs (sharemanagers.longhorn.io)** | **0** |
| **share-manager-* pods** | **0** |
| PVCs cluster-wide | 99 total: 83 ReadWriteOnce; 16 ReadWriteMany |
| Existing RWX PVCs | 16, all in 14 unrelated namespaces. |
| Backing of existing RWX | **All 16 are static NFS PVs** (`driver: nfs.csi.k8s.io`, reclaimPolicy Retain). 15 are static with no StorageClass; 1 uses a NAS-backed NFS StorageClass (provisioner nfs.csi.k8s.io, reclaim Retain; not used). **None are Longhorn RWX** (no ShareManager CRs). |
| Longhorn PV reclaim | Delete: 63; Retain: 17 |

### 8. Live Herdr baseline (namespace `herdrnetes-exp`)

| Item | Value |
|---|---|
| Namespace | `herdrnetes-exp`, labels `app.kubernetes.io/name` and `part-of` = `herdrnetes-exp`; **Pod Security `enforce=restricted`, enforce-version=latest** |
| StatefulSet | `herdr`, replicas 1/1 ready, serviceName `herdr`, RollingUpdate, OrderedReady |
| Containers and images | `herdr`: `ghcr.io/jlaska/herdrnetes-herdr:exp002-h095-c311@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277` (imageID digest matches). `ovis`: `ghcr.io/jlaska/herdrnetes-ovis:exp003-o054-h095@sha256:8e31cc27ca866dc47f9cb0f519abce844db8a75974c5d147b91fdbcff46ef0db` |
| Pod name | `herdr-0` |
| Pod UID | `fe7cd780-06ae-4756-ad8e-d22deb410a38` |
| Node | node-3 |
| Pod created / startTime | 2026-11-19T07:45:51Z |
| Container start | herdr 2026-11-19T07:46:59Z; ovis 2026-11-19T07:47:55Z |
| Restart counts | **herdr: 0; ovis: 0**. No lastState on either. |
| Phase / QoS | Running / Burstable |
| Pod security context | runAsUser/Group 1000; runAsNonRoot; fsGroup 1000; fsGroupChangePolicy OnRootMismatch; seccomp RuntimeDefault |
| Container security context | readOnlyRootFilesystem=true; allowPrivilegeEscalation=false (both containers) |
| Tolerations / nodeSelector / affinity | 2 tolerations / none / none |
| PVCs | `home-herdr-0`: ReadWriteOnce, 5Gi, `longhorn`, Bound. `workspace-herdr-0`: ReadWriteOnce, 20Gi, `longhorn`, Bound. |
| Longhorn volumes for these PVCs | Both healthy, attached, 3 replicas, dataLocality disabled, not encrypted |
| NetworkPolicies in namespace | **1** |
| ns `herdrnetes-exp` events | none returned (event retention) |

### 9. Experiment namespace collision check

- `herdrnetes-exp005*` namespace in context-1: **not found** (NotFound).
- Namespaces labelled `herdrnetes.io/experiment` in context-1: **none**.
- Namespaces with prefix `herdrnetes-` in context-1: only `herdrnetes-exp` (the Herdr namespace above).
- Note: the existing namespace is named `herdrnetes-exp` (no `005`). The RESULTS.md text for EXP-005 says the scratch namespace is `herdrnetes-exp005`. This does not collide.

### 10. Pod Security and NetworkPolicy

- Herdr namespace PSA labels: `pod-security.kubernetes.io/enforce=restricted`, `enforce-version=latest`.
- NetworkPolicies in `herdrnetes-exp`: count **1**.

### 11. RBAC (namespace-scoped, informational)

- `auth can-i --list -n herdrnetes-exp`: `*.*` with verbs `[*]` (full access in the namespace). Non-resource URL `*` also.
- Cluster-scoped checks: `create namespace` yes; `create persistentvolume` yes; `patch storageclass` yes. The operator identity is cluster-admin-like. These checks were read-only and did not modify anything.

## Warnings / unexpected conditions

1. **No current-context in kubeconfig.** A bare `kubectl` fails against `localhost:8080`. Any future command must pass `--context` explicitly.
2. **Longhorn `latest-longhorn-version` = v1.12.1**, but the current version is v1.13.0. `stable-longhorn-versions` does not list v1.13.0. This is probably an upgrade-responder metadata lag. Informational only.
3. **Node-3 Longhorn restarts (longhorn-manager 10x, engine-image 11x, share-manager pre-pull init 8x, exit 137 at 2026-11-19T07:33:52Z).** These fall in the same window as the cluster-wide Ready transitions (node-1 07:16:01Z, node-3 07:34:59Z, node-2 07:48:41Z on 2026-11-19), which suggests a node reboot or restart event. The herdr-0 pod was created at 07:45:51Z, inside that window. The root cause is **NOT CHECKED** (would need logs or node-level access).
4. **Daily maintenance window correlation (hypothesis).** The tuppr maintenance window `0 2 * * *` (local time zone) equals 07:00Z in November. The 07:16–07:48Z restarts fall inside a 3h window starting at 07:00Z. The TalosUpgrade and KubernetesUpgrade objects are `Completed` (last transition 2026-11-03), so no upgrade was active at check time. Whether the window caused the restarts is **NOT CHECKED**. This matters for RWX experiment timing, because a daily window can disrupt node-level storage.
5. **Ten Longhorn volumes are `robustness=unknown`, `state=detached`** (14 stopped replicas in total). They are 10 detached volumes belonging to unrelated workloads (8 database data and WAL volumes; 2 application asset and resource volumes, 3 replicas each). The owning namespaces currently run only other unrelated pods, and no database pods are present. Probably scaled down or in a degraded state, but **NOT CHECKED** (would need pod and database-cluster inspection). Not related to Herdr.
6. **Weekly filesystem-trim CronJob (`weekly-trim`, `0 0 ? * FRI`, longhorn-system)** pod on node-2 failed twice (exit 1, last finished 2026-11-20T00:16:24Z). The termination message is empty. Root cause **NOT CHECKED** (logs are not permitted).
7. **Warning event on an unrelated workload pod**: FailedAttachVolume "Volume is already exclusively attached to one node" (last 2026-11-20T01:49:01Z, count 1). This is a RWO attach conflict on a non-Herdr workload. Not investigated.
8. **Warnings from an unrelated workload** (2 events, reason omitted): delay accounting and process effective-user messages. Informational.
9. **Existing RWX claims are all NFS static PVs** (`nfs.csi.k8s.io`). No Longhorn RWX exists, so no ShareManager or share-manager pods exist. The experiment starts from a clean RWX state, but this also means no existing Longhorn RWX baseline to compare against.
10. **Herdr pod has 0 restarts and was created 2026-11-19T07:45:51Z.** The pod is about 19 hours old. It was created during the node Ready window (node-2 did not become Ready until 07:48:41Z), so it was scheduled while the cluster was still settling. Event history for the namespace returned nothing, so why it was (re)created is **NOT CHECKED**.
11. **Date discrepancy.** The environment states today is 2026-11-19. The UTC clock reads 2026-11-20T02:11Z at start, and about 02:40Z at last collection. All timestamps here are UTC.
12. **Non-Herdr workloads on the same nodes** (unrelated application and database workloads). The cluster is shared. Any RWX experiment should use only its own namespace, as AGENTS.md requires.
13. **NOT CHECKED (would require something beyond read-only):** Longhorn engine and instance-manager logs, node-level dmesg or journal (node-3 restart cause), `kubectl describe` on each Longhorn volume, CNPG cluster status, the weekly-trim job logs, and any `--dry-run=server` validation of an RWX PVC or StorageClass. The `kubectl debug` and `exec` routes are blocked by the rules.

## Summary of key values

- Context: `context-1` (expected cluster; only context with Herdr namespace).
- Kubernetes: client v1.36.5 / server v1.36.6. Nodes: 3 Talos v1.14.6, kernel 6.18.63-talos, kubelet v1.36.6, all Ready, no taints, not cordoned.
- Longhorn: v1.13.0 (manager, engine, instance-manager, share-manager image all v1.13.0). Pods healthy except node-3 restart history from 2026-11-19T07:33Z.
- StorageClass `longhorn`: default; reclaimPolicy Delete; Immediate; expansion true; numberOfReplicas 3, dataLocality disabled, fsType ext4, staleReplicaTimeout 30, disableRevisionCounter true.
- CSIDriver `driver.longhorn.io`: fsGroupPolicy ReadWriteOnceWithFSType; attachRequired true; Persistent only.
- RWX settings: rwx-volume-fast-failover false; endpoint-network-for-rwx-volume empty; no share-manager or nfs settings exist; storage-over-provisioning 100; minimal-available 20; replica-soft-anti-affinity false.
- Node prerequisites: RequiredPackages, NFSClientInstalled, Multipathd, KernelModulesLoaded, MountPropagation all True on all 3 nodes.
- Scratch headroom: 1 GiB x 3 replicas = 3 GiB. Per-node Longhorn schedulable headroom 63.9 / 44.9 / 42.9 GiB (node-1/2/3).
- Share managers: 0 ShareManager CRs, 0 share-manager pods. Existing RWX PVCs: 16, all NFS static (none Longhorn).
- Herdr: pod `herdr-0`, UID `fe7cd780-06ae-4756-ad8e-d22deb410a38`, node-3, created 2026-11-19T07:45:51Z. Restart counts: herdr 0, ovis 0. PVCs: `home-herdr-0` 5Gi RWO longhorn; `workspace-herdr-0` 20Gi RWO longhorn. Namespace `herdrnetes-exp`, PSA enforce=restricted, 1 NetworkPolicy.
- Experiment namespace `herdrnetes-exp005*`: not present. No `herdrnetes.io/experiment` labelled namespace.
