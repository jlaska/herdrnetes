# EXP-008 Stage B: OpenShell Kubernetes driver lifecycle (results)

**Status:** executed under owner approval (2026-11-24) of items 2–4 of the Stage B proposal, revision 4 (draft PR #42). The findings below are **proposed**, not accepted. ADR-0001, REQ-009 and REQ-011 are unchanged.

## Scope and environment

- One existing home-lab cluster (three Talos nodes; Kubernetes v1.36.6; kernel 6.18). Cluster, node and host names are redacted (`node-a`, `node-b`; `argo-app-*`).
- OpenShell v0.1.9, gateway image `ghcr.io/nvidia/openshell/gateway@sha256:1fd9e1e807990e66c9486a28d3ce9d649fd7528df48d0e830d2de2148b52dfe5`. One-replica StatefulSet, `workspace_mode = "shared"`. Supervisor and sandbox runtime images `0.1.9`.
- Agent Sandbox v1.0.12, controller `registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:b0ee91a42129919179baf5f429979fee3ab1a3dac6855110b4648a6ff4b44103`.
- CLI v0.1.9 (musl, sha256 `2db8e54f…7c69`; release attestation verified). It ran under an isolated HOME with the owner's interactive OIDC login, which was logged out at the end.
- Workload: the Stage A synthetic counter image, `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16`. Created with:
  ```
  sandbox create --detach --tty --restart-policy never --no-auto-providers -- /usr/local/bin/counter.sh /sandbox/out
  ```
- Freeze: GitOps merges were held by the owner for the whole run. Renovate had no open PRs for either app. The harness checked the Argo state and the GitOps `main` SHA at every step boundary.
- Harness: [`stageb.sh`](stageb.sh), [`ackpty.py`](ackpty.py), [`gaps.py`](gaps.py).
  - It runs a fixed allowlist of seven mutations (M1–M7).
  - Kubernetes reads go through a read-only wrapper.
  - Each step runs once, with no retries.
  - A trap during B2 restores the gateway StatefulSet to 1 replica if the step exits early.

### Identity sources

| Source | What it records |
|---|---|
| **P** (process) | Read through a read-only exec in the workload container: counter PID, `/proc` start time, nonce and boot ID. |
| **W** (workload) | Workload pod UID and container ID. |
| **ACK** | A fresh `sandbox connect` in a PTY types `mark <word>`. The counter must answer `ACK <word> pid= start= nonce=` with the same identity. |
| **Counter log** | One line per second, checked by `gaps.py`: any gap over 3 s or a reset of `n` counts as a discontinuity. |

## Runs

### Attempt 1 (`1124-2120`): B1 failed, a configuration prerequisite

- `sandbox create` timed out after 300 s at `ConfigurationPending`. The gateway then rolled the sandbox back itself ("rolled back stale fail-closed sandbox-runtime bootstrap").
- **Cause:** the gateway's `grpc_endpoint` had no `https://` scheme. The supervisor only uses TLS for `https://` endpoints, and the gateway accepts only TLS.
- The owner corrected the endpoint.

### Attempt 2 (`1124-2135`): B1 failed, a node prerequisite

- The supervisor now authenticated (`sandbox_jwt`), but the workload's `agent` container exited about 1 s after starting, and the pod went to `Failed`.
- The gateway again rolled the sandbox back at 300 s.
- **Cause (owner):** the Talos nodes needed a ptrace adjustment before OpenShell could work. The owner patched the nodes.
- This attempt also showed a sampler launch defect, which was fixed. It is why attempt 1 has no sampler data.

### Run 3 (`1124-2222`): complete

All steps passed their harness checks, followed by cleanup.

| Step | Event | Process continuity | Reattachment |
|---|---|---|---|
| **B1** | Baseline, 300 s bootstrap window, then a 600 s soak with an identity read every 30 s | **Survived**: one identity throughout (PID 71, start 50438614, nonce `230650de7ef3e973`); counter n=255→895, max gap 1.01 s, 0 discontinuities | **Same process**: the ACK at n=894 matched P |
| **B2** | Graceful gateway restart: scale 0, then scale back to 1 at +91 s. The old pod was gone at 1.4 s; a new pod UID was Ready at 104.7 s; the sandbox was Ready at 122.3 s | **Survived**: P and W unchanged; n=879→1033, max gap 1.00 s, 0 discontinuities | **Same process** through the new gateway: the ACK at n=1032 matched |
| **B3** | API-initiated short-grace termination: `delete pod <gateway> --grace-period=1`. A new pod UID was Ready at 8.3 s; the sandbox was Ready at 16.1 s | **Survived**: P and W unchanged; max gap 1.01 s, 0 discontinuities | **Same process**: the ACK at n=1172 matched |
| **B5** | Positive control: delete the workload pod | **Unavailable**: the original process ended with its pod; no replacement process ran | **Not possible**: the sandbox stayed `Error` until it was deleted |

Notes on the table:

- Timings for B2 are measured from the scale-down; timings for B3 from the delete.
- B2's outage (about 105 s until the gateway was Ready) was within the 240 s ceiling.
- **B3 is not a pure SIGKILL test.** It is an API delete with a 1 s grace period, so the gateway process received SIGTERM first. Nothing here shows survival of an abrupt gateway process kill or node loss. No node access was used.
- **Credential expiry** is ruled out as a confounder:
  - the gateway JWT TTL is 3600 s, and the sandbox lived about 25 min (03:22–03:47 UTC);
  - no token-expiry annotations were present (`b2-token-expiry.txt`);
  - the only process loss (B5) was caused deliberately.
- **B5 details** (`obs/b5-times.txt`; `samples/pods-watch.jsonl`):
  - The original workload pod UID `b84a7082…` was removed at 3.7 s.
  - Agent Sandbox created a replacement with the same name and a **different UID**, `54089716…`, at 3.9 s.
  - About 2 s later, while it was still `Pending`, the gateway deleted the replacement ("sandbox-runtime workload generation changed; suspending stale boundary").
  - The gateway set the sandbox phase to `Error` as soon as the delete happened (Agent Sandbox reason `PodTerminating`).
  - **B5 therefore validates pod-replacement detection (W), not process-level detection (P).** The replacement never ran, so no exec could read a new PID or nonce. The detector was never shown telling apart a second live process.
- **Topology:** the supervisor pod and the workload pod ran on different nodes. Only the supervisor pod carries `openshell.ai/sandbox-id`; the workload pod is labelled `openshell.ai/boundary-pair=<id>`. The harness was corrected to select pods by either label before `b1-soak` ran.

### Cleanup compared with B0

- `sandbox delete` returned rc 0. No pod, PVC, PV or Sandbox CR from the test remains.
- The gateway pod UID changed (B2 and B3 replaced it), as expected.
- The post-run inventory (`inv/`) differs from B0 only in the gateway StatefulSet's `generation` (10 → 12), from B2's two scale operations. Its UID and `replicas=1` are unchanged.
- The gateway data PVC, the controller, the CRD, RBAC and both Argo apps are unchanged. The Argo apps are `Synced/Healthy` at the owner's fix commit.
- The CLI is logged out.

## Proposed findings (for owner review)

- **FIND-088** (proposed): with the OpenShell v0.1.9 Kubernetes driver and Agent Sandbox v1.0.12, the canonical main process **survived a graceful gateway restart** with about 105 s of gateway unavailability, and a new `connect` reattached to the same process. This contrasts with the Podman driver (FIND-083), where a graceful restart replaced the process.
- **FIND-089** (proposed): the process also **survived an API-initiated, 1 s-grace gateway pod termination**, with the same reattachment. A pure SIGKILL, node loss or gateway OOM was not tested.
- **FIND-090** (proposed): when the workload pod is deleted, the sandbox **fails closed**:
  - the process is lost;
  - Agent Sandbox's same-name replacement pod (new UID) is deleted by the gateway before it starts;
  - the sandbox stays `Error` until it is deleted explicitly.

  Workload-pod loss is therefore a hard interruption with no automatic recovery. Process-level detection of a replacement process remains unvalidated.
- **FIND-091** (proposed): prerequisites found on this installation:
  - an `https://` scheme on `grpc_endpoint`;
  - a Talos node ptrace adjustment (owner-applied).

  Without them, a sandbox fails closed: it stays `ConfigurationPending` until the gateway rolls it back at 300 s. The CLI reports only a timeout, and the rollback deletes the pod and its logs.

Scope of all four: one run, one synthetic process, one cluster, the versions above, a one-replica gateway, and a shared workspace.

## Conclusions

1. **Did the Kubernetes driver demonstrate process continuity?** Yes, for the tested gateway lifecycle events: graceful restart (B2) and API short-grace termination (B3). Over a 10-minute soak and both events, all identity sources agreed and the process was continuous. That is not true of workload-pod loss (B5), which ends the process and leaves the sandbox in `Error`.
2. **Lifecycle events not tested:**
   - abrupt gateway kill (SIGKILL / OOM) or node loss;
   - a gateway outage longer than about 105 s or longer than the JWT/credential TTLs;
   - gateway image upgrade or rollback;
   - supervisor pod deletion or restart;
   - Agent Sandbox controller restart or upgrade;
   - node drain or reboot of either the workload node or the supervisor node;
   - a workload container crash under other restart policies;
   - a multi-replica gateway;
   - multi-hour soaks;
   - natural process completion;
   - a real agent with credentials;
   - process-level detection of a replacement process.
3. **Is moving toward Stage C justified?** The evidence supports *proposing* Stage C. It does not authorize it. Gateway restarts no longer replace the agent process on this driver, which removes the main Stage A blocker for the tested events. Two things should be addressed or explicitly accepted before Stage C:
   - workload-pod loss is unrecoverable without native agent session resume (FIND-090);
   - abrupt gateway kills and supervisor-pod loss are untested.

   Stage C needs separate owner approval. No further Stage B expansion was performed.

## Evidence

[`evidence/`](evidence/) holds one directory per run. Redactions:

- node, cluster and app names replaced;
- raw gateway and controller logs, raw PTY transcripts and the full inventory kept local;
- pod and CR JSON filtered to identity fields only (no env, Secret references or tokens).

Contents of each run directory:

| Path | Contents |
|---|---|
| `timeline.log` | Every mutation and step result. |
| `obs/` | Per-step identity reads (P, W, G), plus `*-compare.txt`, `*-gaps.txt`, `*-times.txt` and the counter logs. |
| `ack/` | ACK results. |
| `samples/` | 1 Hz pod and `sandbox get` polls, P every 5 s, and watch streams. |
| `inv/` | Diff of the post-run inventory against B0. |
