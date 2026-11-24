# EXP-008 stage B: Kubernetes-driver gateway-restart continuity (PROPOSAL; not approved; nothing installed or run)

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../docs/experiments/08-openshell-execution.md) · follows stage A ([README](local/README.md), FIND-083–087) · REQ-009, REQ-011 (Future) · ADR-0001 unchanged

**Status.** This is research from source only. No component was downloaded, installed, created or run, and no cluster was touched. Every action listed in [section 7](#7-owner-approvals-required-none-granted) needs explicit owner approval. Stage C (real agent) stays deferred.

**Revision 2 (2026-11-24, agent-generated, for owner review).** [Revision 1](https://github.com/jlaska/herdrnetes/blob/fa38e5078345da4ae9a88fab5902cbf795578731/experiments/exp-008/STAGE-B-PROPOSAL.md) (as merged in `fa38e50`, PR #41) is preserved in history. This revision:
- re-checks every rev 1 citation against the pinned sources, corrects nine and completes two (section 2);
- adds three mechanisms that rev 1 missed: credential expiry, `Starting`-row recovery, and gateway readiness that only checks the database;
- compares three test environments and recommends a **disposable local cluster** instead of scratch namespaces in the existing cluster (sections 3–4);
- revises the matrix. It now takes a true SIGKILL through the disposable node, adds a mandatory positive control, and aligns the classification with stage A, keeping one deviation that is pre-registered (section 5).

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

The sources are OpenShell `v0.1.9` (`ce58cf8e9b953281352d98a637e41616295b1318`) and kubernetes-sigs Agent Sandbox `v1.0.3` (`527d9346fe1d237dea5c003f3c720531c7bab1df`).

OpenShell does **not pin** an Agent Sandbox version:
- its docs install `releases/latest`;
- its e2e and k3d tooling default to `v1.0.3` (`e2e/support/install-agent-sandbox.sh:9`);
- newer releases (up to v1.0.12) were not read.

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

## 3. Environment comparison

**Essential to the continuity question (A):**
- A1. The real Agent Sandbox v1.0.3 controller and CRD, and OpenShell chart 0.1.9, with the default two-pod topology.
- A2. A durable gateway DB. The StatefulSet's SQLite is on a PVC, and any default StorageClass works (S, `deploy/helm/openshell/templates/statefulset.yaml:21-33`; `values.yaml:469-475`).
- A3. The `/sandbox` workspace PVC the driver requests (2 GiB RWO, S). It holds the counter log.
- A4. A kernel that passes OpenShell's fail-closed launch probes: Landlock ABI ≥3, seccomp user-notify with ADDFD, task-memory access, and `SO_BINDTODEVICE` (S, `docs/about/support-matrix.mdx:175-195`). The documented minimum is Kubernetes 1.29 (S, `:144`).
- A5. Gateway restarts that nothing else interferes with, such as Argo CD or operators.
- A6. Read access to pod and CR state, and the counter ACK. A host-side PID read improves the evidence but is not essential.

**Fidelity only (B):**
- k3s as the distribution, Cilium, Longhorn, PSA `restricted` and Argo CD.
- The target nodes' kernels.

Continuity depends on the gateway, driver and controller logic and the pod lifecycle. It does not depend on CNI enforcement or the storage backend.
- The driver's NetworkPolicies are checked for **presence**, not enforcement (I).
- Longhorn would matter only for volume re-attach after a node failure, which is out of scope.
- PSA affects admission, not a running process. It is checked by a server-side dry-run.

| | 1. Local disposable cluster (kind / k3d on the workstation) | 2. Separate disposable cluster (dedicated VMs, k3s + Cilium) | 3. Scratch namespaces in the existing cluster |
|---|---|---|---|
| Isolation from existing workloads | Complete: its own API server, CRD and RBAC. The controller's cluster-wide rights stop at the throwaway cluster | Complete | **None at cluster scope.** The controller gets create/delete/patch on pods, services and PVCs in **every** namespace, including the live Herdr namespace (S, `k8s/rbac.generated.yaml`). This cannot be namespace-restricted in v1.0.3 (S). A CRD in a shared cluster, and its removal cascading to every Sandbox CR |
| Host exposure | Shares the workstation kernel and, when rootless, the operator's UID (same class as stage A). Rootful nodes widen it | Only the VM | Only the cluster's nodes, but the live workload is exposed |
| OpenShell / Agent Sandbox compatibility | Upstream CI tests the Kubernetes driver on **kind** (S, `.github/actions/setup-e2e-kind/action.yml:53-100`). Upstream local dev uses k3d, which "Requires Docker running" (S, `tasks/scripts/helm-k3s-local.sh:6-8`) | k3s lanes exist upstream (S, `e2e-suites.yml:93-106`) | Unknown: unrecorded node kernels, PSA fields and Cilium allows (rev 1, U) |
| Kernel / Landlock / seccomp | The workstation kernel passed the probes in stage A under rootless Podman (S, FIND-083–087). Whether the probes pass when nested in a node container is unverified (U) | Chosen freely; can match the target | Unrecorded (U) |
| NetworkPolicy / PSA | Enforcement not required. kind's PSA is off by default, so a `--dry-run=server` check against a labelled namespace covers admission | Can match the target exactly | Default-deny needs explicit allows for gateway ingress and API-server egress (rev 1; S/I) |
| Storage | Bundled local-path is sufficient (I) | Any | Longhorn volumes in the shared pool |
| Fidelity to target | Low for CNI, storage and distribution; correct for the OpenShell/Agent Sandbox logic | High | Highest |
| Setup / teardown | One `create` and one `delete`. A host-level diff verifies cleanup | VM provisioning plus a Cilium install, which adds failure modes unrelated to the question. Depends on spare hardware (U) | Cluster-scoped install and removal. Argo CD orphan/prune behaviour (U), plus a CRD-cascade decision |
| Resources / risk | 1 node, about 2–4 vCPU, 4–6 GB RAM and 6–10 GB of images (I). Low risk | Medium cost; low risk | Low cost; **highest risk** |

## 4. Recommendation

**Use approach 1: a disposable single-node kind cluster on the workstation, rootless Podman first.**

Reasons:
- It exercises the exact OpenShell and Agent Sandbox code paths the question depends on.
- Upstream CI uses kind for this driver.
- kind supports Podman as a provider without the Docker socket that k3d needs (I: kind docs, not re-verified here).
- It contains the controller's cluster-wide RBAC completely.
- Its node is disposable, so a **true SIGKILL** of the gateway and a host-side PID read are possible without touching a shared node.
- Cleanup is "delete the cluster" plus a host diff.

What it gives up:
- No Cilium, Longhorn, k3s or target-kernel fidelity. Findings must say so.
- The host kernel is shared, and with rootless Podman so is the operator's UID. Per AGENTS.md, that UID is **not** isolated from the owner's GPG agent or other credentials.
- Mitigations:
  - The **recommended** mitigation is to run the cluster under a separate unprivileged local account.
  - Alternatively, accept the stage A exposure class: synthetic counter only, no credentials, digest-pinned images, no host mounts, loopback only.

**Fallbacks, in order:**
1. k3d, if kind's rootless provider fails and the owner accepts a Docker-compatible socket.
2. A throwaway VM running k3s, if the nested launch probes fail locally or the owner wants target-like kernel and CNI fidelity before stage C.

**Scratch namespaces in the existing cluster are not recommended for stage B.**
- The controller's rights cannot be bounded by namespace.
- A bounding ValidatingAdmissionPolicy would be new, unreviewed cluster-scoped machinery (I).
- Nothing in the continuity question needs the live cluster.

Revisit this only after approach 1 gives a result, and with an approved decision.

## 5. Minimal test matrix

**Identity, collected on every sample:**
- **P (process):** counter nonce (in memory), PID and `/proc` start time inside the workload. Also `boot_id`, and a counter log on `/sandbox` at 1 Hz with a monotonic timestamp. The ACK returns the same fields.
  - If B3's node access is approved, also the host PID and its start time (as stage A's `hpid`/`hstart`).
- **C (container):** UID, containerID, `startedAt`, `restartCount`, phase and Ready for both pods; the CR's UID, generation, `operatingMode` and annotations.
- **G (gateway view):** `main_process_instance_id`, `main_process_started_at_ms`, and the `sandbox get` phase.
- **Sampling:** pods by `get --watch` event streams plus a 1 s poll. `sandbox get` at 1 Hz. Gateway, supervisor and controller logs retained (redacted).

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
| B0 | Preflight, read-only, inside the disposable cluster and on the host only. Records podman and kind versions, cgroup v2 controller delegation, the Landlock LSM list, `ptrace_scope`, server version (≥1.29), StorageClass, no `agents.x-k8s.io` CRD, and a host baseline (containers, volumes, networks, images, listeners, user units, a hash of `~/.kube`). Server-side PSA dry-run of the driver's pod specs | — | A failure stops before any install |
| B1 | Install the pinned controller and chart (TLS port-forward overlay; `values-tls-port-forward.yaml`). Create one sandbox whose main process is the counter. Wait for Ready, for the 300 s bootstrap window to pass, and for the row to leave `Starting`. **Soak for 10 min**, then `ACK b1` | Soak at 1 Hz | Baseline. Ready vs first ACK. Any identity change in the soak means the control is unstable: stop |
| B2 | **Graceful:** scale the gateway StatefulSet to 0, hold 90 s, scale to 1. `ACK b2` | t0−30 s to sandbox Ready + 300 s | Graceful survival; no suspend (H3); Ready ordering. The 90 s hold stays below the minimum remaining credential life (2.2 item 4) |
| B3 | Re-baseline (2 min after B2's Ready). **Forced:** SIGKILL the gateway container's main process through the disposable node's runtime. The kubelet restarts the container in the same pod. `ACK b3` | Same as B2 | Forced survival with a real SIGKILL, and no dual-writer risk |
| B3b *(optional)* | `kubectl delete pod --force --grace-period=0` on the gateway | Same | API-level forced delete. Record whether the old and new gateway processes overlapped on one SQLite PVC (U) |
| B4 *(optional)* | Agent Sandbox controller scaled 0 → 1 after 90 s, gateway up | 90 s + 300 s | Controller restart leaves the pods and CR spec untouched |
| B5 | **Positive control (mandatory, last):** delete the workload pod with the gateway up | Until Ready + 300 s or unavailable | Must classify as restarted or unavailable. **If it reads survived, the detector is broken and B2/B3 are void** |

**Not in the minimal matrix:**
- A supervisor↔gateway network partition (needs an enforcing CNI).
- A gateway outage longer than the credential TTL, and a restart during `Starting`. Each documents a hazard already shown in source (2.2 items 3–4); each would need separate approval.
- A supervisor-pod delete, gateway upgrade or rollback, HA, Herdr, real agents and Kata.

**Stop conditions:**
- Any unavailable result.
- Any guard or kube-context mismatch.
- Sampler loss during an outage window.
- Any object or listener created outside the disposable cluster and its loopback port-forward.
- Any sign that the harness can reach a non-disposable cluster: **abort before any write**.
- The budget: 60 min excluding the B1 soak.

A restarted result is recorded, not retried. The next step re-baselines with the new identity, as in stage A run 4. Each step gets at most one pre-approved, identical re-run, and it is recorded.

## 6. Security, isolation, cleanup

**Pins.**
- OpenShell CLI v0.1.9 (sha256 as in stage A) and chart 0.1.9, with provenance checked as in FIND-079.
- The gateway, supervisor and sandbox images resolved to digests from the **published** 0.1.9 chart. The in-tree `appVersion` is `0.0.0`, so the tags are unverified (U).
- The Agent Sandbox v1.0.3 core `sandbox.yaml`, by release-asset sha256 `725fafda…7d96`. Its controller image changed from a tag to a digest, with that edit recorded. No `--extensions`.
- The kind node image by digest, and the EXP-006 counter image digest.

**Isolation.**
- A dedicated kubeconfig (mode 0600, outside the repo), pointed at by an explicit `KUBECONFIG` and `--context`. A server-identity guard compares the cluster CA hash. Upstream scripts that merge kubeconfigs are not used.
- The API server is bound to loopback, with no host-port mappings.
- A dedicated gateway id. No providers, inference or credentials. Chart PKI stays in a temporary directory that is never committed.
- Access is only by `port-forward`. `exec` into the workload bypasses the OpenShell boundary and is limited to reading identity.
- Preferably run under a separate local account (section 4).

**Rollback.** If any stop condition fires, record the state and go straight to cleanup. There is nothing to roll back outside the disposable cluster.

**Cleanup.**
1. Delete the sandbox through the CLI and wait for finalizers.
2. Uninstall the release and the Agent Sandbox manifest.
3. `kind delete cluster`.
4. Remove the dedicated kubeconfig and the PKI directory. Remove the images pulled only for this run, listed by digest.
5. **Verify** with a diff against the B0 host baseline: containers, volumes, networks, images, listeners, user systemd units, the `~/.kube` hash, and the default Podman store. Confirm no non-disposable context was ever used.

Because the cluster is destroyed, the CRD-cascade question from rev 1 disappears.

**Remaining privileges.**
- Within the throwaway cluster: the controller's cluster-wide pod, service and PVC rights; the gateway's pod and Secret creation in the sandbox namespace; TokenReviews.
- On the host: the shared kernel, and the operator's UID unless a separate account is used.

## 7. Owner approvals required (none granted)

1. The environment: a disposable kind cluster on the workstation, rootless Podman. Rootful only on a separate explicit approval; k3d or a VM only as the fallbacks in section 4.
2. Which local account runs it: a separate unprivileged account (recommended) or the operator's own account.
3. Installing user-space `kind` (pinned version and checksum) and creating its node container, network and volumes.
4. Image pulls from `ghcr.io`, `registry.k8s.io`, `nvcr.io` and `docker.io`, by digest.
5. Inside the disposable cluster only: the Agent Sandbox CRD, namespace, controller Deployment, ClusterRole and ClusterRoleBinding; the OpenShell chart with its ClusterRole, Roles, certgen hook and the NetworkPolicies the driver creates.
6. The TLS port-forward chart overlay. The upstream disabled-auth `values-skaffold.yaml` shape is not proposed.
7. `port-forward`, and read-only `exec` for identity.
8. Node-level actions on the **disposable** node only: the SIGKILL in B3, and an optional host PID read.
9. Optional B3b and B4, and the mandatory positive control B5.
10. The pre-registered deviation from stage A's classification (section 5).
11. That findings are scoped to kind, rootless Podman, local-path, OpenShell v0.1.9 and Agent Sandbox v1.0.3. They make no claim about Cilium, Longhorn, k3s or the target kernels.
12. Whether a later **read-only** preflight of the existing cluster (k3s version, node kernel, Landlock/seccomp, PSA dry-run) is wanted before stage C. It is not part of stage B.

## 8. Judgement

**A minimal stage B is justified as a hypothesis test, not as an expected success.**

The stage A mechanism that replaced the process is specific to the Podman driver: `gateway_manages_lifecycle: true`. The Kubernetes driver opts out of both the shutdown sweep and the startup restart. Its pods are `restartPolicy: Never` with no liveness probe. Its supervisor reconnects indefinitely, and while its pod stays Running the reconcile sees it as Degraded, not Unavailable. Upstream tests do not answer the question for this topology: the only test that asserts PIDs is the experimental shared-supervisor HA test (`e2e/rust/tests/kubernetes_shared_supervisor_ha.rs:355-375`).

**Against, or uncertain:**
- Survival is inferred, not observed.
- A long gateway outage can freeze and then kill the workload through credential expiry, and the supervisor cannot re-bootstrap.
- A restart during `Starting` replaces both pods.
- The controller needs cluster-wide privileges. AGENTS.md asks not to bring this complexity in without an approved decision. A disposable cluster keeps it out of the shared one.

**Alternatives if B2 or B3 show restarts, or the privilege cost is unacceptable:**
1. Keep EXP-006's tmux/SSH ownership: FIND-074 and FIND-076, with no cluster-scoped objects and no isolation.
2. OpenShell for isolation only, with tmux inside the sandbox as the process owner.
3. Treat gateway restarts as interrupting, and rely on native agent resume. That is a separate capability, still to be tested.

Gateway HA (Postgres plus replicas) addresses control-plane availability, not workload survival, and is excluded from stage B.

## 9. Open uncertainties (only an experiment can settle them)

1. The counter's identity across a graceful restart and a true SIGKILL of the gateway (H1).
2. Whether the supervisor pod stays Running, and is therefore Degraded rather than Unavailable, throughout the outage.
3. Whether `sandbox get` reads Ready only after the supervisor reconnects.
4. The actual remaining credential life at the time of an outage, and the replay grace for a lost refresh.
5. Whether OpenShell's launch probes pass nested in a rootless kind node: the inner runtime's seccomp profile, user-namespace mapping and cgroup delegation.
6. Two overlapping gateway processes on one SQLite file after an API force-delete (B3b only).
7. Whether the published 0.1.9 chart's image digests and the in-process Kubernetes driver match the source read here.
8. Changes in Agent Sandbox v1.0.4–v1.0.12, and gateway **upgrade** and rollback. Both are out of scope.
9. Behaviour on the target cluster's kernel, CNI and storage. That is out of scope for stage B by design.
