# EXP-008 Stage C4: workload loss, durable state and native Claude Code resume (PROPOSAL; Phase 1 approved for implementation and offline testing only; no C4 execution authorized; nothing run)

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../docs/experiments/08-openshell-execution.md) · Stage C record [`stage-c/results/1126-1017.md`](stage-c/results/1126-1017.md) (PR #47) · REQ-003, REQ-006, REQ-009, REQ-011 · ADR-0001 unchanged

**Status (2026-11-26).** Agent-generated research proposal for owner review.
- No sandbox, PVC, provider, profile, gateway setting, GitOps change, model call or API key was created, changed or used to write it. No cluster was read.
- It supersedes the C4 parts of the historical [Stage C proposal](STAGE-C-PROPOSAL.md) (sections 3.1 items 2–3, 4.2 rows "Native recovery" and "Repository", 4.3 rows C4a–C4c, 8 items 10–11). That file stays as written. Section 11 lists what changed and why.
- It authorizes nothing by itself. Section 13 lists the owner decisions that were open; the owner's decisions so far are in "Owner decisions (2026-11-26)" below. Implementation and execution are separate approvals: **Phase 1 implementation and offline testing are approved; execution is not.**
- Nothing here changes ADR-0001, a requirement status or a finding status. FIND-095 to FIND-097 stay **proposed**.

**Labels.** **O** observed in this repository's committed evidence. **S** read in upstream source or docs at the pinned version. **B** static review of the pinned Claude Code binary. **I** inference. **H** hypothesis C4 would test. **U** unknown; needs a live read.

**Pins.** OpenShell `v0.1.9` (`ce58cf8e9b953281352d98a637e41616295b1318`); Agent Sandbox `v1.0.12` (tag commit `4863a62`, cloned for this review); Claude Code **2.1.323** (sha256 `604d29a6…e348e`) in image `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18`; `claude-haiku-5-5`, effort medium. The same installation as run `1126-1017`.

## Owner decisions (2026-11-26; recorded by the agent as stated by the owner)

These are the owner's decisions on this proposal and on the Phase 1 implementation, PR #49. They amend the text below only where it says so.

1. **Scope:** Phase 1 (native `stop`/`start`) is approved for **implementation and offline testing only**. No C4 execution is authorized; a run needs a separate explicit authorization. **Phase 2 is deferred**: no `allow_driver_config`, no external PVC, no second sandbox.
2. **Approved design choices:**
   - C4a uses `--grace-period=1`, without `--force`;
   - the ledger instead of Git;
   - the new mutations M9–M11;
   - plain `--resume` (no `CLAUDE_CODE_RESUME_INTERRUPTED_TURN`, no `--session-id`, no positional prompt);
   - `STEP_SLEEP=45`;
   - the §5.6 control and probe lines;
   - at most two inputs after resume, with the fixed continuation line;
   - the §10 limits;
   - the shared real-model predicate.
3. **D-1, the transcript tail (amends §5.4):** up to **5** entries after R. Entries 4–5 are permitted only if they are recognized metadata (`api-request`, `cost-state`, `last-prompt`). The 64 KiB limit, the byte-prefix integrity, the permitted types, parent continuity and the partial-line check are unchanged. Additional tool activity is never accepted.
4. **The C4 `step.sh` signal fix** is approved: an interruption exits without recording a completed step. C0–C3 is unchanged.
5. **Classifications added during implementation** are approved: C4b `unmeasured`, session `unavailable`, process `unreadable` and `same-as-original`, and the documented inconclusive reasons.
6. **A single reference snapshot:** if R cannot be verified, or the timing gate expires, STOP without deleting the pod. There is no second R to salvage the same attempt.
7. **FIND-095 to FIND-097:** the owner recommends accepting them at the narrowed scopes in `stage-c/results/1126-1017-ADDENDUM.md` (PR #49). The acceptance itself is recorded by the owner on issue #39.

## 0. Recommendation in one screen

1. **Split C4 into two phases.** Phase 1 answers the core question (can a *new* Claude Code process resume the conversation and continue the task after the original workload is lost?) with **no gateway, GitOps or PVC change**. Phase 2 adds the one question Phase 1 cannot answer: survival of state across **deletion** of the original sandbox, which needs an externally owned PVC and `allow_driver_config`.
2. **Phase 1 (recommended next): OpenShell-native recovery.** Delete the workload pod mid-step (C4a). Then `sandbox stop` and `sandbox start` the **same** sandbox: OpenShell documents this as the recovery for an infrastructure `Error` that "retains the sandbox and its persistent workspace" (S, section 3.1). The default per-sandbox PVC carries the state (C4b-N). The relaunched launcher finds the state and runs `claude --resume <id>` (C4c).
3. **Phase 2 (deferred; analysed here, not requested for approval): sandbox deletion.** An owner-created, labelled PVC mounted at `/sandbox/c` through `--driver-config-json`, the original sandbox deleted, a replacement sandbox created on the same PVC (C4b-E), then the same C4c. **`allow_driver_config` is required for Phase 2 and only for Phase 2** (section 3.3). Phase 2 widens the gateway's security posture to answer only the deletion question. If the owner wants it, it should be a revision of this proposal with its own review and approval, after Phase 1 results.
4. **Keep the hash-chained ledger; no Git, no image rebuild.** It gives a resume check Git cannot. The token step N needs exists only in the pre-fault conversation. An accepted step N after resume, issued as a plain `./step.sh` call, is therefore strong mechanical evidence that the conversation was restored. Steps after N are ordinary agent behaviour (section 4).
5. **Precondition fixes from run `1126-1017`.** Every "model activity" check must require a real model response, not any `assistant` entry (the H4 weakness). Probes must use a strict, machine-checkable format. The token-expiry guard can remain a documented limit (section 7).

## 1. Questions and pass rules

C4 asks three questions. Each has its own pass rule; a pass on one says nothing about the others.

| | **C4a: workload loss** | **C4b: durable state** | **C4c: native resume** |
|---|---|---|---|
| Question | What happens when the original workload pod is terminated while the agent is working? | Does the agent's state survive intact and stay reachable by the next process? **N** (Phase 1): across `stop`/`start` of the same sandbox. **E** (Phase 2): across deletion of the original sandbox, on an externally owned PVC | Can a **new** Claude Code process load the original conversation, recover the task position, answer a memory probe without tools, and continue without repeating completed work? |
| Measured | Process end (workload pod UID gone **and** a termination captured; an unreadable P alone is not enough), container termination state (X key), sandbox phase, any replacement pod and its fate, the last persisted state before the loss (reference snapshot R) | Storage **identity** (PVC UID, PV, volume handle, state id) **and integrity** (file hashes, ledger chain, transcript byte prefix) against R, measured by the new launcher **before** Claude Code starts | Process identity (must be new), session identity, probe answer and tool count, step-ledger behaviour before and after input |
| Pass | Original process ended; sandbox reached a terminal phase; termination recorded; R captured with exactly one step in flight | Identity unchanged **and** every integrity check within the pre-registered allowance (section 5.4) | `resumed-auto-continued` or `resumed-continued-after-prompt` (section 6.3), with the probe correct, zero tool calls in the probe turn, and no repeated completed step |
| Looks like a pass but is not | Kubernetes or OpenShell readiness of anything afterwards | "The PVC still exists" | A new process answering a prompt; a fresh session redoing the task; the original process having survived (then nothing was lost and C4c is void) |

**A new process answering is not survival.** After C4a the original process is gone by construction. The resumed process gets a new nonce, start time, workload pod UID and possibly a new node. PID equality means nothing across sandboxes or pods: a fresh PID namespace will probably give the agent PID 71 again. P is compared on nonce, `/proc` start time and boot id together, as in Stage C.

## 2. Basis

- **Accepted at their scopes:**
  - FIND-077 to FIND-087 (Stage A; [EXP-008 record](../../docs/experiments/08-openshell-execution.md)).
  - FIND-088 to FIND-091 (Stage B). The owner's Stage C instruction of 2026-11-25 treats them as accepted at their documented scopes ([`stage-c/README.md`](stage-c/README.md), status note). [`k8s/README.md`](k8s/README.md) still says "proposed" and is left for the owner to update.
  - FIND-092 to FIND-094, at amended scopes: owner decision on issue #39, 2026-11-26. `stage-c/results/README.md` still says "proposed".
- **Proposed, not accepted:** FIND-095 to FIND-097 (run `1126-1017`). C4 relies on FIND-095 (the corrected credential path works) and on the C0 baseline; it does **not** rely on FIND-096/097. Owner review of FIND-095 should precede approval (section 13, item 1).
- **FIND-090 (O, Stage B, synthetic):** deleting the workload pod ends the process. Agent Sandbox creates a same-name replacement pod. The gateway deletes it while it is `Pending` ("workload generation changed; suspending stale boundary") and the sandbox stays `Error`. C4a repeats this with a real agent; FIND-090 did not try `stop`/`start`.
- **Prior resume evidence (O, EXP-001, local, Claude Code 2.1.311):** FIND-007 (Herdr relaunched `claude --resume <id>`; the codeword was recalled, also headless) and FIND-008 (resume does not restore launch flags). Neither was a resume after an interrupted tool call, and neither ran in OpenShell.
- **Not established anywhere yet:** a resume of an interrupted turn at 2.1.323 *with a real model and in OpenShell*; whether OpenShell `stop`/`start` works from the fence-suspended `Error`; whether a real Herdr client changes any of this.

### 2.1 Claude Code 2.1.323 resume behaviour (offline review for this proposal)

An independent Sonnet review read static strings of the pinned binary (sha256 verified) and ran an **offline probe**:
- **Environment:** an unprivileged user and network namespace with loopback only; a mock `/v1/messages` returning SSE; a fake key; synthetic prompts only; the Stage C flags.
- **Procedure:** the mock returned one Bash `sleep 30` `tool_use`, and Claude Code was killed while the tool ran. Six variants: SIGKILL; SIGTERM then SIGKILL after 1 s; a positional prompt; `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1`; `--session-id` with `--resume`; a different cwd.
- **Limits:** one synthetic step and no real model, so model behaviour after resume stays U. The probe scripts and per-run structural reports are local to the review and not committed. Section 12 proposes making them an offline test.

| # | Fact | Label |
|---|---|---|
| CR1 | Transcript writes are queued and appended (O_APPEND) about every 100 ms; no fsync was found in the session store. The assistant entry holding the in-flight `tool_use` was on disk about 0.1 s after the response, before the tool started. SIGKILL wrote nothing. SIGTERM appended only metadata rows (`api-request`, `cost-state`, `last-prompt`), with no result and no interruption marker. A torn final line is anticipated: it is sealed with a newline before the next append. How a torn tail loads is U | B, O |
| CR2 | A plain interactive `--resume <id>` sent **no** request and changed nothing during the observation window. The TUI showed the call as "Interrupted · What should Claude do instead?" and waited. **Automatic continuation is not the default** | O |
| CR3 | On the first input after resume, Claude Code appends a synthesized `tool_result` for the orphaned `tool_use`: `is_error: true`, `toolDenialKind: "interrupted"`, text "[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is unknown. Check whether it took effect before relying on it or running it again.]". It also appends a `<synthetic>` assistant entry. The first request then carried the whole prior history. The tool is **never re-run** by Claude Code itself | O, B |
| CR4 | `CLAUDE_CODE_RESUME_INTERRUPTED_TURN` exists in 2.1.323. When set, it resubmits the interrupted turn about 0.5 s after start with no input, using `CLAUDE_CODE_RESUME_PROMPT` ("Continue from where you left off.") and dropping the orphaned `tool_use`. An age limit, `..._MAX_AGE_MS` (default 1 h), applies | O, B |
| CR5 | Resume appends to the **same** file with the same `sessionId`; the original bytes remain an exact prefix. The first resumed rows' `parentUuid` is the pre-fault `tool_use` entry. There is no separate resume marker | O |
| CR6 | `--session-id` together with `--resume` **exits with an error** (it needs `--fork-session`). A positional prompt with `--resume` is sent immediately, so it is input | O |
| CR7 | Resume restores messages, not flags: `--settings`, `--tools` and `--model` come from the new command line (consistent with FIND-008). The session is looked up under the cwd's slug, and a different or untrusted cwd raises the folder-trust dialog. A "Resume from summary / full session" dialog exists for sessions idle at least 70 min **and** of at least 100k estimated tokens; C4's session should be far below both (I) | B, O |

## 3. Storage architecture

### 3.1 Source-level behaviour (S unless marked)

| # | Fact | Source (OpenShell v0.1.9 unless marked) |
|---|---|---|
| F1 | The default `/sandbox` PVC is created by the **Agent Sandbox controller** from the Sandbox CR's `volumeClaimTemplates` (one template, `workspace`, RWO). It is named `workspace-<CR name>` and carries a controller ownerReference to the Sandbox CR. The controller has no PVC delete call; the PVC goes away by ownerReference garbage collection when the Sandbox CR is deleted (O: Stage B and C cleanup) | `crates/openshell-driver-kubernetes/src/driver.rs` ~7792–7820; Agent Sandbox v1.0.12 `controllers/sandbox_controller.go:2211-2290`, `api/v1beta1/sandbox_types.go` ~296–303 |
| F2 | The FIND-090 fence suspends the runtime but keeps the Sandbox CR. The per-sandbox PVC should therefore still exist while the sandbox is `Error` (I; U live) | `driver.rs:5167-5195`, `5497-5535` |
| F3 | **`sandbox stop` is admitted from `Error`.** On Kubernetes it suspends the CR (`operatingMode: Suspended` / `replicas: 0`), removes compute and keeps the PVC. **`sandbox start`** (from `Stopped`) renews authentication, repeats configuration admission and **relaunches the canonical command** with a new supervisor and workload pod. The docs prescribe "`sandbox stop` followed by `sandbox start` … retains the sandbox and its persistent workspace" for infrastructure errors. The docs qualify the workspace retention: "on backends that support restarting stopped sandboxes"; the Kubernetes driver implements stop and start (`driver.rs:4117-4231`). A comment at `compute/mod.rs:465-467` says "stopping a suspended sandbox discards its retained state". It refers to OpenShell's separate `Suspended` phase; the docs state that stop retains "policies, provider attachments, settings … and persistent workspace data" (`overview.mdx` ~990–1008). That the fenced `Error` sandbox is not in that `Suspended` phase is I (FIND-090 observed `Error`). Whether stop works from the live fence-suspended state, and whether the PVC is kept, is **U**: it is the first thing Phase 1 measures | `crates/openshell-server/src/compute/mod.rs:440-489`, `~2480`; `driver.rs:4117-4231`, `2670-2672`; `docs/how-it-works/sandboxes/overview.mdx:1021`; CLI `crates/openshell-cli/src/main.rs:1709-1719` |
| F4 | `--restart-policy` (`never`, `on-failure`, `always`) acts only on a reported **main-process exit**. It is not consulted when the workload pod is deleted: the fence is unconditional. A restart "does not restore process memory or terminal history" | `compute/mod.rs:6167`, `7014-7020`; `overview.mdx:39-50` |
| F5 | The workspace init container seeds `/sandbox` from the image once, guarded by a `.workspace-initialized` sentinel, so a restart does not reseed the retained PVC | `driver.rs` ~7710–7780 |
| F6 | A pre-existing PVC can be attached only through caller driver config, which needs `allow_driver_config = true`. A mount **at** `/sandbox` is rejected ("reserved for the OpenShell workspace"); a mount **below** it is allowed, and any such mount **disables the default workspace PVC and its init container** | `crates/openshell-core/src/driver_mounts.rs:200-210`; `driver.rs` ~917, ~7894–7925 |
| F7 | v0.1.9 has no retain, keep-workspace, snapshot or restore option for Kubernetes workspaces ("temporary — will be replaced by snapshotting"). Gateway storage settings are only the storage class and default size. Re-adopting an orphaned `workspace-<name>` PVC would need a manual ownerReference edit and a same-name sandbox: unsupported | `driver.rs` ~1028–1041; `docs/how-it-works/sandboxes/runtimes.mdx:298-299`; Agent Sandbox `sandbox_controller.go:2226-2248` |
| F8 | The pod security context sets `runAsUser`/`runAsGroup` to the sandbox uid (10001), `fsGroup` to its gid and `fsGroupChangePolicy: OnRootMismatch`. Whether Longhorn applies fsGroup to an external PVC is **U** | `driver.rs` ~7498–7506 |
| F9 | The driver sets no node affinity or nodeName. With RWO, a replacement workload pod can land on another node, and it cannot attach until the old attachment is released (I for Longhorn timing) | `driver.rs` (grep) |

### 3.2 Options compared

| Option | What survives workload-pod loss | What survives sandbox deletion | Needs | Answers | Verdict |
|---|---|---|---|---|---|
| **A. Default per-sandbox PVC, no recovery action** | PVC while the CR exists (F2), but nothing can run on it: the fenced sandbox never starts a process | Nothing (F1) | — | C4a only | Insufficient: C4b and C4c untestable |
| **N. Default per-sandbox PVC + native `stop`/`start`** | PVC, same sandbox identity (F3, F5) | Nothing | Three new harness mutations (M9 workload pod delete, M10 `stop`, M11 `start`); a state-aware launcher | C4a, C4b-N, C4c | **Recommended for Phase 1.** No gateway, GitOps, PVC or security change |
| **E. Externally owned, labelled PVC via driver config** | PVC (no owner, no finalizer added by OpenShell or Agent Sandbox: the gateway has only `get` on PVCs) | PVC and all state | `allow_driver_config = true` (gateway restart), an owner-created labelled PVC, driver-config JSON on both creates | C4a, C4b-E, C4c | **Phase 2 only**, if the owner wants the deletion question answered now |
| P. `--restart-policy on-failure/always` | Not applicable: not consulted for pod deletion (F4). It would apply to a main-process crash, which is a different, untested event | — | — | Nothing for C4a as posed | Rejected for C4; record as a future variant |
| Workspace snapshot, retain or restore option | — | — | Not available in v0.1.9 (F7) | — | Not an option at this pin |
| Helper pod, `kubectl cp` from the orphaned PVC, manual PVC adoption | — | — | Unsupported manipulation | Not the recovery path in question | Rejected (as in the historical proposal) |

**Why N first.** The open technical risk is Claude Code's resume of an interrupted turn and OpenShell's `stop`/`start` from `Error`, not the storage plumbing. Option N tests both on the existing installation with nothing widened. Its limit is explicit: the sandbox identity survives, so **Phase 1 does not answer "after deletion of the original sandbox"**. It is the minimum that answers C4a and C4c. Phase 2 reuses the Phase 1 harness unchanged except for the mount and the delete-then-create step, so doing N first costs little.

### 3.3 `allow_driver_config`: necessity, exposure and rollback (Phase 2 only)

**Necessary?** Not for Phase 1. **Yes for Phase 2**: in v0.1.9 caller driver config is the only supported way to give a *different* sandbox a pre-existing volume (F6, F7). The owner's GitOps values (a separate repository, read only by the reviewer) do not set it. The chart default is `false` (`deploy/helm/openshell/values.yaml:530`; Helm key `server.drivers.kubernetes.allowDriverConfig`). The live value is U.

**What it opens (S: `driver.rs` ~690–830, ~8185–8250; `resource_admission.rs`).** It is one gateway-wide boolean, with no per-user, per-workspace or per-sandbox scope. With it on, any authenticated gateway user who can create sandboxes in a workspace can request exactly:
- PVC volumes (no other volume type) whose PVC carries `openshell.ai/sandbox-attachable=true` and `openshell.ai/sandbox-attachable-workspace=<workspace>`, mounted read-write below `/sandbox`;
- `node_selector` and free-form `tolerations` (scheduling onto tainted nodes);
- `resources` requests and limits (uncapped);
- `runtime_class_name` and `priority_class_name`, but only for classes carrying OpenShell's approval label.

Everything else is rejected (`deny_unknown_fields`): host namespaces, privilege, capabilities, env and envFrom, Secret and ConfigMap volumes, service accounts, annotations. The chart also adds a Role rule granting the gateway `get` on PVCs while the flag is on.

**Exposure here.** The gateway is single-user (owner OIDC), but agent processes share the owner's UID and could reach the isolated CLI login (FIND-055). During the window, such a process could mount the labelled PVC or schedule a sandbox with tolerations and large resource requests. Controls:
1. Exactly one PVC carries the attachable labels, checked by name in `pre` and `post`; any other is a STOP.
2. The flag is on only for the run window, entered and left by owner GitOps commits.
3. The owner removes the PVC's attachable labels immediately after the replacement sandbox is deleted.
4. Optional: add one experiment-specific label to the required-label map (owner decision).

**Ordering constraint (S, `crates/openshell-driver-kubernetes/src/resource_admission.rs:247-262`).** Sandboxes created with driver config are re-validated on start and about every 30 s while running. After a revert they fail with "sandbox driver config is disabled…; recreate it". **All Phase 2 sandboxes must be deleted before the flag is reverted.**

**Rollback.**
1. Delete the C4 sandboxes and wait for no residue.
2. Remove the PVC labels.
3. Revert the GitOps commit; the gateway restarts.
4. Verify: the rendered config shows `allow_driver_config = false`, the PVC `get` rule is gone from the Role, Argo is Synced/Healthy, the OpenShell app path tree equals the pre-enable commit, and no Sandbox CR remains.
5. The owner deletes the PVC after evidence review. With reclaim `Delete`, also check that the PV and Longhorn volume are gone.

The gateway restarts caused by the enable and revert commits are lifecycle events: they happen only when no sandbox exists, before `pre` and after cleanup.

## 4. Git versus the progress ledger

The pinned image has no Git ([`stage-c/README.md`](stage-c/README.md) D1). The ledger in [`task/step.sh`](stage-c/task/step.sh) records `attempt`, `done` and `refused` lines with the invoking shell's identity, and a `ledger.log` in which each line carries the hash of the previous line. Each step's next token is printed once, and only its sha256 is stored.

| C4 question | Ledger | Git |
|---|---|---|
| State persistence | sha256 of each log and of the `.state` token hash, plus chain verification, compared with R | Commit hashes; also needs the working tree |
| Repeated or skipped steps | Structurally refused: a repeated or out-of-order `N` is not executed and is logged to `refusals.log` with the reason (`expected-n=…`) | Detectable only after the fact, by commit history |
| In-flight tool call | `attempt N` without `done N` at R; a re-attempt records `prior_attempts=1`; a stale lock break is logged to `locks.log` | Possibly a stale `.git/index.lock` (a separate failure class) |
| Conversation resume | **Mechanical, for step N only.** Step N's token appears only in the pre-fault transcript: in step N−1's tool result, and in the interrupted step N `tool_use` command. `.state` holds only its hash, and the screen is not readable by the agent. The check: after resume, the accepted `attempt N` must come from a Bash `tool_use` whose whole command matches `^\./step\.sh [0-9]+ [a-z0-9]+$` (no `$(`, `;`, `&&`, backticks or pipes), and whose token equals the one in the pre-fault step N `tool_use`. A fresh session cannot produce that token. **Limit:** "only `./step.sh`" is a Claude Code permission rule (`dontAsk`, one allow rule), not an OS boundary. The agent runs as uid 10001 on the same PVC as its transcript, which is why every resumed command is checked against the regex. Later steps print fresh tokens, so they add continuation evidence, not resume evidence. A restart from scratch shows as `./step.sh 1 start` refused | No equivalent: a fresh session can read the repository and continue plausibly |
| Correct continuation | The next accepted attempt is N (the in-flight step) with `prior_attempts=1`, followed by N+1, N+2 | Commit N+1 follows N |

**Recommendation: use the ledger; no Git, no rebuild.** It answers every C4 core question, and it answers the resume question better than Git would. Git repository recovery (stale index lock, an uncommitted working tree, a commit interrupted mid-write) is a real later question for REQ-003 and REQ-006. Make it a separate extension (C4-G) with an image that contains Git, after C4 results exist. It is not needed to answer C4. No GitHub credential or remote is involved in either.

**One hazard, gated.** After its sleep, `step.sh` makes three writes in order (`task/step.sh` lines 73–75):
1. it rotates `.state/next-token.sha256`;
2. it appends `done N`;
3. it appends the ledger line.

A kill after write 1 makes step N's token unrecoverable: the stored hash is already for N+1, and the only copy of the N+1 token died with the process. A re-run of N is then refused as `wrong-token`. A kill between writes 2 and 3 leaves `done N` without its ledger line. The C4a gate therefore kills only while step N is inside its sleep (section 5.3). Any such partial state is `in-flight-partial(k)`, with k the number of writes done. It is classified `chain-broken-by-fault`, a harness-timing outcome: never `corrupt` and never context loss.

## 5. Phase 1 design (native stop/start)

### 5.1 Objects and owners

| Object | Created and deleted by | Notes |
|---|---|---|
| Sandbox `exp008c4-<RUN>` (Sandbox CR, supervisor pod, workload pod, Service, NetworkPolicies, Secrets) | Harness: M1 create, M6 delete. The gateway owns compute | One sandbox for the whole run, stopped and started once |
| Per-sandbox PVC `workspace-<CR name>` and its PV | Agent Sandbox controller (ownerReference to the CR) | Holds all agent state under `/sandbox/c`; garbage-collected at M6 |
| Provider `exp008c-anthropic`, profile `claude-code-exp008c` | Owner, in the owner's terminal, as in Stage C | New dedicated key; deleted after cleanup |
| Local evidence directory (outside the repository) | Harness | Raw material stays local (0700) |

No gateway setting, GitOps commit, PVC or label is created or changed in Phase 1.

### 5.2 Launcher change (state-aware, not implemented)

The canonical command is fixed at create, and `sandbox start` relaunches it (F3). The launcher must therefore choose its mode from the state it finds:
- **Fresh** (neither `/sandbox/c/repo` nor `/sandbox/c/state-id` exists): as today. Also writes a random 128-bit `state-id` and the session id. Identity records become per-launch (`launch/identity-1`, `identity-2`).
- **Resume** (both exist): writes `launch/precheck-<k>` with the C4b measurements (5.4) and verifies them itself. It execs `/usr/local/bin/claude --resume <sid>` with:
  - the **same** `--bare --settings … --strict-mcp-config --tools Bash --model claude-haiku-5-5 --effort medium` flags (FIND-008, CR7: resume does not restore flags);
  - **no `--session-id`** (CR6: the combination exits with an error);
  - **no positional prompt** (CR6: that would be input);
  - the same `CLAUDE_CONFIG_DIR`, `HOME` and cwd `/sandbox/c/repo`, so the transcript slug and folder trust match (CR7).
- **Auto-continue variables.** The launcher **unsets** `CLAUDE_CODE_RESUME_INTERRUPTED_TURN`, `CLAUDE_CODE_RESUME_PROMPT` and `CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS`, so the default behaviour is what is measured (CR2, CR4). It records the **names** (never values) of every `CLAUDE_CODE_*` variable present at exec. Setting them is an owner-selectable variant (section 13 item 6). Only one variant runs per run.
- **API-key approval.** The seeded approval holds the placeholder's last 20 characters. The placeholder is revision-scoped ([`stage-c/README.md`](stage-c/README.md) D4). If the provider revision seen at start differs, the old approval would no longer match and the custom-key dialog would block the TUI. The resume launcher therefore compares the current tail with the stored one, records `approval_tail=same|added`, and if needed **adds** the new tail to `approved` in **both** copies (`claude/.claude.json` and `home/.claude.json`), with a structured JSON edit (python3). It records each file's sha256 before and after, and changes nothing else.
- **Refuse, never fall back.** The launcher exits nonzero without starting Claude Code (recorded as C4b `corrupt` or `lost`) if:
  - exactly one of `repo` and `state-id` exists (a partial first launch);
  - the state id is unreadable;
  - the session id or transcript is missing;
  - the ledger chain is broken.

  It never starts a fresh session on found state.
- **Limit: lost state looks like a first launch.** If the PVC were lost or replaced, the launcher would see empty state and start a fresh agent. The harness guards this from outside: `start` runs only after V shows the PVC and PV unchanged, and a post-start check of `launch/identity-*` and `state-id` against the pre-registered values classifies `lost`, **which overrides every C4c value**.
- **Step pacing.** The launcher exports `STEP_SLEEP=45` (the default is 20 s) so the C4a gate has room for the reference snapshot (5.3). *M* rises to about 46 s. This is a task-package change and is recorded in the package hash.
- **One start only.** A launcher refusal leaves `Error/MainProcessFailed`, which OpenShell lets `start` relaunch directly (`compute/mod.rs:2476`). The harness never issues a second `start`, and never passes the ephemeral or auto-delete option to `sandbox create` (`compute/mod.rs:6267-6290`), which would auto-delete a failed sandbox.
- The credential checks of the current launcher (placeholder form, approval tail, unset Bearer-capable variables) run in both modes. The new supervisor resolves the provider again at start, and C4c's activity check (5.6) catches a failure.

### 5.3 Sequence (one run, one attempt per step, no retries)

*M* (italic) is the median interval between the first attempts of steps 1–6 in C0, as in Stage C (about 20.6 s in run `1126-1017`). It is unrelated to the mutation identifiers M1–M11. Harness step names: `c0-create`, `c0-baseline`, `c4a`, `c4b`, `c4c`, then `cleanup` and `post` as in Stage C. In Phase 2, `c4b` performs the C4b-E variant.

| Step | Action | Proceeds when | Stops or records |
|---|---|---|---|
| owner | New key, $5 cap, profile and provider recreated, freeze, redaction list ([`stage-c/README.md`](stage-c/README.md) 12.5) | Provider listed | — |
| `pre`, `sampler-start` | As Stage C, plus the sampler follows Sandbox CR, PVC, PV and VolumeAttachment for this sandbox | Stage C conditions | Any guard |
| **C0** | Create S1 (default PVC, `--restart-policy never`, no ephemeral option). Stage C identity, credential and egress checks. First attach: the codeword line doubles as the **pre-fault control probe** (5.6). *M* from steps 1–6. Clean detach | Stage C C0 conditions, with the corrected H4 predicate (7). The control reply is recorded either way; a format failure makes a later C4c probe failure `inconclusive` | Any C0 failure |
| **C4a** | Gate: at least 6 `done` and at most 100; no client attached; step N in flight.<br>Take the reference snapshot **R**: P, W and V from the sampler, plus **one** exec (`snap`: transcript and task logs). Then re-read `attempts.log` and `progress.log` once. Proceed only if R is complete, step N is still without `done`, and its `attempt` is 3–30 s old (sleep 45 s).<br>Then at once `delete pod <workload> --grace-period=1 --wait=false` (M9, labels re-checked). Observe for 120 s | Original process ended (workload pod UID gone and termination captured); sandbox phase recorded | Gate not met within 15 min, or R incomplete → STOP (C4 `not-tested`); never kill without a complete R |
| **C4b-N** | `sandbox stop` (M10); wait for `Stopped` (≤ 300 s). Verify that the CR exists and is suspended, no pod remains, the PVC and PV have unchanged UIDs and no `deletionTimestamp`, and the VolumeAttachment is released. Then `sandbox start` (M11, once); wait for `Ready` (≤ 300 s). Read `launch/precheck-2` and compare with R | Section 5.4 allowance | Stop or start refused or timed out → record `not-restartable`, with the CLI error text and the CR's generation and bootstrap annotations (identity fields only; the start path checks the expected runtime identity, `driver.rs:4258`); C4c `not-tested`; go to cleanup |
| **C4c** | (a) No client and no input for max(4*M*, 120 s). Expected (H, CR2): no request and no transcript change.<br>(b) Attach; capture the screen as replayed and after a redraw, recording any dialog or the "Interrupted" notice. Type the probe (5.6); it is the first input.<br>(c) If no step has been accepted within 2*M* after the probe reply, type the fixed line "Continue the task."<br>(d) Observe until `done` for N, N+1 and N+2 (step N counts), or 6*M* after the last input. Detach.<br>The input that started the work (none, the probe, or "Continue the task.") is recorded.<br>**Hard caps:** at most 2 typed lines after resume, 1 stop, 1 start, 20 min after `start`, and 10 refusals after resume (then STOP and cleanup) | Classification 6.3 | Recorded result, not a stop |
| cleanup, `post`, `sampler-stop`, `logout` | Section 8 | `restoration=matches-pre` | Residue → owner decides |

Phase 1 has **no gateway scale, no gateway restart, no second sandbox** and no C1–C3 repeat.

### 5.4 State and session measurements

| Key | Before (R, by exec just before M9) | After (by the resume launcher before `exec`, then by exec) |
|---|---|---|
| **P** process | pid, `/proc` start, boot id, nonce (launch record and live) | Must differ in nonce and start; pid equality ignored |
| **W** workload | Pod UID, container IDs, restart counts, node | New pod UID expected; node recorded |
| **X** termination | Captured by the sampler on the transition: exit code, reason, `lastState`, container log tail (local) | Replacement pod creation and fence, from the watch |
| **V** volume | PVC UID, PV name, volume handle; VolumeAttachment node and attacher | UIDs and handle identical; attachment released between stop and start; the new attachment's node and attacher recorded, not compared |
| **D** state identity | `state-id`, session id | Identical |
| **Tr** transcript | Transcript path, byte length L_R, sha256 of bytes [0, L_R), line count, last entry type | sha256 of [0, L_R) identical; bytes beyond L_R recorded as `tail_after_R` (count, and whether the last line is partial) |
| **T** task | sha256 and line counts of `attempts`, `progress`, `refusals`, `ledger` and `locks` logs, and of `.state/next-token.sha256`; ledger chain; lock state | Identical, except the allowance below |
| (informational) | sha256 of both `.claude.json` copies and other files under `claude/` except the transcript | Recorded, not compared: Claude Code rewrites them |
| (start record) | — | No provisioning-timeout record on the sandbox (`provisioning_deadline.rs:279`); recorded |

**Allowance (pre-registered).**
- Transcript bytes after L_R (appended between R and the kill): at most 64 KiB and 3 entries, of types `assistant`, `api-request`, `cost-state` or `last-prompt`, with `parentUuid` continuity. At most the final line may be partial. *(Amended by owner decision D-1: up to 5 entries, where entries 4–5 must be recognized metadata.)*
- A stale `.state/lock` from the killed step.
- A partial or complete finish of step N (section 4): `in-flight-partial(1)` (token rotated only), `in-flight-partial(2)` (plus `done N`), or `in-flight-completed` (all three writes). The first two are always `chain-broken-by-fault`. The third is too, unless the transcript tail holds step N's output.
- Nothing else may change.
- Any other difference is `corrupt`.

### 5.5 Controlled termination

- M9 is an API delete with a 1 s grace: SIGTERM to the container, then SIGKILL. It is near-abrupt, matching Stage B B3. FIND-090 used the default grace, so the two must not be generalised to each other (AGENTS.md).
- It does **not** use `--force` or `--grace-period=0`. Force removes the API object before the kubelet stops the container, which with RWO risks a second writer.
- Graceful pod loss (default grace, which may let Claude Code flush on SIGTERM), node loss, supervisor-pod loss and main-process crash under a restart policy are **not tested**.

### 5.6 Probes and memory requirements

- **Codeword:** generated locally and typed at the first attach in C0 ([`stage-c/README.md`](stage-c/README.md) D12). It is not in the argv, the prompt file, the environment or any file the harness writes into the sandbox. It exists in the sandbox only in the transcript, on the same PVC. The agent is prevented from reading that by its permission rules (only `Bash(./step.sh *)`, `dontAsk`), not by the OS. Every resumed command is checked against the step regex (section 4).
- **Control line (C0, first attach):** `Remember this codeword: <codeword>. Reply on one line exactly: PROBE-<token> CODEWORD=<the codeword> LAST=<number of the last step that printed STEP OK>. Do not run any tool for this reply.` It establishes that Haiku follows the format before the fault, without an extra attach.
- **Probe line (C4c (b)):** `Reply on one line exactly: PROBE-<token> CODEWORD=<the codeword I gave you> LAST=<number of the last step that printed STEP OK>. Do not run any tool for this reply.`
- **Pass criteria:**
  - the token is present;
  - the codeword matches exactly;
  - `LAST` equals the ledger's last `done` at R (N−1);
  - **zero** `tool_use` entries between the probe's `user` entry and the first assistant text entry containing the token. Claude Code writes each content block as its own entry. `tool_use` entries ordered after the token-bearing text, in the same or later messages, are continuation, which `task/prompt.txt` asks for ("answer it in one short line … then continue"). The same rule applies to the C0 control;
  - the reply is a real model entry (7).
- After resume, the probe is the first input. Claude Code then appends the synthesized interrupted result for step N before the probe (CR3), which is the expected structure, not a fault.
- If the first assistant action after the probe is a tool call (for example an immediate re-run of step N, invited by the synthesized interrupted result), the probe is `probe-ignored`, not memory loss. The codeword is then judged from the first token-bearing reply, if any.
- C3a showed that an echoed token is weak evidence. The codeword and `LAST` are the recall evidence, and the step N token check is the mechanical evidence.
- CR2 was observed against a mock; C4c (a) is its first measurement with the real model.

### 5.7 Duplicate-work and corruption detection

- **Before input:** any `attempt`, `refused` or `tool_use` after start and before the first typed line counts as automatic continuation. A refusal is classified by its reason.
- **After input:** each refusal is classified by reason:
  - `expected-n` with n ≤ N−1 is a **duplicate attempt**; `./step.sh 1 start` refused is a **restart-from-scratch**;
  - `expected-n` with n > N is a **skip attempt**;
  - `wrong-token` is recorded but **not** used to decide context loss: a mistyped token or an `in-flight-partial` state also produces it. Context loss is decided by the probe (codeword, `LAST`) and by the step N token check;
  - a hallucinated N+1 is refused as `expected-n=N` before any token check, so it is a skip attempt, not `wrong-token`;
  - `busy` means concurrency.
- **The only legitimate re-execution is step N** (`prior_attempts=1`).
- **Ledger:** the chain is verified end to end at cleanup, and the pre-R portion must be byte-identical.
- **Batching** is detected as in Stage C.

## 6. Classifications (pre-registered; one value per axis)

### 6.1 C4a

| Axis | Values |
|---|---|
| Original process | `ended` (workload pod UID gone **and** termination captured or the pod deletion observed in the watch; an unreadable P alone, for example a failed exec, is `inconclusive`) · `survived` (P unchanged: C4a void; C4b and C4c `not-tested`) · `inconclusive` |
| Replacement pod | `fenced` (created, deleted before running: FIND-090 pattern) · `ran` · `none` |
| Sandbox phase within 120 s | `Error` · other (recorded) |
| Termination record | `captured` · `not-captured` |

### 6.2 C4b

| Value | Rule |
|---|---|
| `intact` | V and D identical; the Tr prefix and T identical within the allowance |
| `intact-with-allowance` | As above, using any allowance item (recorded which), including `in-flight-completed`. The C4b value describes the state only; whether the chain can still continue is a C4c matter (`chain-broken-by-fault` makes C4c `inconclusive`) |
| `corrupt` | Any other T or Tr difference, or a broken ledger chain outside the `in-flight-partial` states |
| `lost` | PVC or PV identity changed, or state id absent |
| `not-restartable` | `stop` or `start` refused, or the timeout reached. State is not measurable through the supported path; recorded, with no helper pod |

### 6.3 C4c

| Axis | Values |
|---|---|
| **Process** | `new-process` (expected) · `not-started` (launcher refused, or Claude Code exited) |
| **Session** (attribute, not pass or fail) | `same-id-same-file` · `same-id-new-file` · `new-id` · `fresh-no-history` |
| **Resume** | Decided by one ordered procedure (below); exactly one value: `inconclusive` · `not-started` · `failed` · `re-executed` · `probe-ignored` · `resumed-context-lost` · `resumed-auto-continued` · `resumed-continued-after-prompt` · `responded-no-progress` |
| **Repeat/skip** | `none` · `in-flight-reattempt-only` (step N) · `duplicate-refused(k)` · `skip-refused(k)` · `restart-from-start` |
| **Interrupted turn** | `synthesized-interrupted` (expected, CR3): a `tool_result` for the step N `tool_use` id with `is_error: true` and `toolDenialKind: "interrupted"` · `dropped` (CR4 variant) · `absent` · `other`. Recorded from structure only |
| **Session load** (supporting checks, CR5) | The byte prefix [0, L_R) is unchanged, with one file and the same `sessionId`. The first resumed row's `parentUuid` is the pre-fault `tool_use` entry. If the transcript's `api-request` rows record a request message count, record it against the pre-fault message count (U whether they do) |

**Resume decision procedure** (first match wins; implemented as one function in `metrics.py` with one unit test per value and a totality test):
1. `lost` from C4b, or the session file is new or empty (`fresh-no-history`) → C4c is reported as `lost`/`fresh-no-history` and no Resume value is a pass.
2. `inconclusive`:
   - `chain-broken-by-fault`;
   - a C0 control-probe format failure, when the C4c probe also fails;
   - the credential path failing at start (proxy 403, or only API-error entries);
   - an upstream 429, 529 or 5xx during resume;
   - spend-cap exhaustion.
3. `not-started`: the launcher refused, or Claude Code exited.
4. `failed`: no real model entry within 6*M* of the last input, or a blocking dialog on screen.
5. `re-executed`: `./step.sh 1 start` after resume, or more than one duplicate attempt of a completed step.
6. `probe-ignored`: the first action after the probe is a tool call. The codeword and `LAST` of any later token-bearing reply are recorded as attributes.
7. `resumed-context-lost`: the probe reply has a wrong or missing codeword or `LAST`.
8. `resumed-auto-continued`: step N was accepted, by the step N token check of section 4, **before** any input, and `done` exists for N, N+1 and N+2.
9. `resumed-continued-after-prompt` **(expected, H)**: as 8, but step N was accepted only after the first input (the probe or "Continue the task.", recorded).
10. `responded-no-progress`: everything else. The model replied correctly but never got step N accepted, or stalled before N+2, or looped on refusals under the caps.

Value 8 is expected only in the CR4 variant (CR2).

**Primary C4c pass (the same rule as section 1):** `resumed-auto-continued` or `resumed-continued-after-prompt` (steps 8–9 imply the probe criteria of 5.6: token, codeword, `LAST`, zero tool calls before the reply, a real model entry), **and** Repeat/skip ∈ {`none`, `in-flight-reattempt-only`}, **and** C4b ∈ {`intact`, `intact-with-allowance`}. Each axis is reported separately; a partial result is not relabelled.

## 7. Lessons from run `1126-1017` applied

| Lesson | Matters to C4? | Change |
|---|---|---|
| **H4 gate counted any `assistant` entry** (`stagec.sh:707` `_tr_probe`; also `metrics.py` `window()` and `probe()`) | **Yes, blocker for implementation.** After `start`, a new supervisor resolves the credential again; a failure would make Claude Code write API-error `assistant` entries, which the old predicate would count as resumed activity | One shared "real model entry" predicate: `message.usage` present, `message.model == claude-haiku-5-5`, no `isApiErrorMessage`, not `<synthetic>`. Used by the C0 gate, the windows, the probes and C4c activity, with offline tests for each negative |
| **Supervisor-token-expiry guard was vacuous** (`stagec.sh:577-586`; no annotation exists) | No: C4 has no gateway outage, and `start` renews authentication (F3) | Keep it as a documented limit. Record annotation presence; do not gate on it |
| C3a reply did not name the last step; codeword never asked | Yes | Strict probe format and a pre-fault control (5.6) |
| FIND-097's "five POSTs during the outage" relies on local supervisor logs; the exported metric counts transcript entries (Haiku audit) | Yes, for evidence | Export a derived, timestamped count of proxy decisions per window (structured fields only), scanned like the rest |
| Hand-counted P samples differed by 1–3 from a recount (record lines 85, 114) | Minor | Compute every count by script from committed samples |
| `export.sh` relative DEST failed closed | Minor | Documented: absolute DEST |
| Client tree had 3 PIDs, not 4 | No | — |

## 8. Cleanup and restoration (Phase 1)

Order:
1. Kill the harness tmux clients (zero survivors).
2. Take a final `snap`.
3. `sandbox delete exp008c4-<RUN>` (M6).
4. Wait until no object of the sandbox remains: pod, PVC `workspace-<CR>`, PV, Secret, Service, NetworkPolicy, ConfigMap, ServiceAccount, Role, RoleBinding, Sandbox CR, Cilium policy, VolumeAttachment.
5. The owner deletes the provider and the profile.
6. `post`.
7. `sampler-stop`.
8. `logout`.
9. The owner revokes the key and records the Console spend.

`restoration=matches-pre` requires:
- Argo and GitOps unchanged;
- the gateway StatefulSet generation **unchanged** and the gateway pod UID **unchanged** (Phase 1 has no gateway operation);
- providers and profiles `removed`;
- no PVC, PV or Sandbox CR difference.

**Phase 1 rollback.** Phase 1 changes no gateway setting, GitOps commit, PVC or label, so rollback is the cleanup above. If cleanup stops with the sandbox `Stopped` (after `c4b`), `sandbox delete` from `Stopped` is the supported path, and the per-sandbox PVC is then garbage-collected with the CR. The owner decides any residue; the agent edits no finalizer.

### 8.1 Exclusions

Not part of C4 (each needs its own decision):
- a repeat of C0–C3;
- gateway crash, SIGKILL, scale or upgrade;
- supervisor-pod loss, node drain or node loss;
- graceful (default-grace) workload loss in the same run;
- Kata or RuntimeClass changes;
- Talos ptrace changes (REQ-013 stays Future);
- dynamic per-repository PVCs (REQ-010);
- GitHub or any Git credential, remote or signing;
- Git in the image, or any image rebuild;
- Codex;
- a real Herdr client;
- production Herdr/OpenShell integration;
- `agent-runner`.

Phase 2 is excluded from Phase 1 approval.

## 9. Phase 2 delta (sandbox deletion; only if separately approved)

- **Owner, before `pre`, with no sandbox present:**
  - a GitOps commit enabling `allowDriverConfig` (the gateway restarts);
  - create PVC `exp008c4-state` in the sandbox namespace (RWO, Longhorn, 1 Gi), labelled `openshell.ai/sandbox-attachable=true`, `openshell.ai/sandbox-attachable-workspace=default` and `exp008.c4/run=<RUN>`. The StorageClass reclaim policy (`Delete`, or `Retain` for safety) is the owner's choice.
  - `pre` records the enable commit as the GitOps baseline and the pre-enable commit as the restoration baseline, and requires exactly one attachable-labelled PVC.
- **Create S1** with `--driver-config-json '{"kubernetes":{"volumes":[{"name":"c4-state","persistent_volume_claim":{"claim_name":"exp008c4-state","read_only":false}}],"containers":{"agent":{"volume_mounts":[{"name":"c4-state","mount_path":"/sandbox/c","read_only":false}]}}}}'`. `read_only` defaults to true and must be set false on both. Mount the whole PVC with no `sub_path`.
  - C0 additionally verifies that no `workspace-*` PVC was created (F6) and that uid 10001 can write `/sandbox/c` (fsGroup on Longhorn is U; not writable → STOP).
  - `HOME=/sandbox` is then image-layer and non-persistent; the launcher already places HOME, config and state under `/sandbox/c`.
- **C4a:** as Phase 1.
- **C4b-E:**
  1. `sandbox delete S1` (from `Error`) and wait for no S1 residue.
  2. Verify the PVC: same UID, no `deletionTimestamp`, no ownerReferences, labels unchanged, only `kubernetes.io/pvc-protection` as a finalizer, VolumeAttachment released.
  3. Create S2 `exp008c4-<RUN>-r` with the same driver config and the same package. The launcher finds the state and resumes.
  4. Measurements as 5.4, plus the new sandbox id. Node recorded: RWO re-attach on another node is part of the test.
- **C4c:** as Phase 1.
- **Cleanup:**
  1. Delete S2 and wait for no residue.
  2. Verify the PVC is intact.
  3. The owner removes the attachable labels.
  4. The owner reverts the flag; all driver-config sandboxes must be gone first (3.3).
  5. Verify the revert (3.3 rollback step 4).
  6. The owner deletes the PVC after evidence review, and the PV and Longhorn volume if `Retain`.
  7. `post` reports `restoration=INCOMPLETE pending-owner-delete=pvc` until then.
- **New mutations:** S2 create and delete; nothing that touches the PVC (the harness only reads it).

## 10. Failure and rollback matrix

| # | Failure | Detection | Response | Residue risk |
|---|---|---|---|---|
| 1 | C0 credential path fails (placement refusal, no real model entry) | Stage C C0 checks with the corrected predicate | STOP at C0 → cleanup | None beyond Stage C |
| 2 | C4a gate never satisfied (agent stopped early or batched) | Gate timeout 10 min | STOP; C4 `not-tested`; cleanup | None |
| 3 | Step N completes before the kill | T shows `done N` at the precheck | Record `in-flight-completed`; continue; C4c likely `inconclusive (chain-broken-by-fault)` | None |
| 4 | Original process survives the pod delete (unexpected) | P readable and unchanged | C4a `survived`; C4b and C4c `not-tested`; cleanup | None |
| 5 | Replacement pod runs instead of being fenced | Watch shows Running plus a new P | Record `ran`; take no stop or start; cleanup | None |
| 6 | `sandbox stop` refused or not `Stopped` in 300 s | CLI rc, phase poll | C4b `not-restartable`; cleanup (`sandbox delete`) | CR stuck on a finalizer → owner decides; no finalizer edits by the agent |
| 7 | `sandbox start` refused, times out, or the pod is stuck on volume attach | Phase poll, pod events (`Multi-Attach`, `FailedAttachVolume`) | Record; C4c `not-tested`; cleanup | Longhorn volume attached → owner checks after cleanup |
| 8 | Launcher refuses resume (state mismatch or chain broken) | `launch/precheck-2`, sandbox `Error/MainProcessFailed` | C4b `corrupt`/`lost`; C4c `not-started`; cleanup | None |
| 9 | Claude Code shows a blocking dialog on resume | Screen capture at (b); no model entry | C4c `failed`, dialog recorded; nothing typed beyond the fixed lines | None |
| 10 | New supervisor's credential resolution fails | Proxy decisions, API-error entries | C4c `inconclusive`; cleanup | None |
| 11 | Agent loops on refusals and spends | `spend_check`, refusal rate | 80 % of `BUDGET_USD` → STOP → cleanup | None |
| 12 | Guard trips (context, Argo, GitOps, competing CR) | `guard_full` | STOP → cleanup (cleanup runs once even after STOP) | As Stage C |
| 13 | Wall clock over 60 min from C0 create, or over 20 min after `start` | Guard | STOP → cleanup | None |
| 14 | Upstream 429, 529 or 5xx, or cap exhaustion, during resume | API-error entries, proxy decisions | C4c `inconclusive` (never `failed`); STOP on the spend guard | None |
| 15 | Exec channel fails while the workload is up (P unreadable for a reason other than loss) | Exec error with the pod UID unchanged | C4a `inconclusive`, never `ended`; STOP before M10 | None |
| 16 | Gateway pod restart or Argo sync during the run | Sampler (gateway UID), `guard_full` | STOP → cleanup; result recorded with the confound | As Stage C |
| 17 | STOP while `Stopping` or `Starting` | Phase at STOP | Cleanup waits for a settled phase (≤ 300 s), then `sandbox delete`; never a second `stop` or `start` | CR stuck → owner |
| 18 | STOP while `Stopped` (after `c4b` stop, before start) | Phase | `sandbox delete` from `Stopped` (a valid resting state; cleanup deletes, it does not stop); wait for the PVC, PV and VolumeAttachment to clear before `post` | None expected |
| 19 | `start` stuck on Multi-Attach, then cleanup deletes | Pod events | Delete; record any lingering Longhorn attachment for the owner | Longhorn attachment → owner |
| P2-a | Other attachable-labelled PVC exists, or appears | `pre` and step-boundary names-only check | STOP before create | — |
| P2-b | Flag reverted while a driver-config sandbox exists | Order check in owner procedure | Sandbox fails admission; delete it; proceed | Owner-visible error only |
| P2-c | PVC deleted or recreated by mistake | V mismatch (new UID) | C4b-E `lost`; S2 not created | Data lost (backup optional) |
| P2-d | Revert commit fails to sync | Argo state | Owner fixes forward; `post` `NOT-CLEAN` until synced | Flag still on → owner priority |

**Spend and duration.** Expected about 20–35 model requests (C0 to about step 8 at 45 s per step, one resumed request carrying well under 20K tokens of history, 3–6 further steps, 2 probe lines): ≈ $0.01–0.03 on the transcript estimate. The Console cap is $5 (authoritative) and the harness stops at 80 % of `BUDGET_USD=2`. The section 5.3 caps bound a refusal loop. Agent life is about 20–30 min; the wall-clock STOP is at 60 min from create. Freeze window as Stage C (start before 23:00 local, never 00:30–07:00).

**Evidence and redaction.** As [`stage-c/README.md`](stage-c/README.md) 8.8:
- **Committed:** classifications, P/W/V/D keys, hashes and counts (Tr, T), probe booleans (token present, codeword correct, `LAST` correct, tool count), structural interrupted-turn facts, timelines, inventory diffs.
- **Local only:** transcripts, screen captures, PTY and container logs, codeword, probe tokens.
- The redaction scan also covers the state id, PVC volume handles and node names.

## 11. Superseded C4 assumptions (historical Stage C proposal)

| Historical | Now | Source |
|---|---|---|
| Durable PVC `exp008c-state` and `allow_driver_config` are required for C4b and C4c | Required only for the sandbox-deletion variant (Phase 2). Native `stop`/`start` retains the default PVC (F3) | Section 3 |
| Mount the durable PVC at `/sandbox` | Rejected at `/sandbox`; mount below it, which disables the default workspace (F6) | `driver_mounts.rs:200-210` |
| S2 is a new sandbox with `--resume` in argv | Phase 1: same sandbox, relaunched canonical command; the state-aware launcher chooses resume | Section 5.2 |
| Git commits; T key via `git rev-parse`; Repository row `intact-descendant`, `blocked-by-lock` | Hash-chained ledger; C4b and Repeat/skip axes | [`stage-c/README.md`](stage-c/README.md) D1; section 4 |
| `apiKeyHelper`; `--tools Read,Edit,Bash`; uid 1000; codeword in prompt | Placeholder in `ANTHROPIC_API_KEY` with seeded approval; `--tools Bash`; uid 10001; codeword typed at first attach | [`stage-c/README.md`](stage-c/README.md) D2, D6, D12, D13; FIND-093/095 |
| Local `tar` backup of `repo/` and `claude/` before C4a | Unneeded: the existing `snap` keeps local copies of the transcript and task logs at R | `stagec.sh` `snap` |
| C4 after C1–C3 in the same run | C4 alone; C1–C3 not repeated | Section 5.3 |
| C4c (a) observed while attached | Observed detached, then attached for (b) | Section 5.3 |

## 12. Reusable harness and the implementation boundary (not implemented)

From the independent Haiku inventory of `stagec.sh` at `main` `7705326`:
- **Reusable unchanged:** logging and single-attempt primitives (`once`, `put1`, `need`), the read-only `K` wrapper, `guard_ctx`, Argo/GitOps/provider/profile reads, `spend_check`, `inventory`, `spods`, `snap`, `pkeys`/`wkeys`, `prefix_ok`, the client functions (`client_start`, `client_tree`, `client_scan`, `cap`, `redraw`, `ctrl_l`, `type_line`, `client_kill`, `client_detach`), `gate`, `kwatch`/sampler/`sampler_gate`, `grab_logs`, `waitfor`, `pre`, `post` with `restore-check.sh`, `export.sh`, `launcher.sh` packaging, `task/step.sh`, `task/settings.json`, `task/prompt.txt`, `owner/owner-provider.sh`, and `metrics.py` `m`, `prefix`, `usage`, `screen`, `rawmode`, `ledger`.
- **Reusable with change:**
  - `task/launch.sh`: state-aware mode (5.2); its "refusing to reuse state" guard (line 24) becomes the fresh-mode branch only.
  - `kw`: add M9 (workload pod delete, grace 1, label-checked).
  - `O`: add M10 `sandbox stop` and M11 `sandbox start` for `$SBX` only; Phase 2 also needs a second sandbox name.
  - `guard_full`: the Phase 2 S2 CR.
  - `ident`, `classify_process`: a `new-process` classifier.
  - `metrics.py` `probe`: strict format, codeword, `LAST`, tool count, real-model predicate.
  - `metrics.py` `window`: real-model predicate.
  - `cleanup`: also waits for the VolumeAttachment; in Phase 2 it must *not* wait for the external PVC to disappear, and selects only by sandbox labels.
  - Sampler: CR, PVC, PV and VolumeAttachment.
- **New:** steps `c4a`, `c4b`, `c4c`; the C0 control line; a resume-precheck comparator; the `STEP_SLEEP=45` export. (Phase 2, if ever revised in: driver-config create.)
- **Tests that must change** (they assert today's narrower policy; all are Phase 1 except the second-sandbox create and delete cases, which only Phase 2 needs):
  - `tests/allowlist-test.sh` check 8 ("`kw` allows scale only") and the once-only list;
  - `tests/wrapper-test.sh` lines 22–25 and 59 (refused second-sandbox create/delete and `kw delete pod`);
  - new launch-test cases for resume mode, refusal on mismatch, and no fallback to fresh;
  - real-model predicate negatives;
  - `tests/allowlist-test.sh`: no ephemeral or auto-delete option on `sandbox create`; `start` and `stop` once only;
  - `task/step.sh`: a lock owner record with an empty start time is treated as stale (today it compares empty to empty and reports `busy` forever after a torn write), the boot id is recorded in `locks.log`, and an offline test breaks a dead owner's lock from a different PID namespace (`unshare`);
  - `metrics.py`: the C4c decision procedure, with one test per value and a totality test;
  - an offline resume test that turns the section 2.1 probe into a regression test: pinned binary, loopback mock, a `tool_use` killed mid-run, then plain `--resume`. It asserts CR2, CR3, CR5 and CR6 with the real resume launcher.

Implementation, offline testing and an independent review would form a later PR, after the owner approves this design. Nothing above is written yet.

## 13. Owner decisions required

None of these is granted.

1. **FIND-095 to FIND-097:** accept, amend or reject. The Haiku audit flagged two points for that review: FIND-097's "five POSTs during the outage" is supported only by local logs, and FIND-095's "only placeholder forms in readable files" should read "no real-key shape; placeholder in the environment only".
2. **C4 scope:** approve Phase 1 (native `stop`/`start`) for **implementation and offline testing only**. Phase 2 is deferred by recommendation (section 0 item 3): it would need a revised proposal and its own approval.
3. **Termination mode for C4a:** API delete with `--grace-period=1` (recommended), or the default grace, which matches FIND-090. Only one is run.
4. **Ledger instead of Git:** no image rebuild (recommended). Git recovery deferred to a separate C4-G.
5. **New harness mutations:** M9 workload pod delete, M10 `sandbox stop`, M11 `sandbox start`. Phase 2 adds a second sandbox create and delete.
6. **Probe and continuation wording** (5.6, 5.3 (c)); the C0 control line; `STEP_SLEEP=45` for this run (5.2); the caps (5.3); and the **resume variant**: the default plain `--resume` (recommended: it measures what Claude Code does by itself) or `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1` (CR4: automatic resubmission, closer to what an automated Herdr restore would want). Only one variant per run; the other would be a later run.
7. **H4 real-model predicate** as a precondition of implementation (7).
8. **Execution (later, separately):** a new key, the $5 cap, `BUDGET_USD=2`, the profile and provider recreated, the freeze and redaction list, and the harness commit named in the authorization.
9. **Phase 2 only (if ever revised in):**
   - the GitOps enable and revert window for `allowDriverConfig`;
   - PVC creation, size, StorageClass reclaim policy and label scheme (optional extra required label);
   - who removes labels and reverts;
   - acceptance of the exposure in 3.3.
10. **Evidence retention:** raw transcripts and screens stay local; owner retention or shredding after review.
11. **Owner follow-up, not edited here:** the `1126-1017` record header links REQ-003 and REQ-006, whose conditions were not tested; FIND-095 to FIND-097 cite no REQ ID.

## 14. Open uncertainties (to be measured, not assumed)

1. Whether `sandbox stop` succeeds from the fence-suspended `Error`, and `start` reaches `Ready` (F3, U).
2. Whether the per-sandbox PVC exists while the sandbox is `Error` (F2, U).
3. Whether CR1–CR7, observed offline with a mock and one synthetic step, hold with the real model, a 10–15 step transcript and OpenShell's proxy. A torn final line after a pod kill is the main transcript risk (CR1).
4. Whether the real model re-runs step N after the synthesized interrupted result (CR3), which tells it to check "whether it took effect", or tries N+1 first and recovers from the refusal.
5. Whether a resume shows any dialog that blocks a detached TUI (CR7; the approval-tail case is handled in 5.2).
6. Longhorn RWO detach and attach timing across nodes, and fsGroup on an external PVC (Phase 2).
7. Whether Haiku re-runs step N correctly after a synthesized interruption, or tries N+1 first (both are classified).

## 15. Review record

- **Haiku evidence and traceability audit (2026-11-26):** FIND-095–097 cross-checked against the exported evidence (supported, with the gaps in section 13 item 1); traceability gaps (item 11); harness inventory (section 12); superseded assumptions (section 11); the two harness weaknesses located (section 7).
- **Sonnet storage and security review (2026-11-26):** source at OpenShell v0.1.9 and Agent Sandbox v1.0.12 (section 3, F1–F9; section 3.3). Main corrections to the historical design: a mount at `/sandbox` is rejected; any mount below it disables the default workspace; native `stop`/`start` exists; the current flag value is `false`.
- **Sonnet Claude Code resume review (2026-11-26):** static review of the pinned binary plus the offline loopback probe (section 2.1, CR1–CR7). It changed the design in four places: no `--session-id` on resume; no positional prompt; the auto-continue variables are unset by default and offered as a variant; the expected outcome is `resumed-continued-after-prompt`.
- **Haiku completeness audit of the draft (2026-11-26):** three blockers, all fixed:
  - the accepted-findings citations;
  - the C4c pass rule was inconsistent between sections 1 and 6.3;
  - the "stop retains the workspace" qualifier and the Suspended-phase comment.

  Should-fix items, fixed: the title wording, a definition of *M*, label collisions (storage option X → E, resume facts R → CR, keys I → D and S → Tr), `chain-broken-by-fault` placement, an exclusions list, the mutation count, the GitOps-value provenance, and Phase 1 rollback.
- **Sonnet independent design and security review of the draft (2026-11-26):** two blockers, both fixed. The C4c classes were not exclusive or exhaustive (now an ordered decision procedure with `responded-no-progress` and `probe-ignored`). Ledger partial-write states were unclassified (now `in-flight-partial(k)` → `chain-broken-by-fault`). Should-fix items, adopted:
  - the token-chain claim narrowed to step N, with a command-regex check and the permission-rule limit stated;
  - `STEP_SLEEP=45`, R from the sampler plus one exec, and an abort on an incomplete R;
  - launcher mode guards, the auto-continue variables, both `.claude.json` copies, and the lost-state limit;
  - the stale-lock empty-start case;
  - the probe tool rule made explicit;
  - a bounded transcript-tail allowance;
  - seven failure-matrix rows;
  - hard caps.

  Its minimality advice was adopted in part. The control probe is folded into C0, and Phase 2 is deferred. The Phase 2 analysis and the CR4 variant stay in the document, because the assignment asked for the storage and `allow_driver_config` analysis.
