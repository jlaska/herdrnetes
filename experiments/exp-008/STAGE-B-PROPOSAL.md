# EXP-008 stage B: Kubernetes-driver gateway-restart continuity (PROPOSAL; not approved; nothing installed or run)

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../docs/experiments/08-openshell-execution.md) · follows stage A ([README](local/README.md), FIND-083–087) · REQ-009, REQ-011 (Future) · ADR-0001 unchanged

**Status.** This is research from source only. No component was downloaded, installed, created or run, and no cluster was touched. Every cluster change listed below needs explicit owner approval. Stage C (real agent) stays deferred.

**Question.** Can a Kubernetes-backed OpenShell sandbox keep its canonical main process across a gateway restart? Under the Podman driver it could not (FIND-083, FIND-084).

**Hypothesis H1 (not a result).** With the Kubernetes driver's default topology, a dedicated supervisor pod per sandbox, the workload process survives both a graceful gateway restart and a forced gateway termination. The reason would be that this driver opts out of the lifecycle hooks that replaced the process under Podman. H1 is falsified by any change of the counter nonce, a counter-log reset, or a container or pod replacement.

## Source findings

The sources are OpenShell `v0.1.9` (`ce58cf8e9b953281352d98a637e41616295b1318`) and kubernetes-sigs Agent Sandbox `v1.0.3` (`527d9346fe1d237dea5c003f3c720531c7bab1df`).

OpenShell does **not pin** an Agent Sandbox version:
- its docs install `releases/latest`;
- its e2e and k3d tooling default to `v1.0.3` (`e2e/support/install-agent-sandbox.sh:9`);
- newer releases (up to v1.0.12) were not read.

Labels: **S** means source-confirmed, **I** means inferred, and **U** means it needs an experiment. OpenShell paths are relative to its tree. The orchestrator re-checked the two decisive items (**S\***) against the clone.

### Why stage A replaced the process, and why Kubernetes may differ

| Item | Podman (stage A) | Kubernetes driver | Label |
|---|---|---|---|
| `gateway_manages_lifecycle` | `true` (`crates/openshell-driver-podman/src/driver.rs:726`) | `false` (`crates/openshell-driver-kubernetes/src/driver.rs:1305`) | S\* |
| Stop sweep on gateway SIGTERM | Runs: containers stopped (FIND-083) | Returns early (`crates/openshell-server/src/compute/mod.rs:4139-4141`) | S\* |
| Startup recovery | Restarts containers when launch auth is set (FIND-084) | Returns early to `recover_pending_sandbox_updates` (`compute/mod.rs:4281-4283`). No `start_sandbox` runs for a Ready sandbox, and nothing is like Podman's JWT-triggered restart | S\* |
| Gateway SIGTERM | Stops sandboxes | Drains supervisor sessions (≤10 s) and exits without touching CRs or pods (`crates/openshell-server/src/lib.rs:1324-1355`) | S |
| Gateway SIGKILL / pod force-delete | Process ran until restart | Nothing runs. The StatefulSet recreates the gateway, whose database is on a PVC | I |

### The seven questions

1. **Creation, ownership, discovery.**
   - The gateway creates one Agent Sandbox `Sandbox` CR (`agents.x-k8s.io`), Suspended, with `restartPolicy: Never` (S, `driver-kubernetes/src/driver.rs:2564-2790`).
   - The Agent Sandbox controller creates the **workload pod** with a controller ownerReference (S, agent-sandbox `controllers/sandbox_controller.go:1188-1480`).
   - The gateway creates the **supervisor pod** directly, with a non-controller ownerReference to the CR (S, `driver.rs:3523-3596`, `sandbox_runtime.rs:336-640`).
   - Both pods use `restartPolicy: Never` (S\*, `sandbox_runtime.rs:637`), and neither has a liveness probe (S).
   - After a restart, the gateway rediscovers its CRs by the labels `managed-by=openshell` + `gateway-id`, then reconciles every 30 s (S, `driver.rs:2418-2545`, `5707-5716`). The gateway database is authoritative for whether a sandbox exists; the cluster is authoritative for backend state (S, `compute/mod.rs:6684-6790`).
2. **Graceful and forced termination.**
   - Graceful: there is no stop sweep (see above).
   - Forced: inferred to leave pods untouched.
   - The upstream e2e does **not** assert process continuity across a gateway restart for this topology (S: only the experimental shared-supervisor HA test asserts PIDs, `e2e/rust/tests/kubernetes_shared_supervisor_ha.rs:355-375`).
3. **Adopt or replace.**
   - Existing pods are adopted (S, `compute/mod.rs:4545-4690`).
   - Credentials rotate in place: a 1 h gateway JWT renewed at about 80 %, with ServiceAccount-token re-bootstrap on Unauthenticated (S, `crates/openshell-core/src/grpc_client.rs:733-840`).
   - **Hazard (I):** the driver's reconcile **suspends the workload, deleting its pod**, when it sees:
     - the supervisor pod unavailable (missing, deleting or not Running);
     - fence or control-policy drift;
     - a generation mismatch (`driver.rs:~5100-5260`, `6810-7030`).

     A Degraded supervisor (Running, not Ready) does not trigger it.
   - A `create` bootstrap marker less than about 5 min old is rolled back by deleting the CR (`driver.rs:5537-5585`). No restart test may start inside that window.
4. **Process identity.**
   - `main_process_instance_id` is a UUID per **supervisor instance**, not per workload process (S, `crates/openshell-supervisor-process/src/delegated.rs:99`).
   - A supervisor reconnect keeps it (S, `supervisor_session.rs:479-575`). `started_at` is kept when the id matches (S, `compute/mod.rs:6004-6015`).
   - So the counter's own nonce must be the primary identity; the instance id is secondary (I).
   - A controller restart does not touch owned pods (I, `sandbox_controller.go:1395-1415`).
5. **Supervisor loses the gateway.**
   - It reconnects forever with 1–30 s backoff and has no give-up path (S, `supervisor_session.rs:45-46`, `363-385`, `595-620`).
   - Its pod goes NotReady in about 3 s. That is harmless: there is no liveness probe, `restartPolicy` is Never, and the boundary Service publishes not-ready addresses (S, `crates/openshell-supervisor/src/lib.rs:205-300`).
   - The freeze-then-terminate deadline (default 30 s, range 10–300 s) belongs to **supervisor↔workload** transport loss, for example a supervisor-pod restart or eviction, not to gateway loss (S, `crates/openshell-sandbox/src/boundary_server.rs:3200-3310`).
6. **Fit with the target cluster.** The EXP-006 cluster model is a disposable namespace, PSA `restricted`, default-deny NetworkPolicy plus Cilium, no ServiceAccount automount, digest-pinned images and Longhorn.
   - **Pod specs (I):** they look compatible with restricted PSA: non-root, drop ALL, `RuntimeDefault` seccomp, no host namespaces, no hostPath and no privileged containers. Two fields need an admission dry-run (**U**):
     - `sysctl net.ipv4.ip_unprivileged_port_start=0`;
     - `supplementalGroupsPolicy: Strict`.

     The certgen hook Jobs were not checked (U).
   - **Kernel (S, `docs/about/support-matrix.mdx:175-195`):** Landlock ABI ≥ 3, nested seccomp user-notify with `ADDFD` under the runtime default profile, task-memory access and `SO_BINDTODEVICE`. All are probed at launch and fail closed. The cluster's node kernel, Landlock and seccomp support are **not recorded** in this repo (U).
   - **Network:** a CNI that enforces ingress and egress policy is required (S). Under default-deny, explicit allows are needed that the chart does not create: supervisor→gateway, DNS, gateway→API server (likely a Cilium `kube-apiserver` entity; I), and gateway ingress from supervisors. The driver also creates its own fence and control NetworkPolicies.
   - Kata/RuntimeClass is optional and not needed for stage B.
7. **Cluster-scoped prerequisites.**
   - **Agent Sandbox v1.0.3:**
     - the CRD `sandboxes.agents.x-k8s.io` (v1beta1 only);
     - the namespace `agent-sandbox-system`;
     - a controller Deployment;
     - a ClusterRole and ClusterRoleBinding with create/delete/get/list/patch/update/watch on **pods, services and PVCs in all namespaces**, plus sandboxes, events and leases.

     It has no webhooks. Its manifest names the controller image **by tag only**.
   - **OpenShell chart 0.1.9:**
     - a ClusterRole for `tokenreviews` create, `nodes` get/list/watch, `namespaces` get, and `runtimeclasses`/`priorityclasses` get. An admin can apply it out of band;
     - a namespaced Role on sandboxes, pods, services, secrets, networkpolicies and events;
     - a certgen pre-install hook.

     It has no webhooks.

## Smallest test matrix (continuity first)

**Identity, three sources per sample:**
1. The counter's pid, `/proc` start and nonce, by ACK. The counter log on `/sandbox` must show `n` strictly increasing with no gap across the outage.
2. `main_process_instance_id` and `main_process_started_at_ms`, which identify the supervisor instance.
3. Pod UIDs, `containerID`, `restartCount` and `startedAt` for both pods, plus the CR's UID and generation. A host PID would need node access, which is a separate approval.

**Classification**, pre-registered and separate for each step:
- **survived:** nonce, pid and start unchanged; gap-free log; same pod UIDs and container IDs; `restartCount` 0. If only the instance id changed, record "supervisor replaced, process survived".
- **restarted:** a nonce change, an `n` reset, or a container or pod change.
- **unavailable:** no ACK within 300 s of the gateway reporting Ready, with pods and phase recorded. The run stops: no recreate and no reset.

| Step | Action | Notes |
|---|---|---|
| B0 | Read-only preflight. API minor version, node kernel / Landlock / seccomp support, CNI enforcement, PSA labels, StorageClass, whether an `agents.x-k8s.io` CRD already exists, and live-namespace and cluster-scoped inventory baselines | A failure stops before any install |
| B1 | Install the pinned controller and gateway. Create one sandbox whose canonical main process is the synthetic counter. Wait until the bootstrap marker has cleared and the sandbox is Ready. Record identity; `ACK b1` through `sandbox connect` over `port-forward` | Baseline. Herdr is optional: a disposable Herdr pane, as in stage A, only if approved |
| B2 | **Graceful gateway restart.** Scale the StatefulSet to 0, hold 90 s, scale to 1. Sample pod state every 5 s; after Ready, `ACK b2` | The core question |
| B3 | **Forced gateway termination.** `delete pod --force --grace-period=0`, then the same sampling and `ACK b3` | A proxy for SIGKILL; a true SIGKILL needs node access |
| B4 | Agent Sandbox controller restart, graceful then forced, held down for 90 s with the gateway up | Optional, after B2 and B3 |
| B5 | Supervisor↔gateway partition (a scratch CiliumNetworkPolicy, 90 s) | Optional. A supervisor-pod delete, the expected freeze/terminate contrast, is deferred |

The run stops at the first unavailable result, and has a 45-minute budget.

### Setup, cleanup, boundaries

**Pins.**
- CLI v0.1.9 (sha256 as in stage A) and chart 0.1.9.
- Gateway, supervisor and sandbox images resolved to digests.
- The Agent Sandbox v1.0.3 manifest, by its release-asset sha256 `725fafda…7d96`. The controller image is changed to a digest, with that edit recorded.
- The existing EXP-006 workload image digest.

**Isolation.**
- Two scratch namespaces, gateway and sandboxes, labelled disposable: PSA `restricted`, default-deny plus explicit allows only, scheduled off the live Herdr node.
- A dedicated gateway id. No providers, inference or credentials.
- Chart PKI kept in a temporary directory that is never committed.
- Access only by `port-forward`, with EXP-006-style kube-context and server-identity guards.

**Cleanup.**
- Delete the sandbox through the CLI, uninstall the release, and delete both scratch namespaces.
- Confirm that the PVCs and Longhorn volumes are gone, and diff the cluster-scoped inventory against B0.
- Removing the CRD cascades to **every** Sandbox CR cluster-wide, so keeping or removing the CRD and controller is an owner decision.

**Security boundaries.**
- The controller's cluster-wide pod, service and PVC rights reach every namespace, including the live Herdr namespace. This is the largest new privilege.
- The gateway can create pods and Secrets in the sandbox namespace, and can create TokenReviews.
- `kubectl exec` into the workload bypasses the OpenShell boundary.
- Only the synthetic counter runs.

### Owner approvals required (none granted)
1. Installing the Agent Sandbox CRD, the `agent-sandbox-system` namespace, and the controller Deployment, ClusterRole and ClusterRoleBinding.
2. The OpenShell ClusterRole and ClusterRoleBinding, or an admin-applied equivalent.
3. The scratch namespaces and their Roles, RoleBindings and ServiceAccounts.
4. NetworkPolicy and CiliumNetworkPolicy objects: the explicit allows, and those the driver creates.
5. Confirmation that no admission webhook is added.
6. Image pulls and registry reads from `ghcr.io` and `registry.k8s.io`.
7. Node-level reads or debug, if a host PID is wanted.
8. PVCs on the cluster StorageClass.
9. `port-forward` and any `exec`.
10. Whether to tear down or retain the CRD and controller.
11. The B0 preflight itself, which reads cluster and node metadata.

## Judgement

**A minimal stage B is justified as a hypothesis test, not as an expected success.**

The stage A mechanism that replaced the process is specific to the Podman driver: `gateway_manages_lifecycle: true`. The Kubernetes driver opts out of both the shutdown sweep and the startup restart. Its pods are `restartPolicy: Never` with no liveness probe, and its supervisor reconnects indefinitely while keeping its instance id. Upstream tests do not answer the question for this topology.

**Against, or uncertain:**
- Survival is inferred, not observed.
- The reconcile can suspend the workload on drift, and the window right after the gateway starts is untested.
- Outages longer than the 1 h JWT, and API-server outages, are untested.
- The cluster's fit is unknown: kernel qualification, PSA fields and Cilium allows.
- The controller needs cluster-wide privileges. AGENTS.md asks not to bring this complexity in without an approved decision.

**Alternatives if B2 or B3 show restarts, or the privilege cost is unacceptable:**
1. Keep EXP-006's tmux/SSH ownership: FIND-074 and FIND-076, with no cluster-scoped objects and no isolation.
2. OpenShell for isolation only, with tmux inside the sandbox as the process owner.
3. Treat gateway restarts as interrupting, and rely on native agent resume. That is a separate capability, still to be tested.

Gateway HA (Postgres plus replicas) addresses control-plane availability, not workload survival, and is excluded from stage B.

## Unknowns that only an experiment can settle
1. The counter nonce across graceful and forced gateway restart.
2. The gateway-start race: the supervisor is NotReady, and the first reconcile could suspend the workload.
3. Whether `sandbox get` reads Ready only after the supervisor reconnects. Source says yes (`compute/mod.rs:8063-8085`); Podman showed Ready before the process existed.
4. Outage longer than the 1 h JWT TTL; a long API-server outage; a cold gateway start without the API server.
5. Whether the instance id changes when only the supervisor pod is replaced.
6. The cluster's kernel, Landlock and seccomp support, and PSA admission of the sysctl, `supplementalGroupsPolicy` and certgen Jobs.
7. A true SIGKILL, which needs node access.
8. Changes to the reconcile of existing pods in Agent Sandbox v1.0.4–v1.0.12.
9. Gateway **upgrade** and rollback across versions, which is not in this matrix.
