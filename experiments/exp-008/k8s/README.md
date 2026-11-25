# EXP-008 Stage B: OpenShell Kubernetes driver lifecycle (results)

**Status:** executed under owner approval (2026-11-24) of items 2–4 of the Stage B proposal, revision 4 (draft PR #42). The findings below are **proposed**, not accepted. ADR-0001, REQ-009 and REQ-011 are unchanged.

**Approved proposal (immutable reference).** Revision 4 is commit [`33291effcee234bf34c732bee0e85b1a53e97843`](https://github.com/jlaska/herdrnetes/commit/33291effcee234bf34c732bee0e85b1a53e97843), file [`experiments/exp-008/STAGE-B-PROPOSAL.md` at that commit](https://github.com/jlaska/herdrnetes/blob/33291effcee234bf34c732bee0e85b1a53e97843/experiments/exp-008/STAGE-B-PROPOSAL.md).
- Git blob `3d28a9e74fd711fb55a5ee117a48063f93826e76`; file sha256 `da913c31aa690afae53802c8043be5f4e20d20b88ca805b1e382b3b43f51e007`.
- On 2026-11-24 this was the head of #42 (`refs/pull/42/head`).
- References to "revision 4", "section N" or "item N" in this document mean that text. "B0" means the read-only inventory recorded in its section 2.4 (2026-11-24, about 21:20 UTC). It is **not** the baseline the run-3 cleanup was diffed against (see [Cleanup](#cleanup-compared-with-the-run-3-pre-run-baseline)).
- Later commits to #42, or a squash merge of it (which creates a new commit), do not change what was approved.
- #42 itself is not modified by this PR.

## Scope and environment

- One existing home-lab cluster (three Talos nodes; Kubernetes v1.36.6; kernel 6.18). Cluster, node and host names are redacted (`node-a`, `node-b`; `argo-app-*`).
- OpenShell v0.1.9, gateway image `ghcr.io/nvidia/openshell/gateway@sha256:1fd9e1e807990e66c9486a28d3ce9d649fd7528df48d0e830d2de2148b52dfe5`. One-replica StatefulSet, `workspace_mode = "shared"`. Supervisor and sandbox runtime images `0.1.9`.
  - `workspace_mode` is OpenShell's mapping of workspaces to Kubernetes **namespaces**. `shared` means all workspaces use one sandbox namespace (OpenShell `docs/kubernetes/workspaces.mdx` at `ce58cf8`). It says nothing about storage.
  - The sandbox's `/sandbox` was its own per-sandbox workspace PVC (Longhorn, reclaim `Delete`), deleted with the sandbox. It was **not** the shared workspace PVC of ADR-0001 / REQ-004.
- Agent Sandbox v1.0.12, controller `registry.k8s.io/agent-sandbox/agent-sandbox-controller@sha256:b0ee91a42129919179baf5f429979fee3ab1a3dac6855110b4648a6ff4b44103`.
- CLI v0.1.9 (musl, sha256 `2db8e54f…7c69`; release attestation verified). It ran under an isolated HOME with the owner's interactive OIDC login, which was logged out at the end.
- Workload: the Stage A synthetic counter image, `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16`. Created with:
  ```
  sandbox create --detach --tty --restart-policy never --no-auto-providers -- /usr/local/bin/counter.sh /sandbox/out
  ```
- Freeze: GitOps merges were held by the owner **within each run**. Renovate had no open PRs for either app. The harness checked the Argo state and the GitOps `main` SHA at every step boundary against the values it recorded at that run's `pre` step.
  - Between runs the configuration changed on purpose. GitOps `main` moved from `a604ce9` (attempts 1 and 2) to the owner's fix commit `1978dc1` (run 3), and the nodes were patched outside GitOps. See [`evidence/baseline-drift.md`](evidence/baseline-drift.md).
  - **Harness limitation (observed):** the `pre` step records the Argo state but does not require Synced/Healthy. Attempt 2 started with `argo-app-openshell` **OutOfSync/Progressing** (`1124-2135/timeline.log`, line 1), and the harness proceeded. Run 3 started Synced/Healthy.
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

### Preflight (`0000-0000`): stopped before any mutation

- 2026-11-24T22:02:42Z: `pre` stopped with "CLI registration exp008b missing (owner login first)". No mutation ran.
- Its pre-run inventory (kept local) is identical to attempt 1's. It is the harness-form snapshot closest to B0 ([`evidence/baseline-drift.md`](evidence/baseline-drift.md)).

### Attempt 1 (`1124-2120`): B1 failed, the gateway endpoint (plus a masked workload failure)

- **CLI:** `sandbox create` failed at 02:26:07Z, about 319 s after the create at 02:20:48Z (`timeline.log`). Its message was "sandbox provisioning timed out after 300s. Last reported status: ConfigurationPending: Waiting for effective configuration validation before workload activation" (`obs/b1-create.err`).
- **Retained evidence is thin.** This attempt has no sampler data, because of a sampler launch defect found and fixed in attempt 2. The gateway container was replaced at 02:33:48Z, before any log was captured, so **no retained log** shows what the gateway did with this sandbox. An earlier version of this README said the gateway "rolled the sandbox back itself". That is consistent with attempt 2 but is not in retained evidence for attempt 1.
- **Workload pod events (observed, retained by chance).** Attempt 2's event watch replayed attempt 1's still-live Kubernetes events (`1124-2135/samples/events-watch.jsonl`, lines 1–16):
  - the workload pod `default--exp008b-1124-2120` was created at 02:20:48.99Z;
  - its containers started by 02:21:07Z;
  - Agent Sandbox reported `SandboxReady` at 02:21:07.53Z;
  - it reported `PodFailed` at 02:21:09.61Z.

  This is the same signature as attempt 2's workload failure. The node patch was applied only after attempt 2, so it was also absent in attempt 1. That it caused this pod failure is an inference. The CLI showed only the endpoint symptom.
- **Cause of the CLI symptom (owner diagnosis):** the gateway's `grpc_endpoint` had no `https://` scheme. The supervisor uses TLS only for `https://` endpoints, and the gateway accepts only TLS, so configuration validation never completed. This is not re-derived from source or from retained logs.
- The owner corrected the endpoint before attempt 2. GitOps `main` did not move until `1978dc1` (after attempt 2). Attempt 2's `pre` saw the OpenShell app OutOfSync at `a604ce9` and the StatefulSet at `generation` 10 (attempt 1: 9). See [`evidence/baseline-drift.md`](evidence/baseline-drift.md).

### Attempt 2 (`1124-2135`): B1 failed, the node prerequisite

- **The endpoint fix took effect** (observed in [`obs/gateway-excerpt.txt`](evidence/1124-2135/obs/gateway-excerpt.txt), a redacted excerpt of the run-3 gateway log):
  - the gateway container started at 02:33:48Z;
  - `CreateSandbox` completed at 02:36:06.24Z;
  - the sandbox authenticated with `protocol:sandbox_jwt` at 02:36:07.75Z.

  No retained record shows `ConfigurationPending` in this attempt.
- **The workload failed** (`samples/pods-watch.jsonl`, `samples/pods-1hz.txt`; timings to about 1 s):
  - the `agent` container was Running and ready at 02:36:24.97Z;
  - it was not ready by 02:36:25Z;
  - the pod was `Failed` (restartCount 0) by 02:36:27–28Z, about 20 s after the create.

  The container's exit code and reason are **not recorded** (the samplers kept only readiness and restart counts), and the rollback deleted the pod before its logs were captured.
- **The supervisor pod** stayed Running and not Ready (its readiness probe was refused) until about 02:41:09Z, when it went `Failed`.
- **Gateway rollback:** at 02:41:19.23Z, 313 s after the create, the gateway logged "rolled back stale fail-closed sandbox-runtime bootstrap" and issued `DeleteSandbox`. A 300 000 ms response completed at 02:41:07.75Z; the record does not show which request it was.
- **CLI:** the create failed at 02:41:19.27Z (313.4 s) with a **different** message from attempt 1: "sandbox provisioning stream ended before reaching terminal phase". It names neither timeout nor phase.
- **Cause (owner diagnosis):** the Talos nodes needed a ptrace adjustment before OpenShell could work, and the owner patched them. The exact node setting is not recorded here (approval checklist item in the Stage C proposal). The workload failure is observed. Its attribution to ptrace is the owner's and was not reproduced.
- This attempt started while `argo-app-openshell` read OutOfSync/Progressing (see the Freeze note above).

### Deviations from revision 4 (recorded for owner review)

1. **B1 ran three times, with configuration changes between attempts.** Revision 4, section 5 allowed "at most one pre-approved, identical re-run" per step.
   - Attempts 1 and 2 failed at `create`, before any fault was injected, and the owner changed the gateway configuration and the nodes between them.
   - Run 3 is therefore a run on a corrected configuration, not an identical re-run.
   - This record does not show whether the owner's approval covered the extra attempts; the owner should confirm.
2. **Cleanup baseline.** The cleanup diff used the run-3 pre-run inventory, not B0 (see Cleanup below). It also showed StatefulSet `generation` 10 → 12, which is outside section 6 step 7's allowed differences.
3. **Harness `pre` check** proceeded with the OpenShell app OutOfSync/Progressing in attempt 2 (see Freeze above). It does not affect run 3, which started Synced/Healthy.

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
  - the gateway JWT TTL is 3600 s (`gateway_jwt.ttl_secs = 3600` in the rendered `openshell-config`, read in B0: revision 4, section 2.4; not re-read in run 3), and the sandbox lived about 25.5 min (created 03:21:48Z, deleted 03:47:20Z);
  - no token-expiry annotations were present (`b2-token-expiry.txt`);
  - the only process loss (B5) was caused deliberately.
- **B5 details** (`obs/b5-times.txt`; `samples/pods-watch.jsonl`):
  - The harness first saw the original workload pod UID `b84a7082…` gone at 3.7 s, and first saw a replacement with the same name and a **different UID**, `54089716…`, at 3.9 s. These are poll-detection times from `t0` (just before the delete), not event times. The watch shows the original's deletion and the replacement's `creationTimestamp` at 03:41:51Z (1 s resolution), 2–3 s after `t0`.
  - While the replacement was still `Pending`, the gateway logged "sandbox-runtime workload generation changed; suspending stale boundary" at 03:41:55.85Z and deleted it. The replacement's `deletionTimestamp` is 03:41:55Z, about 4 s after its creation (3–5 s at 1 s resolution) and about 2.2 s after the harness first saw it. The log line is in [`obs/b5-gateway-excerpt.txt`](evidence/1124-2222/obs/b5-gateway-excerpt.txt).
  - The gateway set the sandbox phase to `Error` within about 0.5 s of the delete. `sandbox get` read Error at 03:41:49.64Z against a delete at 03:41:49.19Z. The gateway logged "Sandbox failed to become ready … reason=PodTerminating" at 03:41:49.28Z.
  - The original pod's last recorded phase was `Succeeded`.
  - **B5 therefore validates pod-replacement detection (W), not process-level detection (P).** The replacement never ran, so no exec could read a new PID or nonce. The detector was never shown telling apart a second live process.
- **Topology:** the supervisor pod and the workload pod ran on different nodes. Only the supervisor pod carries `openshell.ai/sandbox-id`; the workload pod is labelled `openshell.ai/boundary-pair=<id>`. The harness was corrected to select pods by either label before `b1-soak` ran.

### Cleanup compared with the run-3 pre-run baseline

**Baseline used.** The harness takes a fresh inventory at the `pre` step of every run (`inv/b0-pre`; the name is historical) and diffs the post-run inventory against it. For run 3 that baseline was captured at 2026-11-25T03:21:37Z, **after** both prerequisite fixes. It is not the original B0 (revision 4, section 2.4), and the cleanup result says nothing about B0.

The two baselines differ. Between B0/attempt 1 and run 3:
- GitOps moved from `a604ce9` to `1978dc1`;
- the gateway StatefulSet `generation` went from 9 to 10, and its pod was replaced;
- the `openshell-config` `resourceVersion` changed twice;
- the certgen ServiceAccount, Role and RoleBinding were re-created;
- the nodes were patched outside any inventory.

Image digests are unchanged. Details: [`evidence/baseline-drift.md`](evidence/baseline-drift.md). The fixes are intended to stay; they are part of the configuration that run 3 tested.

**Result against the run-3 baseline:**
- `sandbox delete` returned rc 0. The harness checked that no pod, PVC, Secret, Service or NetworkPolicy carrying either sandbox label, no pod or PVC with the sandbox's name, and no Sandbox CR remained (`timeline.log`). PVs were not listed separately. The post-run object listing is not committed.
- The gateway pod UID changed (B2 and B3 replaced it), as expected.
- The post-run inventory (`inv/`) differs from the run-3 baseline only in the gateway StatefulSet's `generation` (10 → 12), from B2's two scale operations. Its UID and `replicas=1` are unchanged.
  - **Deviation:** revision 4, section 6 step 7 allowed only the gateway pod's UID and age, and events, to differ. The `generation` change is an expected side effect of the approved `scale` steps, but it was not on that list.
- No other inventory file differs. That covers the gateway data PVC, the controller, the CRD, RBAC, and the Argo state (`argo.txt`: both apps Synced/Healthy at `1978dc1`). This is inferred from the absence of a diff; the full pre and post inventories are kept local.
- The CLI is logged out (`timeline.log`, `gateway logout rc=0`).

**Not established:** that the installation matches B0. That the nodes match their pre-experiment state (the ptrace patch is outside every inventory, and is intended to stay).

## Proposed findings (for owner review)

- **FIND-088** (proposed): with the OpenShell v0.1.9 Kubernetes driver and Agent Sandbox v1.0.12, the canonical main process **survived a graceful gateway restart** with about 105 s of gateway unavailability, and a new `connect` reattached to the same process. This contrasts with the Podman driver (FIND-083), where a graceful restart replaced the process.
- **FIND-089** (proposed): the process also **survived an API-initiated, 1 s-grace gateway pod termination**, with the same reattachment. A pure SIGKILL, node loss or gateway OOM was not tested.
- **FIND-090** (proposed): when the workload pod is deleted, the sandbox **fails closed**:
  - the process is lost;
  - Agent Sandbox's same-name replacement pod (new UID) is deleted by the gateway before it starts;
  - the sandbox stays `Error` until it is deleted explicitly.

  Workload-pod loss is therefore a hard interruption with no automatic recovery. Process-level detection of a replacement process remains unvalidated.
- **FIND-091** (proposed, refined 2026-11-24 after evidence review): this installation had two independent prerequisites. They fail at different layers, with different symptoms, and a missing endpoint scheme can mask a missing node fix.
  - **FIND-091a: gateway endpoint (control plane).** The gateway's `grpc_endpoint` needs an `https://` scheme (owner diagnosis).
    - Without it the sandbox never passes configuration validation, and `sandbox create` fails after 300 s with "timed out … ConfigurationPending: Waiting for effective configuration validation before workload activation" (attempt 1, observed).
    - After the owner's correction, the sandbox authenticated (`sandbox_jwt`) about 2 s after create (attempt 2, observed). Attributing that change to the scheme is the owner's diagnosis.
  - **FIND-091b: Talos node ptrace adjustment (workload).** The Talos nodes needed a ptrace adjustment (owner diagnosis and owner-applied; exact setting not recorded here).
    - Without it the workload's `agent` container exits about 1 s after it starts and the workload pod goes `Failed`, although Agent Sandbox briefly reports `SandboxReady` (attempt 2, observed; the exit code is not recorded).
    - The supervisor stays Running and not Ready. The gateway rolls the sandbox back at about 313 s ("rolled back stale fail-closed sandbox-runtime bootstrap"), and the CLI fails with "provisioning stream ended before reaching terminal phase" (attempt 2, observed).
    - The same workload signature (`SandboxReady`, then `PodFailed` 2 s later) also appears in attempt 1's events, behind the endpoint symptom (observed; that it had the same cause is inferred).
  - **Common to both:** the sandbox fails closed. Neither CLI message names its cause. The gateway's rollback deletes the pods, so the container logs and exit status are lost unless something captures them first.
  - **Implication for later stages (proposal):** record the container termination state (exit code, reason, `lastState`) and the workload container logs on any pod transition to `Failed`, before a rollback can delete them.

Scope of all four: one run (FIND-091: two failed attempts), one synthetic process, one cluster, the versions above, a one-replica gateway, `workspace_mode = "shared"` (a namespace mapping), and the default per-sandbox workspace PVC.

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
| `inv/` | Diff of the post-run inventory against that run's own pre-run inventory (`b0-pre`, taken at the `pre` step; not B0). The `b0-pre` and `post` trees are local. |

Additions from the 2026-11-24 evidence review, all redacted:
- [`baseline-drift.md`](evidence/baseline-drift.md): how the per-run baselines differ.
- [`1124-2135/obs/gateway-excerpt.txt`](evidence/1124-2135/obs/gateway-excerpt.txt): attempt 2 gateway lines.
- [`1124-2222/obs/b5-gateway-excerpt.txt`](evidence/1124-2222/obs/b5-gateway-excerpt.txt): B5 gateway WARN lines.

**Not committed, but kept locally unchanged:**
- the preflight run's inventory (its `timeline.log` is committed as [`0000-0000/timeline.log`](evidence/0000-0000/timeline.log));
- the per-run `refs.txt`, `argo-ref.txt`, `gitops-ref.txt` and `STOPPED` markers;
- the `*.out` CLI outputs, which `.gitignore` excludes;
- the full inventories, the raw logs and the PTY transcripts.

Attempts 1 and 2 have empty `ack/` and `inv/` directories, because they stopped before any ACK or post-run inventory.

**Known evidence limits:**
- Attempt 1 has no sampler data and no gateway log.
- No run recorded a container's exit code or reason.
- The committed `1124-2222/obs/b1-t0` holds the soak start (03:26:48.5Z), because the harness overwrites the create time; `timeline.log` has the create time.
