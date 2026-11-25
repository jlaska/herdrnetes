# EXP-008 stage B: Kubernetes-driver gateway-restart continuity (PROPOSAL; not approved; nothing installed or run)

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../docs/experiments/08-openshell-execution.md) · follows stage A ([README](local/README.md), FIND-083–087) · REQ-009, REQ-011 (Future) · ADR-0001 unchanged

**Status.** This is research only. No component was installed, created or run by the agent. On 2026-11-24 the owner authorized read-only B0 reads of the existing cluster; they ran (`get`, `logs`, `auth can-i`, no Secret data) and are summarized in [2.4](#24-b0-live-read-only-inventory-revision-4). Every other action listed in [section 7](#7-owner-approvals-required-none-granted) needs explicit owner approval. Stage C (real agent) stays deferred.

**Revision 4 (2026-11-24, agent-generated, for owner review).** The owner upgraded the installed Agent Sandbox from v0.5.6 to **v1.0.12** (GitOps, via Argo CD) and authorized B0. Revision 4 changes:
- 2 and 2.3: Agent Sandbox v1.0.12 replaces v0.5.6; v1.0.3 → v1.0.12 controller differences (2.2 item 10);
- new 2.4: the live B0 inventory;
- section 4: conditions 1–3 met in B0; remaining conditions;
- section 5: B5 expectations under v1.0.12, C keys, B0 marked done;
- sections 6–7: cluster-admin kube credential, change freeze now covers both Argo apps, B0 approval consumed.

**Revision 3 (2026-11-24, agent-generated).** It re-targets stage B at the **existing OpenShell and Agent Sandbox installation**, which the owner reports is installed and unused. It does not set up a new cluster. Revision 3 changes:
- 2.3, which records installed versions against the analysed sources;
- sections 3–4 (reuse recommended, conditional on a read-only B0);
- section 5 (API-level forced kill, B3b and B4 dropped, explicit B0 commands);
- section 6 (cleanup preserves the installation);
- section 7 (four approvals).

The process-identity rules, the classification, the positive control, the stop conditions and the evidence requirements are unchanged.

[Revision 2](https://github.com/jlaska/herdrnetes/blob/0ba77401a369f862f94129b2b9e947596a34cc07/experiments/exp-008/STAGE-B-PROPOSAL.md) (`0ba7740`) re-checked the rev 1 citations and recommended a disposable local cluster. [Revision 1](https://github.com/jlaska/herdrnetes/blob/fa38e5078345da4ae9a88fab5902cbf795578731/experiments/exp-008/STAGE-B-PROPOSAL.md) is in `fa38e50` (PR #41).

The question, H1 and the overall judgement are unchanged.

**Question.** Can a Kubernetes-backed OpenShell sandbox keep its canonical main process across a gateway restart? Under the Podman driver it could not (FIND-083, FIND-084).

**Hypothesis H1 (not a result).** With the Kubernetes driver's default topology, a dedicated supervisor pod per sandbox, the workload process survives both a graceful gateway restart and a forced gateway termination. The reason would be that this driver opts out of the lifecycle hooks that replaced the process under Podman. H1 is falsified by any change of the counter nonce, PID or `/proc` start time, a counter-log reset, or a workload pod or container replacement.

## 1. Evidence summary

**Stage A proves** (accepted, one local run, one synthetic process, OpenShell v0.1.9, Podman driver):
- An OpenShell-owned main process is independent of Herdr (FIND-081).
- Single-writer attach (FIND-086), and retention and explicit delete (FIND-087).
- A disposable gateway can be isolated on this workstation (FIND-078). Release provenance is verifiable (FIND-079).
- Both gateway restart modes **replaced** the process (FIND-083, FIND-084). Ready preceded the new process (FIND-084), and supervised reconnect reached the replacement (FIND-085).

**Unproven:** any Kubernetes-driver behaviour; process survival across any gateway restart; native agent resume; gateway upgrade and rollback; behaviour on the target cluster's kernel, CNI and storage.

## 2. Source findings

The sources are OpenShell `v0.1.9` (`ce58cf8e9b953281352d98a637e41616295b1318`) and kubernetes-sigs Agent Sandbox `v1.0.3` (`527d9346fe1d237dea5c003f3c720531c7bab1df`). Revision 4 adds Agent Sandbox `v1.0.12` (release asset `sandbox.yaml` sha256 `9c400c9d875061088c28598525b7ec37a5c2cb50460804c6b6f53f5fc37301ff`); its `controllers/sandbox_controller.go` and `api/v1beta1/sandbox_types.go` were diffed in full against v1.0.3 (2.2 item 10). Agent Sandbox line numbers below are v1.0.3 unless marked v1.0.12.

OpenShell does **not pin** an Agent Sandbox version:
- its docs install `releases/latest`;
- its e2e and k3d tooling default to `v1.0.3` (`e2e/support/install-agent-sandbox.sh:9`);
- so v1.0.12 is newer than anything OpenShell 0.1.9 tests against (U).

Labels:
- **S** means source-confirmed and **I** means inferred.
- **U** means it needs an experiment.
- **S\*** marks an item the lead agent re-read in the clone for this revision.

OpenShell paths are relative to its tree. Driver paths are `crates/openshell-driver-kubernetes/src/`.

### 2.1 Why stage A replaced the process, and why Kubernetes may differ

| Item | Podman (stage A) | Kubernetes driver | Label |
|---|---|---|---|
| `gateway_manages_lifecycle` | `true` (`crates/openshell-driver-podman/src/driver.rs:726`) | `false` (`driver.rs:1305`) | S\* |
| Stop sweep on gateway SIGTERM | Runs: containers stopped (FIND-083) | Returns early (`crates/openshell-server/src/compute/mod.rs:4139-4141`) | S\* |
| Startup recovery | Restarts containers when launch auth is set (FIND-084) | Lifecycle-transition recovery runs **first** (`compute/mod.rs:4280`), then the driver returns early to `recover_pending_sandbox_updates` (`:4281-4283`). That recovery only acts on rows in a transition phase, so it is a no-op for Ready and Provisioning rows. Rows in `Starting` are re-started: see 2.2 | S\* |
| Gateway SIGTERM | Stops sandboxes | Drains supervisor sessions (≤10 s) and demotes the DB row from Ready to Provisioning. Does not touch CRs, pods, NetworkPolicies or Secrets (`crates/openshell-server/src/lib.rs:1324-1355`) | S |
| Gateway SIGKILL / pod force-delete | Process ran until restart | The driver runs inside the gateway process, so nothing reconciles while it is down. The StatefulSet recreates the gateway, whose SQLite DB is on a PVC | S (in-process); I (rest) |

### 2.2 Mechanisms that can preserve or interrupt the process

1. **Ownership and discovery.**
   - The gateway creates one Agent Sandbox `Sandbox` CR (`agents.x-k8s.io`, v1beta1) (S, `driver.rs:2564-2790`).
   - The Agent Sandbox controller creates the workload pod with a controller ownerReference (S, `controllers/sandbox_controller.go:1188-1480`).
   - The gateway creates the supervisor pod directly (S, `driver.rs:3523-3596`, `sandbox_runtime.rs:336-640`).
   - Both pods use `restartPolicy: Never` (S, `sandbox_runtime.rs:637`, `driver.rs:8107`). Neither has a liveness probe (S).
   - CRs are found by the labels `managed-by=openshell` + `gateway-id` (S, `driver.rs:1965-1971`, `6324-6335`). The periodic reconcile runs every 30 s (S, `driver.rs:614`, `5676-5700`).
   - Existence depends on both sides. A sandbox missing from the cluster for more than 5 min is pruned from the DB (S, `compute/mod.rs:558`, `6678-6820`). A CR with no DB row is left alone (S, `:6636-6652`).
2. **No suspend at restart (the race rev 1 feared is absent).**
   - The reconcile suspends the workload (deleting its pod) only when the supervisor is **Unavailable** (S\*, `driver.rs:5254-5262`).
   - Unavailable means: the supervisor pod has a deletionTimestamp, is missing, or is in a phase other than Running.
   - Ready=True is Available, and Running-but-not-Ready is **Degraded**, which only publishes an annotation (S\*, `driver.rs:6803-6830`). API errors give Unknown, which never suspends (S).
   - Supervisor readiness mirrors whether the gateway has accepted its session (S\*, `crates/openshell-supervisor/src/lib.rs:1028-1062`). After a gateway restart the supervisor is therefore Degraded, not Unavailable, as long as its pod stays Running.
   - Other suspend triggers are a missing Service or fence, a UID or generation mismatch, and resource-admission config drift (S, `driver.rs:4974-5268`). A plain restart is not expected to cause any of them (I; checked by H3).
3. **Restart during `Starting` replaces both pods.**
   - If a gateway restarts while a sandbox row is `Starting`, recovery re-issues StartSandbox with launch auth.
   - The driver then stops the sandbox and recreates both pods: "Gateway restart creates a fresh in-memory launch session" (S\*, `driver.rs:4345-4362`).
   - A stale non-`create` bootstrap is suspended. A `create` bootstrap marker newer than 300 s is rolled back by deleting the CR (S, `driver.rs:5537-5592`).
   - **No restart step may begin until the sandbox is Ready and past 300 s.**
4. **Credential expiry is the one gateway-loss path that can freeze and kill the process.**
   - The workload-side boundary server closes its supervisor connection when the presented credential expires (S\*, `crates/openshell-sandbox/src/boundary_server.rs:1589-1660`, set at `:1699-1700` and `:1744-1745`).
   - Losing that connection freezes the workload. After the recovery deadline (default 30 s, range 10–300 s) the process tree is terminated (S, `boundary_server.rs:3202-3310`).
   - Only the gateway can renew the credential. The chart's JWT TTL is 3600 s (S, `deploy/helm/openshell/templates/_toml.tpl:131`).
   - The supervisor's tokens come from its auth bundle (`TokenSource::File`), so ServiceAccount re-bootstrap does **not** apply to it (S, `crates/openshell-core/src/grpc_client.rs:140-153`, `803-805`). **This corrects rev 1**, which said re-bootstrap would recover the session.
   - Arithmetic on the refresh constants suggests the worst-case remaining life is about 460 s (I). Short outages (≤120 s) should be safe; longer ones may be fatal (U).
   - Rev 1's statement that the freeze deadline "belongs to supervisor↔workload transport loss, not gateway loss" is therefore **incomplete**.
5. **Control direction.** New sandboxes default to `RuntimeInitiated` (S, `config.rs:81-90`, `driver.rs:2720`): the workload-side runtime dials the supervisor's per-sandbox Service. The supervisor's gateway session is still outbound. Only in this mode does the boundary Service publish not-ready addresses (S).
6. **Process identity.**
   - `main_process_instance_id` is a UUID per **supervisor instance** (S, `crates/openshell-supervisor-process/src/delegated.rs:99`). It survives a supervisor reconnect, and `started_at` is kept while the id matches (S, `compute/mod.rs:6010-6023`).
   - So under this driver, neither value identifies the workload process. That differs from stage A, where supervisor and process shared one container (I).
   - With `restartPolicy: Never`, a container restart means a pod replacement, so pod UID, containerID and `startedAt` detect it (I).
   - An in-memory nonce plus PID, `/proc` start time and `boot_id` identifies one process. Only gaps in the counter log reveal a freeze (I).
7. **Readiness ordering.**
   - The gateway's `/readyz` only pings the database (S, `crates/openshell-server/src/readiness.rs:7-17`), so Kubernetes Ready on the gateway says nothing about the supervisor.
   - From source, `sandbox get` returns to Ready only after the supervisor reconnects (I, `compute/mod.rs:8063-8085`). Under Podman, Ready came before the process (FIND-084), so this is measured, not assumed (U).
8. **Agent Sandbox controller.**
   - On restart it does not enforce spec on existing pods (S, `sandbox_controller.go:1290-1380`, TODO at `:1377`).
   - It deletes a workload pod only when the CR is Suspended or expired. If the pod vanishes, it creates a new one (S).
   - It has **no** namespace-restriction option. The flags at `cmd/agent-sandbox-controller/main.go:93-176` have no watch namespace. `--cache-label-selectors` (`:146`) narrows the cache but not RBAC (S).
   - The opt-in `--extensions` manifest adds cluster-wide NetworkPolicy CRUD (S, `k8s/extensions-rbac.generated.yaml`). It is **excluded**.
9. **Auto-restart after main exit.** If the counter exits, OpenShell replaces the runtime with a new process (S, `compute/mod.rs:5066-5200`). A replacement accompanied by an exit report is a process death, not a gateway effect, and is classified as restarted with the exit code recorded.
10. **Agent Sandbox v1.0.3 → v1.0.12 (revision 4).** Relied-on behaviour is unchanged, with one new Ready reason:
    - A deleted workload pod is recreated with the same name, `sandbox.Name` (S, v1.0.12 `sandbox_controller.go:2029`; v1.0.3 `:1452`). OpenShell's pod template carries the `openshell.ai/bootstrap` scheduling gate that only the driver lifts (S, `driver.rs:7484`, `4077`), so the replacement comes back gated and Pending without the original process (I).
    - On controller restart, existing pods still get only label/annotation patches; the "enforce spec" TODO is still commented out (S, v1.0.12 `:1942`).
    - **New:** any pod with a deletionTimestamp makes the Sandbox `Ready=False`, reason `PodTerminating` (S, v1.0.12 `:768-776`); v1.0.3 kept Ready=True during the grace period. The gateway treats every Ready=False reason outside a transient list as terminal and sets phase **Error** (S\*, `compute/mod.rs:8417-8430`), which is not auto-recovered. This matters only when the **workload** pod is deleted (B5), not for gateway restarts (B2, B3).
    - `failedPodPolicy` is new, defaults to `Retain`, and the controller acts only on `Recreate`; OpenShell never sets it, so v1.0.3 behaviour holds (S).
    - New CRD validations (name ≤63 when `spec.service` is set; unique, non-empty VCT names; `maxItems: 128`) are satisfied: OpenShell never sets `spec.service`, caps names at 63 (`driver.rs:2114-2120`) and emits one VCT, `workspace` (S).
    - The controller no longer writes the `agents.x-k8s.io/pod-name` annotation (v1.0.0 release notes); pod name equals Sandbox name.
    - No new expiry, suspend or deletion triggers for direct (non-claim) Sandboxes (S). The extensions controllers were not diffed; they are not installed.
    - v1.0.0 removed `v1alpha1` and the conversion webhook. The ClusterRole lost its CRD `get/patch/update` rule, so the controller's privileges **narrowed** (S, manifest diff; confirmed live in 2.4).

### 2.3 Installed versions versus the analysed sources (revision 3)

The owner reports that OpenShell and Agent Sandbox are already installed, unused, in the existing cluster under Argo CD.

The evidence for this subsection is the owner's GitOps repository, read at commit `18a4259` (revision 3) and `a604ce9` (revision 4, Agent Sandbox rows). Cluster, host and identity-provider names are deliberately omitted from this public repo. Live confirmation is in 2.4.

| Item | Analysed in section 2 | Installed per GitOps | Effect |
|---|---|---|---|
| OpenShell chart | 0.1.9 (`ce58cf8`) | 0.1.9, StatefulSet, 1 replica | Same source (S). Image digests unknown until B0 |
| Supervisor topology | Default: one dedicated supervisor pod per sandbox | Values set `supervisor.topology: combined`, `supervisor.sideloadMethod: init-container` and `server.appArmorProfile` | **Not effective in chart 0.1.9.** `supervisor.topology` was "removed by RFC 0012 with no replacement" (S, `docs/kubernetes/migrate-gateway-config.mdx:41`). No template reads these keys, and the driver's only topology enum is `Gateway`/`Workspace` (S, `config.rs:221-225`). So the install should be the default topology that section 2 analyses (I; B0 verifies) |
| Agent Sandbox | v1.0.3 (`527d934`) | **v1.0.12** since 2026-11-24 (GitOps `a604ce9`; previously v0.5.6). The kustomization now fetches the release asset by URL, pinned by tag only, not by digest (S) | Compatible by source with the caveats in 2.2 item 10. The driver prefers `v1beta1` (S, `driver.rs:1982-2025`). **Upstream never tested OpenShell 0.1.9 with v1.0.12** (U) |
| Webhook | None (v1.0.3) | None. v1.0.x removed the v0.5.6 conversion webhook; Argo pruned its Service, Role and RoleBinding (live, 2.4) | The CRD no longer depends on the controller pod being up. One orphan Secret remains (2.4) |
| Auth | Not specified | TLS with mTLS client CA for sandbox callbacks. CLI users authenticate by OIDC (PKCE, browser login). No unauthenticated users. No non-interactive CLI credential exists in the repo | The harness needs an owner-performed CLI login (section 7) |
| Sandbox namespace | Separate scratch namespace | The gateway's own namespace | The experiment's sandbox lives beside the gateway |
| Storage | local-path | Workspace PVC on a Longhorn class with 1 replica, best-effort locality and reclaim `Delete`. The gateway data PVC uses the cluster default class (I: Longhorn) | Longhorn is not needed for continuity, but present. Gateway rescheduling may wait for RWO detach/attach |
| Admission / network | kind defaults | No PSA labels on either namespace. The cluster default is enforce `baseline`, audit/warn `restricted`. No Kyverno or Gatekeeper. No Cilium or default-deny policies on these namespaces (all per repo) | Driver pod specs should pass baseline (I; `net.ipv4.ip_unprivileged_port_start` is a baseline-safe sysctl). B0 confirms |
| Argo CD | — | Apps project. Automated sync with `prune` and `selfHeal`, plus `ApplyOutOfSyncOnly`. **`ignoreDifferences` on StatefulSet and Deployment `.spec.replicas`**. The Agent Sandbox app (infrastructure project) has no such ignore | `scale 0` of the gateway is not reverted by self-heal (S, appset config). An unrelated sync that re-applies the StatefulSet would reset replicas, because there is no `RespectIgnoreDifferences` (I). Scaling the controller *would* be reverted |
| Renovate | — | Patch updates automerge (global `minimumReleaseAge` 3 days). The OpenShell chart moved weekly from 0.1.3 to 0.1.9. **Revision 4:** a new regex manager now also tracks the Agent Sandbox release URL (GitOps `62a840c`), so v1.0.x patches will automerge too | A chart or controller patch release during the run would automerge and sync, restarting the gateway or controller mid-step. The change freeze must cover **both** Argo apps (section 7) |
| Other consumers | — | No Sandbox CRs in GitOps. No other app references the gateway | Confirmed live: none (2.4) |

### 2.4 B0 live read-only inventory (revision 4)

Run by the lead agent on 2026-11-24, ~21:20 UTC, after owner authorization, with an explicit kube context. Commands: section 5.1 (`get`, `logs`, `auth can-i` only; Secret **names** only). Raw output stays local; host, node and identity-provider names are omitted here.

| Item | Observed | Condition (section 4) |
|---|---|---|
| Kubernetes | Server v1.36.6. 3 nodes, Talos v1.14.6, kernel `6.18.63-talos`, containerd 2.3.7 | — |
| Agent Sandbox CRD | Only `sandboxes.agents.x-k8s.io` (no extension CRDs). Versions: `v1beta1` served + storage only. `conversion: None`. `storedVersions: ["v1beta1"]`. Established | **Met** (2) |
| Controller | Deployment 1/1, image `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.12@sha256:b0ee91a42129919179baf5f429979fee3ab1a3dac6855110b4648a6ff4b44103`, pod started 21:11 UTC, 0 restarts, leader lease held. No error lines in the last 400 log lines. Events show a clean rollout from the previous ReplicaSet | **Met** (2) |
| Controller ClusterRole | PVCs, pods, services (CRUD+watch); events (create/patch); `sandboxes` (CRUD+watch); `sandboxes/finalizers,status` (get/patch/update); leases. **No CRD rights** | Narrower than v0.5.6 |
| Leftovers from v0.5.6 | Webhook Service, Role and RoleBinding are gone (pruned). Secret `agent-sandbox-webhook-certs` (Opaque, created 2026-10-11) remains, unused | Harmless; upstream's post-upgrade step 4 would delete it. Owner decision, not part of stage B |
| Webhook configurations | No validating or mutating webhooks matching `sandbox` or `openshell` | — |
| Sandbox CRs | **None** in any namespace | **Met** (3) |
| Gateway | StatefulSet `openshell` 1/1 (so `$GW_STS=openshell`, pod `openshell-0`). Image `ghcr.io/nvidia/openshell/gateway:0.1.9@sha256:1fd9e1e807990e66c9486a28d3ce9d649fd7528df48d0e830d2de2148b52dfe5`. Pod up since 2026-11-19 07:25 UTC, 0 restarts | **Met** (1) |
| Rendered config (`openshell-config`) | `compute_driver = "kubernetes"`, namespace `openshell`, `workspace_mode = "shared"` (the default), workspace class `longhorn-unreplicated-besteffort` 1Gi, supervisor image `supervisor:0.1.9`, `gateway_jwt.ttl_secs = 3600`, `sa_token_ttl_secs = 3600`, resource admission enabled, managed SSH ingress enabled, TLS on, OIDC configured. **No `supervisor_topology` key** | **Met** (1): default two-pod topology |
| Gateway data | PVC `openshell-data-openshell-0`, 1Gi RWO, class `longhorn` (default; reclaim `Delete`) | — |
| Gateway log (since pod start, ~33k lines) | Only periodic reconcile and refresh sweeps; **no sandbox creations or supervisor sessions**; `watched_count=0` credentials. Warnings are watch-expiry and apiserver `429 storage is (re)initializing` re-lists, including a sandbox-watch re-list at 21:13 when the new CRD applied; all recovered | **Met** (3) |
| Argo CD | `…-openshell` Synced/Healthy (last op 2026-11-18). `…-agent-sandbox` Synced/Healthy at `a604ce9` (op finished 21:13 UTC) | **Met** (4, sync state); freeze still needed |
| Namespaces | No PSA labels on `openshell` or `agent-sandbox-system`; the cluster default applies (per GitOps; not readable through the API) | — |
| Network policy | Three NetworkPolicies in `openshell` (sandbox SSH, supervisors, workloads). No Cilium policies, namespaced or cluster-wide | — |
| Storage classes | `longhorn` (default), `longhorn-static`, two unreplicated Longhorn classes, one NFS class (Retain) | — |
| Quota / LimitRange | None in `openshell` | — |
| Kube credential | The available context is **cluster-admin** (`auth can-i --list`: `*.*` `[*]`) | Risk: section 6 |
| Not readable in B0 | Gateway DB rows (would need `exec`); OIDC login state; the cluster's PSA admission config | Covered by B1 and the owner login |

## 3. Environment comparison

**Revision 3 reassessment.** Revision 2 compared three new environments and rejected scratch namespaces in the existing cluster, chiefly because they would add the controller's cluster-wide RBAC to the shared cluster. With the controller and gateway already installed there, reusing them **adds no cluster-scoped object or privilege**. The experiment adds only:
- one sandbox, created through the gateway (CR, two pods, a workspace PVC, Secrets, a Service and NetworkPolicies, all in the gateway's namespace);
- restarts of the existing gateway.

The essential requirements A1–A6 below are unchanged. The installed Agent Sandbox version differs from A1's (2.3, 2.4).

**Essential to the continuity question (A):**
- A1. The real Agent Sandbox controller and CRD, and OpenShell chart 0.1.9, with the default two-pod topology. Revision 2 named v1.0.3; the installed v1.0.12 is acceptable (B0 confirmed the CRD and controller; 2.2 item 10 covers the source differences).
- A2. A durable gateway DB on a PVC.
- A3. The `/sandbox` workspace PVC, which holds the counter log.
- A4. A kernel that passes OpenShell's fail-closed launch probes (S, `docs/about/support-matrix.mdx:175-195`).
- A5. Gateway restarts that nothing else interferes with, such as Argo CD or Renovate.
- A6. Read access to pod and CR state, and the counter ACK.

**Fidelity only (B):** k3s/Talos as the distribution, Cilium, Longhorn, PSA level and the target kernels. Reusing the existing cluster supplies these for free, but findings still claim nothing beyond what was tested.

| | 1. Local disposable cluster (rev 2 recommendation) | 2. Separate disposable cluster (VMs) | 3. **Reuse the existing installation** |
|---|---|---|---|
| New cluster-scoped privilege | None outside the throwaway cluster | None outside it | **None new.** The controller's cluster-wide rights already exist; the experiment does not widen them |
| Setup | Install kind, the controller, the chart and PKI; troubleshoot rootless nesting | VM, k3s and Cilium | One CLI login and one sandbox |
| Fidelity | Low | High | Highest: the real distribution, kernel, CNI and storage |
| Version match to analysed source | Exact | Exact | Chart exact. Agent Sandbox v1.0.12 instead of v1.0.3 (same API, diffed) |
| Effect on other workloads | None | None | Gateway restarts affect only that gateway and its sandboxes (S: shutdown writes nothing; the ClusterRole is read-only plus TokenReviews). B0 must show no other sandboxes or sessions |
| Forced kill | True SIGKILL through the node | True SIGKILL through the node | API-level only. A pod delete with a 1 s grace period ends in SIGKILL. No node access |
| Cleanup | Delete the cluster | Delete the VMs | Delete one sandbox, then verify the pre-existing installation is intact (section 6) |
| Main risks | Nested-runtime troubleshooting | Hardware and time | Shared gateway state (the DB), Argo/Renovate interference on two apps, untested v1.0.12 pairing, owner OIDC token in the harness session, cluster-admin kube credential |

## 4. Recommendation

**Go, conditional on B0: run stage B on the existing OpenShell installation.**

Reasons:
- It answers the same question with the same OpenShell source and higher fidelity.
- It needs no infrastructure setup.
- It adds no cluster-scoped privilege.

Conditions, verified read-only in B0 before B1 (results from 2.4):
1. **Met.** Live gateway image is 0.1.9 (digest recorded), with no `supervisor_topology` in the rendered gateway config.
2. **Met.** The controller runs v1.0.12 (digest recorded) and the CRD serves only `v1beta1`, as storage, with `storedVersions: ["v1beta1"]`.
3. **Met.** No Sandbox CRs anywhere and no supervisor sessions in the gateway log. **Re-check immediately before B1**, since state can change.
4. **Partly met.** Both Argo apps are Synced and Healthy. The change freeze (section 7, item 4) must now cover the OpenShell **and** Agent Sandbox apps, because Renovate tracks both.

Any failed condition is a no-go for reuse until the owner decides. **B0 found no blocker.**

**Fallback:** revision 2's disposable local kind cluster ([rev 2](https://github.com/jlaska/herdrnetes/blob/0ba77401a369f862f94129b2b9e947596a34cc07/experiments/exp-008/STAGE-B-PROPOSAL.md#4-recommendation)), only if the v1.0.12 pairing proves incompatible in B1. Upgrading the installation to match the analysed versions is **not** proposed.

## 5. Minimal test matrix

**Identity, collected on every sample:**
- **P (process):** counter nonce (in memory), PID and `/proc` start time inside the workload. Also `boot_id`, and a counter log on `/sandbox` at 1 Hz with a monotonic timestamp. The ACK returns the same fields. Host PID is not available, because there is no node access.
- **C (container):** UID, containerID, `startedAt`, `restartCount`, phase, Ready and node for both pods; the CR's UID, generation, `operatingMode`, Ready (with reason) and Suspended conditions with `observedGeneration`, and the `gateway-id` label. The v1.0.12 controller does not write the `agents.x-k8s.io/pod-name` annotation; pod name equals Sandbox name (2.2 item 10). The workload pod's scheduling gates are recorded too.
- **G (gateway view):** `main_process_instance_id`, `main_process_started_at_ms` and the `sandbox get` phase. Also the gateway pod UID, node, image digest and Ready, and the data PVC's attach events.
- **Sampling:** pods by `get --watch` event streams plus a 1 s poll. `sandbox get` at 1 Hz. Gateway, supervisor and controller logs kept locally, redacted before any commit.

**Classification**, pre-registered and applied separately to each step. Process continuity and session reattachment are separate axes:

| Class | Rule |
|---|---|
| **survived** | All P keys unchanged; the workload pod UID and containerID unchanged; counter log gap-free (no inter-sample gap >3 s). If G or the supervisor pod changed, append "supervisor replaced". If P is unchanged but there is a gap >3 s, record "survived (frozen *N* s)" |
| **restarted** | Any P key differs, the counter `n` resets, or the workload pod UID/containerID changes. An exit code is recorded if reported (2.2 item 9) |
| **reattached** | A fresh `sandbox connect` reached the PTY and returned a valid ACK. Reported alongside survived or restarted. Reattached + restarted is the FIND-085 pattern, not continuity |
| **native resume** | Not tested. The synthetic counter has no resumable session |
| **unavailable** | The sandbox is not Ready within 300 s of gateway pod Ready, or Ready without a valid ACK within 300 s. **The run stops: no recreate and no reset** |
| **inconclusive** | A P key is missing, the identity sources contradict each other, the sampler lost data across the outage window, or a guard deviated |

**Deviation from the stage A rules, for owner approval.** Stage A treated `main_process_instance_id` as a process key ([local/README.md](local/README.md), `demo.sh` `a5_classify`), which was correct while supervisor and process shared one container. Under this driver it identifies the supervisor (2.2 item 6). It therefore moves from P to G: a change on its own is "supervisor replaced", not restarted.

| Step | Action | Window | Answers |
|---|---|---|---|
| B0 | **Done 2026-11-24** (2.4): read-only live inventory, the commands in [section 5.1](#51-b0-read-only-commands). Before B1, re-run the Sandbox CR, gateway pod and Argo lines, and record the CLI version and checksum | — | Reuse conditions (section 4). No blocker found |
| B1 | Create **one** experiment sandbox through the gateway, `--from` the stage A workload image digest, with the counter as its main process. Name and label it for the experiment. Wait for Ready, for the 300 s bootstrap window to pass, and for the row to leave `Starting`. **Soak for 10 min**, then `ACK b1` | Soak at 1 Hz | Baseline; Ready vs first ACK; v1.0.12 pairing works. Any identity change in the soak: stop |
| B2 | **Graceful:** `scale statefulset/$GW_STS --replicas=0` (the name recorded in B0), hold 90 s, `--replicas=1`. `ACK b2`. Keep the total gateway outage under 240 s. If rescheduling waits on a volume attach, record it; the window still applies | t0−30 s to sandbox Ready + 300 s | Graceful survival; no suspend (H3); Ready ordering. Argo ignores replicas (2.3) |
| B3 | Re-baseline (2 min after B2's Ready). **Forced (API-level):** `delete pod $GW_STS-0 --grace-period=1`. SIGTERM is followed by SIGKILL after 1 s, which cuts the 10 s drain short. The StatefulSet recreates the pod only after the old one has terminated, so there is no dual writer. `ACK b3` | Same as B2 | Survival when the gateway is killed mid-shutdown. A pure SIGKILL with no SIGTERM is **not** reachable without node access; it stays U |
| B5 | **Positive control (mandatory, last):** delete the **experiment's own** workload pod with the gateway up | Until Ready + 300 s or unavailable | Must classify as restarted or unavailable. **If it reads survived, the detector is broken and B2/B3 are void.** Expected under v1.0.12 (2.2 item 10): Sandbox `Ready=False/PodTerminating` during the grace period; gateway phase **Error**, which may not recover; a replacement pod with the **same name, a new UID**, scheduling-gated. Unavailable is therefore the likely, valid outcome. Do not assert that Ready stays True until the pod is gone |

**Dropped for reuse:**
- B3b (`--force --grace-period=0`) could start a second gateway on the pre-existing SQLite DB.
- B4 (controller restart): scaling is reverted by Argo, and a controller restart touches every Sandbox CR in the cluster. (The owner's v0.5.6 → v1.0.12 rollout restarted the controller with no Sandboxes present, so it says nothing about B4.)

Everything revision 2 excluded stays excluded.

**Stop conditions:**
- Any unavailable result.
- Any guard or kube-context mismatch.
- Sampler loss during an outage window.
- Any write to an object not created by the experiment, other than the gateway StatefulSet's replicas and pod.
- A new Sandbox CR, session or Argo sync that appears during the run.
- The gateway not Ready within 240 s of scale-up or pod deletion.
- The budget: 60 min excluding the B1 soak.

A restarted result is recorded, not retried. The next step re-baselines with the new identity, as in stage A run 4. Each step gets at most one pre-approved, identical re-run, and it is recorded.

### 5.1 B0 read-only commands

The owner authorized these on 2026-11-24 and they ran once (2.4). Re-runs before B1 fall under the same authorization only if the owner says so. They run with an explicit context, `K="kubectl --context $CTX"`, and every command is `get`, `logs` or `auth can-i`. None reads Secret data. Outputs stay local until they are redacted (names of hosts, nodes and identity providers removed).

```sh
$K version -o yaml
$K get nodes -o custom-columns=NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion,OS:.status.nodeInfo.osImage,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KUBELET:.status.nodeInfo.kubeletVersion
$K get crd -o name | grep -i 'agents.x-k8s.io'
$K get crd sandboxes.agents.x-k8s.io -o jsonpath='{range .spec.versions[*]}{.name} served={.served} storage={.storage}{"\n"}{end}{.spec.conversion.strategy} {.status.storedVersions}{"\n"}'
$K get sandboxes.agents.x-k8s.io -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,MODE:.spec.operatingMode,GW:.metadata.labels.openshell\\.ai/gateway-id,AGE:.metadata.creationTimestamp
$K -n openshell get statefulset,deployment,pod,service,pvc,networkpolicy,serviceaccount,role,rolebinding,configmap,resourcequota,limitrange -o wide
$K -n openshell get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.spec.nodeName}{"\t"}{range .status.containerStatuses[*]}{.image}{" "}{.imageID}{" rc="}{.restartCount}{" "}{end}{"\n"}{end}'
$K -n openshell get statefulset,configmap -o name   # discover $GW_STS and the gateway *-config ConfigMap
$K -n openshell get configmap "$GW_CONFIG" -o yaml   # rendered gateway TOML: supervisor_topology absent? gateway_jwt ttl, sandbox namespace
$K -n openshell get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,MODE:.spec.accessModes,VOL:.spec.volumeName,STATUS:.status.phase
$K -n openshell get events --sort-by=.lastTimestamp
$K -n openshell logs "statefulset/$GW_STS" --since=24h --tail=500   # supervisor sessions; kept local
$K -n agent-sandbox-system get deployment,pod,service,lease,role,rolebinding -o wide
$K -n agent-sandbox-system get secret -o custom-columns=NAME:.metadata.name,TYPE:.type   # names only
$K get clusterrole agent-sandbox-controller -o yaml
$K -n agent-sandbox-system logs deploy/agent-sandbox-controller --tail=400   # kept local
$K -n agent-sandbox-system get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.image}{" "}{.imageID}{" rc="}{.restartCount}{end}{"\n"}{end}'
$K get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -i -E 'sandbox|openshell'
$K get namespace openshell agent-sandbox-system --show-labels
$K get storageclass
$K -n openshell get ciliumnetworkpolicies; $K get ciliumclusterwidenetworkpolicies
$K -n argo-system get applications.argoproj.io -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTO:.spec.syncPolicy.automated | grep -E 'openshell|agent-sandbox'
$K auth can-i --list -n openshell
```

The `openshell` namespace and the Argo CD namespace come from the GitOps repo. `$GW_STS` and `$GW_CONFIG` were discovered by the `-o name` listing, not assumed: B0 found `openshell` and `openshell-config`. In zsh, quote `custom-columns` arguments (brackets glob) and use a shell function, not a string, for `$K`. If either returns nothing, list names first (`get configmap -o name`, `get applications -A -o name`) rather than guessing.

## 6. Security, isolation, cleanup

**Pins.**
- OpenShell CLI v0.1.9 (sha256 as in stage A).
- The live gateway image digest (`sha256:1fd9e1e8…dfe5`) and controller digest (`sha256:b0ee91a4…4103`), recorded in B0, not changed. The supervisor and sandbox digests are recorded in B1.
- The stage A workload image `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d0…7a16`. EXP-006 already pulled this image family in the cluster (I).

**Isolation.**
- An explicit `--context` on every `kubectl` call, and a server-identity guard comparing the cluster CA hash, as in EXP-006.
- **The only kube credential available is cluster-admin** (2.4). The harness therefore cannot be limited by RBAC; its write scope is enforced by the harness itself (an allowlist of verbs and objects, every write logged). A namespaced credential would be better but is not requested, to keep setup minimal.
- The harness touches only:
  - the experiment sandbox and its derived objects;
  - the gateway StatefulSet's replicas and pod.
- No changes to the chart, values, Argo applications (except an owner-performed auto-sync pause), CRDs, the controller, or any other namespace.
- No providers, inference or credentials in the sandbox.
- `exec` into the experiment workload is limited to reading identity.
- The CLI's OIDC token belongs to the owner and sits under the operator's UID. Per AGENTS.md that is not isolation. The owner logs in for the run and logs out at cleanup.

**Rollback.** If any stop condition fires, record the state and then restore the gateway to `replicas=1` and Ready. **Do not** uninstall, re-sync with prune, or delete any pre-existing object.

**Cleanup must leave the existing installation intact:** the OpenShell gateway, its data PVC and DB, the Agent Sandbox controller, CRD and ClusterRole, and the Argo CD apps. (v1.0.12 has no webhook.)
1. Delete the experiment sandbox through the CLI, by name, and wait for finalizers. This must also work from phase Error after B5.
2. Verify the CR, both pods, the workspace PVC and its Longhorn volume (reclaim `Delete`), and the per-sandbox Secrets, Service and NetworkPolicies are gone.
3. Verify the gateway is at `replicas=1`, Ready, with the B0 image digest and the same data PVC UID.
4. Verify the controller pod and digest, the CRD versions and `storedVersions`, and the ClusterRole match B0.
5. Verify the Argo apps are Synced and Healthy. The owner re-enables auto-sync if it was paused.
6. Remove the harness-side data. The owner runs `openshell gateway logout` (or equivalent).
7. **Verify** with a diff of the B0 inventory against a post-run inventory. The only allowed differences are the gateway pod's UID and age, and events.

**Remaining privileges.** These are unchanged by the experiment: the controller's cluster-wide pod, service and PVC rights; the gateway's namespaced Role; TokenReviews. The harness uses the operator's kube credential (cluster-admin, per B0) and the owner's OIDC session.

## 7. Owner approvals required (none granted)

The smallest set for reuse:
1. ~~Authorize the B0 read-only commands~~ **granted and used 2026-11-24** (2.4). A pre-B1 re-check of the Sandbox CR, gateway pod and Argo lines is part of item 2.
2. **Authorize stage B execution on the existing installation** after B0 passes. That covers:
   - one experiment sandbox `--from` the stage A image digest;
   - B2 (scale the gateway 0 → 1);
   - B3 (delete the gateway pod with `--grace-period=1`);
   - B5 (delete the experiment's own workload pod);
   - read-only `exec` into the experiment workload;
   - cleanup per section 6.

   It includes the pre-registered classification deviation (section 5), the revised B5 expectation, and findings scoped to this installation (OpenShell 0.1.9, Agent Sandbox v1.0.12). The harness runs with the cluster-admin context, limited by its own allowlist (section 6).
3. **CLI authentication:** the owner performs the OIDC login for the harness session (role "user" suffices if it can create sandboxes) and logs out at cleanup.
4. **Change freeze for the run window:** either pause automated sync on the OpenShell **and** Agent Sandbox Argo apps for this cluster, owner-performed and restored afterwards; or hold Renovate and other merges to the GitOps repo for that window. (Revision 4: Renovate now tracks Agent Sandbox too.)

No new cluster-scoped install, upgrade, node access, kind installation or workstation change is requested.

## 8. Judgement

**A minimal stage B is justified as a hypothesis test, not as an expected success.**

The stage A mechanism that replaced the process is specific to the Podman driver: `gateway_manages_lifecycle: true`. The Kubernetes driver opts out of both the shutdown sweep and the startup restart. Its pods are `restartPolicy: Never` with no liveness probe. Its supervisor reconnects indefinitely, and while its pod stays Running the reconcile sees it as Degraded, not Unavailable. Upstream tests do not answer the question for this topology: the only test that asserts PIDs is the experimental shared-supervisor HA test (`e2e/rust/tests/kubernetes_shared_supervisor_ha.rs:355-375`).

**Against, or uncertain:**
- Survival is inferred, not observed.
- A long gateway outage can freeze and then kill the workload through credential expiry, and the supervisor cannot re-bootstrap.
- A restart during `Starting` replaces both pods.
- The installed Agent Sandbox v1.0.12 pairing is untested upstream (OpenShell tests v1.0.3).
- The cluster-wide controller is a standing security concern. Reuse does not add to it, but this experiment does not justify keeping it either. Keeping it is a separate owner decision.

**Alternatives if B2 or B3 show restarts:**
1. Keep EXP-006's tmux/SSH ownership: FIND-074 and FIND-076, with no cluster-scoped objects and no isolation.
2. OpenShell for isolation only, with tmux inside the sandbox as the process owner.
3. Treat gateway restarts as interrupting, and rely on native agent resume. That is a separate capability, still to be tested.

Gateway HA (Postgres plus replicas) addresses control-plane availability, not workload survival, and is excluded from stage B.

## 9. Open uncertainties (only an experiment or live read can settle them)

1. The counter's identity across a graceful restart and a forced (1 s grace) pod delete of the gateway (H1).
2. Whether the supervisor pod stays Running, and is therefore Degraded rather than Unavailable, throughout the outage.
3. Whether `sandbox get` reads Ready only after the supervisor reconnects.
4. The actual remaining credential life at the time of an outage, and the replay grace for a lost refresh.
5. Live state that B0 could not read: gateway DB rows and the cluster's PSA admission config. State that can change before B1: the sandbox inventory and Argo sync.
6. Whether OpenShell 0.1.9 works with Agent Sandbox v1.0.12 in practice (B1), and how the gateway reports the B5 pod deletion (Error, and whether it recovers).
7. Gateway rescheduling time when its RWO data volume must re-attach on another node.
8. A pure SIGKILL with no preceding SIGTERM. That needs node access and is not requested.
9. Changes in other Agent Sandbox releases, and gateway **upgrade** and rollback. Both are out of scope.
