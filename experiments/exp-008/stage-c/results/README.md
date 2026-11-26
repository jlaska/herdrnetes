# EXP-008 Stage C results: two stopped runs (2026-11-25), C0–C3 not reached

**Agent-generated record for owner review.** Nothing here is accepted. The findings below are *proposed*. Stage C, run under the owner's conditional C0–C3 authorization of 2026-11-25, **did not reach C1, C2 or C3**:

| Run | Harness commit | Stopped at | Distinct failure | Model calls |
|---|---|---|---|---|
| `1125-2032` | `2260f43` | `sampler-start` (before any mutation) | Harness defect: a liveness gate read a file that `jq` was still buffering | none (no sandbox was created) |
| `1125-2153` | `bdbbd6f` | `c0-baseline` | **Experiment failure (C0, H4):** OpenShell's credential proxy refused all 12 model requests (`credential_placement_mismatch`), because the launcher's `apiKeyHelper` made Claude Code send the placeholder as `Authorization: Bearer`. Two harness defects were found alongside it | 12 requests sent by Claude Code, all refused at the supervisor proxy before any upstream write |

The owner closed out for the night after run 2, without further live attempts. The harness, task package, offline tests and the proposed (not executed) fixes are on PR #45 (branch `agent/exp-008-stage-c-harness`). Commit references below point there; the harness files are not on `main` until the owner merges #45.

Labels: **O** observed in this run's evidence, **S** source or static-binary review, **I** inference.

## Environment

- Existing EXP-008 Stage B installation (OpenShell 0.1.9 Kubernetes driver, Agent Sandbox 1.0.12; gateway image `sha256:1fd9e1e8…`, controller `sha256:b0ee91a4…`, both as recorded by Stage B). One-replica gateway StatefulSet (`generation` 12 at both `pre` steps). Cluster, node and gateway host names are redacted in the evidence (`<redacted>`, `node-a`/`node-b`).
- Agent image `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6…` (EXP-006), Claude Code **2.1.323** (binary sha256 `604d29a6…`), model `claude-haiku-5-5`, effort medium, Bash tool only. No image rebuild.
- Provider `exp008c-anthropic` of the owner-imported profile `claude-code-exp008c` (credential `ANTHROPIC_API_KEY`, `auth_style: header`, `header_name: x-api-key`, endpoint `api.anthropic.com:443`, binary `/usr/local/bin/claude`). Dedicated Console workspace with a $5 cap (owner). Owner-confirmed GitOps freeze, OIDC login and redaction list.
- All harness calls ran under `env -i` with `HOME`, `USER`, `LOGNAME`, `TERM`, `LANG` only. The first `pre` invocation of run 1 was refused by the harness's own credential-variable guard (the lead's Claude Code session variables and `SSH_AUTH_SOCK` were present), before any cluster access (O, lead notes).

## Run `1125-2032` (run ID 20:32 America/New_York; `pre` at 20:33): stopped at `sampler-start`

- `pre` passed: both Argo apps Synced/Healthy at GitOps `05fed44`, digests as Stage B, gateway Ready with 1 replica, no Sandbox CRs, provider and profile present (O, [`timeline.log`](evidence/1125-2032/timeline.log)).
- `sampler-start` stopped (`STOPPED`): `samples/pods-watch.jsonl` was empty 8 s after start. The 1 Hz sample was fine (O).
- Cause: `jq` block-buffers its output when writing to a file; a namespace holding only the gateway pod produces too few watch events to fill the buffer (I; reproduced locally without the cluster by the lead, and independently by a Sonnet failure analysis). Stage B used the same pipeline without a gate. The sampler's `kill 0` also discards jq's unflushed tail, so Stage B's watch files may lack their last events (I; Stage B evidence unchanged).
- `cleanup` ran on its stop path: no delete needed (`c0-create` never ran), no experiment object, gateway replicas 1 (O).
- Fix (`bdbbd6f`, PR #45): `jq --unbuffered`, a polled gate, regression test with a negative control. The owner approved a re-run with it.

## Run `1125-2153` (run ID 21:53 America/New_York; `pre` at 21:54): C0 failed

### Checkpoint C0 (as reported to the owner)

- **Process and workload identity (O, [`obs/c0-base-summary.txt`](evidence/1125-2153/obs/c0-base-summary.txt), [`samples/P-5s.txt`](evidence/1125-2153/samples/P-5s.txt)):** sandbox Ready 17.4 s after create; one workload pod and one supervisor pod, on different nodes. The agent was the sandbox's main process: PID 71, uid 10001, the launcher record (pid, `/proc` start, nonce) equal to the live process, and the same identity in all 36 P samples (about 6.3–6.7 s apart) up to 02:58:19Z, after cleanup began and before the delete. Clock skew workload vs workstation 80 ms (±86 ms). Task package sha256 `3ff03abc…` (`obs/c0-pkg.txt`).
- **Credential boundary (O):** the agent environment held only the placeholder reference (`keyref_form=placeholder key_form=absent`, launcher `key_form=placeholder`); no real-key-shaped value in the readable process environments (2 of 3 readable, 1 unreadable) or in any file in the workload (`obs/c0-X4.txt`: `env_real_key_shape=0`, `fs_real_key_shape_files=0`, `fs_placeholder_files=0`). Egress probes (TCP connects only): a disallowed host and `python3 → api.anthropic.com` were **blocked** under `openshell sandbox exec` (`PermissionError`, `obs/c0-X5-sandbox.txt`) and under `kubectl exec` outside OpenShell mediation (`gaierror`, `obs/c0-X5-kubectl.txt`). The supervisor recorded both sandbox-exec probes as `transparent_tcp_policy_denied` and also refused `downloads.claude.ai`: one DNS refusal (`NET:REFUSE`, `policy_dns_ineligible`) and two denied `claude` connects (`transparent_tcp_policy_denied`) (O, `obs/c0-proxy-decisions.tsv`).
- **Model access (O, [`obs/c0-proxy-decisions.tsv`](evidence/1125-2153/obs/c0-proxy-decisions.tsv)):** Claude Code sent **12 requests** to `POST https://api.anthropic.com/v1/messages` between 02:54:33Z and 02:58:17Z. Each request produced one event of each kind: an OPA `NET:OPEN` ALLOWED (`/usr/local/bin/claude → api.anthropic.com:443`), an L7 `HTTP:POST` ALLOWED (`request_sequence` 1), a credential-binding `HTTP:POST` DENIED with `credential_placement_mismatch` (`request_sequence` 2) and a `FINDING:BLOCKED` of type `openshell.provider_credential.placement_mismatch` (`request_sequence` 3; its message, "Provider credential used at an unauthorized request location", is in the local log). `request_sequence` numbers events within one request (S), so these are 12 requests, not 24. The table is derived from the supervisor log (structured fields only; the log stays local).
- **Model-driven progress:** none. The task ledger shows 0 attempts, 0 progress and 0 refusals for the whole run; the transcript existed and grew from 15 to 23 lines in identical 1216-byte steps every 26–39 s (O, [`samples/T-10s.txt`](evidence/1125-2153/samples/T-10s.txt)), consistent with recorded API errors and retries (I). The transcript itself was not retained (harness defect below).
- **Reattachment, terminal state, conversation continuity:** not reached. The first-attach and codeword steps come after the transcript probe.
- **Classification:** **C0 failed: model access through OpenShell's credential proxy (H4) does not work with the launcher as designed.** It is not an image dependency failure (the agent started as uid 10001 with the expected identity record).
- **Spend:** no transcript usage was obtainable. The refused requests were answered by the proxy and not forwarded (S), so no Anthropic usage is expected (I). **Not confirmed:** the Console figure is the authority and had not been checked when this was written. *Closeout (owner-reported, 2026-11-26): the Console currently records no spending for this experiment; see [Owner closeout](#owner-closeout-owner-reported-2026-11-26).*

### Cause (verified offline after the run; not by a further live attempt)

- **Claude Code 2.1.323 (S, static review of the pinned binary):** the first-party header builder sets `Authorization: Bearer <value>` for `ANTHROPIC_AUTH_TOKEN` or the `apiKeyHelper` output, while an approved `ANTHROPIC_API_KEY` is sent only as `X-Api-Key`.
- **Reproduced (O, local, cluster-free):** `tests/header-capture-test.sh` on PR #45 runs the pinned binary with the run-2 launcher and settings against a mock endpoint in a loopback-only network namespace: every request carried `Authorization: Bearer <placeholder>` (made-up placeholder) in addition to `x-api-key`.
- **OpenShell v0.1.9 (S, Sonnet source review):** a provider credential has exactly one permitted placement, here the `x-api-key` header; a placeholder in any other header yields `credential_placement_mismatch`, and the rewrite runs before any upstream write, returning 403 to the client (`openshell-core/src/secrets.rs`, `openshell-supervisor-network/src/l7/relay.rs`).
- The `apiKeyHelper` had been chosen to avoid Claude Code's interactive "Detected a custom API key … use this API key?" dialog (EXP-006 s3b path, which had no proxy). The conflict only appears with OpenShell's single-placement credential binding.

### Harness defects found in run 2

1. The transcript probe executed `stagec.sh` directly although the file is mode 644: 179 × "Permission denied" (O, lead notes). The C0 stop message ("no transcript with assistant entries within 180 s") was therefore reached because the probe could not run. With every request refused, no assistant entry could exist, so the outcome would have been the same (I).
2. The final snapshot needs the transcript path that the probe records, so cleanup could not copy the transcript ("final snapshot failed"): the transcript was **not retained** (O, `timeline.log`).
3. `post` named its diff files `diff-<name>.txt.txt` and compared the provider/profile lists byte-wise, so the owner's correct deletion was classified `UNEXPECTED` (an empty provider list printed as one blank line; the profile table's columns re-aligned once the longest name was gone) (O, `inv/diff-2/`).
4. The sampler kept polling for about 10 h after cleanup, until `sampler-stop` (read-only; samples after cleanup + 120 s are trimmed from this record, full files local).
5. `export.sh` did not redact private IPv4 addresses inside event messages; its scan refused the first export (fail-closed as designed).

All five are fixed on PR #45 (`f8a1d5b`, `ccd2d95`) with regression tests.

## Cleanup (both runs)

- `cleanup` ran once per run. Run 2: `sandbox delete` rc 0; no pod, PVC, Secret, Service, NetworkPolicy, ConfigMap, ServiceAccount, Role or RoleBinding carrying the sandbox's labels or name, no Sandbox CR, no PV of its PVCs and no Cilium policy naming it remained; gateway replicas 1 (O, `timeline.log`). `obs/cleanup-pvcs.txt` is the sandbox's PVC → PV record taken **before** the delete, which the residue check then confirmed gone; `obs/cleanup-cilium-residue.txt` is empty.
- Owner deleted the provider and profile and verified their absence (owner). Final `post` (run 2 of `post` for each run, 2026-11-26 08:15 America/New_York): **`restoration=NOT-CLEAN`** for both runs (O, [`inv/restoration.txt`](evidence/1125-2153/inv/restoration.txt)). The reasons, individually:
  - gateway StatefulSet `generation` 12 → 12, explained (no scale operations ran) (O);
  - providers and profiles: `UNEXPECTED`, caused by harness defect 3. Field by field, the only change is the removal of `exp008c-anthropic` and `claude-code-exp008c`, plus the profile table's column re-alignment for the surviving rows (O, `inv/diff-2/`); an offline replay of the corrected `restore-check.sh` on the recorded inventories returns `removed` for both (O, lead);
  - **`argo.txt`: GitOps `main` moved from `05fed44` to `16878c0`** (8 Renovate commits; both apps still Synced/Healthy). None of the 9 changed files is in the OpenShell or Agent Sandbox app paths (O, `gh api compare`, read-only). The freeze guard last confirmed `05fed44` at 02:54:44Z, inside run 2; when the commits reached `main` is not established (the GitHub PR records gave no merge time for the earlier ones).
  - No other inventory file differs (O): gateway StatefulSet, data PVC, pod images and names, CRDs, webhooks, RBAC, namespaces, PVs, Cilium, Sandbox CRs.
- `sampler-stop` (requested; no sampler, watch or harness tmux process remained, lead check) and `logout` (rc 0) done. **Owner actions outstanding at the time of writing:** revoke the API key; check the Console spend. *Both done by the owner on 2026-11-26; see [Owner closeout](#owner-closeout-owner-reported-2026-11-26).*
- Clean restoration is **not** claimed: the recorded verdict is `NOT-CLEAN`, and one of its reasons (GitOps) is a real, unrelated change.

## Owner closeout (owner-reported, 2026-11-26)

Recorded as reported by the owner. The sections above are left as written on 2026-11-26 before this report.
- The experimental provider `exp008c-anthropic` and profile `claude-code-exp008c` were deleted (also verified by `post` run 2, above).
- The dedicated Anthropic API key has been **revoked**. It is not reused; a future run needs a new key.
- The Console **currently records no spending** for this experiment. This is an owner-reported Console observation, not proof that no delayed usage charge can appear. Any later charge is subject to Console reconciliation (a zero Console figure was not proof of no spend in EXP-006 s3b).
- No experimental sandbox, pod, PVC, PV or Cilium policy remained. The gateway remained at one replica, StatefulSet generation 12.

**Why the verdict stays `NOT-CLEAN`.** Both runs keep the recorded `restoration=NOT-CLEAN`. It is not changed to `matches-pre` after the fact. Three different things contribute to it:
1. **Resource cleanup succeeded** (O). Every experiment object was gone, the gateway was unchanged (1 replica, generation 12), and the owner's provider and profile deletion was correct.
2. **The provider and profile `UNEXPECTED` results are false positives** (O, harness defect 3). `post` compared the CLI tables byte-wise. The corrected comparison (`restore-check.sh`, PR #45 `f8a1d5b`) returns `removed` for both names when replayed offline on the recorded inventories. This is a harness defect, not a residue.
3. **The GitOps revision drift is real** (O). GitOps `main` moved from `05fed44` to `16878c0`: 8 Renovate commits, none in the OpenShell or Agent Sandbox app paths, and both apps were Synced/Healthy at the new revision. This is an environmental change during or after the run window. It was not caused by the experiment, and when it happened is not established. The recorded verdict therefore reports a real difference from `pre`, even though no experiment residue exists.

## Proposed findings (for owner review)

Scopes narrowed on 2026-11-26 after an independent Sonnet review, so that none is broader than its evidence.

- **FIND-092** (proposed): in run 1125-2153, **12 of 12** Claude Code requests that carried the placeholder in both `x-api-key` and `Authorization: Bearer` were refused by OpenShell v0.1.9's credential binding with `credential_placement_mismatch` (403) at the supervisor proxy (O: `obs/c0-proxy-decisions.tsv`). Source review indicates that the rule is generic: a provider credential has exactly one permitted placement, and the refusal happens before any upstream write. The client therefore fails closed and the real key is not forwarded (S). That upstream-write claim was **not** observed: no request was seen reaching Anthropic, and the owner reports no Console spend, but neither is proof. Scope: one run, one profile (`x-api-key` placement, `api.anthropic.com:443`), Claude Code 2.1.323. Not tested: other headers, other placements or bindings, a placeholder in a request body.
- **FIND-093** (proposed): Claude Code 2.1.323 sends an `apiKeyHelper` value as `Authorization: Bearer` in addition to `X-Api-Key`, and an approved `ANTHROPIC_API_KEY` as `X-Api-Key` only (S: static review of the pinned binary; O, local only: PR #45 `tests/header-capture-test.sh` with the pinned binary against a loopback mock; in the independent reviewer's run on 2026-11-26 it recorded Bearer on 4 of 4 requests for the 1125-2153 launcher and `x-api-key` only on the corrected launcher's single request). The mock run sets `ANTHROPIC_BASE_URL`, whereas production leaves it unset and takes a different first-party code path. Only the main `/v1/messages` request was observed. **Implication:** with an `x-api-key` OpenShell profile, the agent must not use `apiKeyHelper`. The corrected launcher on PR #45 keeps the placeholder in `ANTHROPIC_API_KEY` and pre-approves it. It sends `x-api-key` only **in the loopback mock harness**. The credentialed OpenShell path with it is **unobserved** until a live C0. Independent security reviews (Sonnet, 2026-11-26, two passes): no blocker; the first pass's should-fix items are done (PR #45 `ccd2d95`), and the second pass's are recorded as residual risks (PR #45 README section 12.7). Owner approval is still required for any run.
- **FIND-094** (proposed): observed in run 1125-2153's C0 only (n = 1, about 4 minutes of agent life), on the Kubernetes driver:
  - The agent ran as the sandbox's main process (PID 71, uid 10001), with the launcher record equal to the live process throughout.
  - Its environment held only the placeholder, and no real-key-shaped value was found in the readable environments or the workload filesystem.
  - A disallowed host, and an allowed host from a binary that is not bound to the credential, were both blocked, under OpenShell mediation (`sandbox exec`) and under `kubectl exec`.

  This is a single-run observation, not a general boundary property. It does not cover the credentialed path, which never succeeded.

## Lessons (process)

- Every liveness gate and every self-invocation needs an offline test that exercises it against a stub: both stopping defects were in untested harness paths (a gate on a buffered pipe; an exec of a non-executable file).
- A credential path should be validated end to end without the cluster before a live run. The header-capture test now does this for the launcher, with a negative control.
- Cleanup must not depend on a step that might not have run (the transcript path).
- Restoration checks must compare meaning, not bytes, and must themselves be tested against the CLI's real output shapes; otherwise a correct cleanup reads as `NOT-CLEAN`.
- Close-out steps that wait for the owner (deletion, `post`) leave read-only samplers running; stop or bound them at cleanup.
- Even with a stop in place, the stop message can name the wrong cause (run 2's "H4?" was reached through a probe defect). Classifications above rest on the proxy decisions, not on the stop text.

## Recommendation on Stage C4

**C4 is not justified now.** C0 has not passed, and C1–C3 produced no evidence about process or conversation continuity under the Kubernetes driver with a real agent. The next step is a single C0–C3 run with the PR #45 launcher fix (security reviews: no blocker; cluster-free header-capture test passing with positive and negative controls; readiness package and residual risks in PR #45 README section 12), **after** a fresh explicit owner authorization, with a new API key, a recreated provider and profile, and a new run ID. Whether C4 (Git persistence, durable PVC) is warranted should be decided from that run's C1–C3 results.

## Evidence

- [`evidence/1125-2032/`](evidence/1125-2032/) and [`evidence/1125-2153/`](evidence/1125-2153/): what `export.sh` (PR #45, `ccd2d95`) copied after its redaction scan passed: timeline, step markers, identity and boundary results, metrics JSON, inventory diffs and restoration results, sampler output. Run 2's four time-stamped sample files are trimmed to 120 s after cleanup (marked in each file); the three watch files are not trimmed. Watch lines carry no observation time; their latest embedded object timestamps are 02:58:50Z (pods), 02:58:20Z (events) and 02:54:30Z (Sandbox CR; its final `DELETED` event carries no later timestamp). `$HOME` paths in diff headers are shortened to `~`. `obs/c0-proxy-decisions.tsv` is derived by the lead from the supervisor log (structured OCSF fields for events naming a public host or a credential).
- Not committed (kept local in `~/.cache/hxc/run/<RUN>/raw`, 0700, for owner review): supervisor, gateway, controller and workload logs; screen captures (none were taken); transcripts (none retained); the full inventories; the lead's notes. Any excerpt needs an owner decision.
- The workload pod's `x-…json` termination capture at 02:54:31Z records its init containers' normal exit (rc 0), not a failure (O).
