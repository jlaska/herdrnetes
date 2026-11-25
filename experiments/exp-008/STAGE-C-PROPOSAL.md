# EXP-008 Stage C: real agent, continuity vs reattachment vs native recovery (PROPOSAL; research only; not approved; nothing run)

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../docs/experiments/08-openshell-execution.md) · REQ-003, REQ-006, REQ-009, REQ-011 · ADR-0001 unchanged

**Status.** This is an agent-generated research proposal (2026-11-24) for owner review. It was revised once after an independent design review, which found that credential delivery as first written was impossible, that one recovery class was unreachable, and that the work-during-window metric was invalid.
- No sandbox, provider, PVC, gateway restart, agent invocation or API credential was created or used to write it.
- No Stage C step is authorized. Section 8 lists the approvals it would need.
- Nothing here changes ADR-0001, a requirement status or an accepted finding.

**Basis (immutable references).**
- **Stage A:** accepted FIND-077 to FIND-087, [`local/README.md` at `fa38e50`](https://github.com/jlaska/herdrnetes/blob/fa38e5078345da4ae9a88fab5902cbf795578731/experiments/exp-008/local/README.md).
- **Stage B:** the approved proposal is revision 4, [`33291ef`](https://github.com/jlaska/herdrnetes/blob/33291effcee234bf34c732bee0e85b1a53e97843/experiments/exp-008/STAGE-B-PROPOSAL.md) (draft PR #42). Results are in [`k8s/README.md` at `844580c`](https://github.com/jlaska/herdrnetes/blob/844580c190afaeb4814a4a41e8eee30408f7613d/experiments/exp-008/k8s/README.md) (PR #43).
- **FIND-088 to FIND-091 are proposed, not accepted.** This proposal depends on FIND-088 and FIND-090, so it should not be approved before the owner has reviewed them (section 8, item 1).

**Labels.**
- **O**: observed in this repository's committed evidence.
- **S**: confirmed in upstream source or docs at a named version. **S\*** means the lead agent re-read it for this proposal.
- **I**: inference.
- **H**: hypothesis that Stage C would test.
- **U**: unknown; needs a live read.

Upstream sources:
- OpenShell `v0.1.9`, `ce58cf8e9b953281352d98a637e41616295b1318`.
- Codex `rust-v0.172.0`, `3d86e43b`. This is **newer than the repo's only Codex pin**, 0.169.0 in EXP-002.
- Claude Code docs fetched 2026-11-24. They document builds up to at least 2.1.327; the repo pins **2.1.323**.

Version-specific claims therefore need a check against the pinned binaries (C0).

## 1. Questions and three separate capabilities

Stage C asks three questions. Each maps to one capability, and each capability has its own pass rule. A pass on one says nothing about the others.

| | Q1 → **Process continuity** | Q2 → **Session reattachment** | Q3 → **Native conversation recovery** |
|---|---|---|---|
| Question | Can a real agent keep working while its terminal client (the Herdr stand-in) is gone and the OpenShell gateway restarts? | Can the user reattach to the **original** process and get a usable terminal back? | After workload-pod loss, can a **new** sandbox restore the agent's native session and continue useful work, with repository state intact? |
| Process | The same process throughout | The same process (continuity is a precondition) | A **different** process, by definition |
| Pass rule | All process keys unchanged (section 4.1), **and** model-driven task progress *during* the fault window (section 3.3 rule) | A fresh `connect` reaches the same process keys, the screen becomes coherent, and typed input reaches the agent and is answered in the same session | New process keys; the pre-fault transcript prefix preserved byte-for-byte and loaded; a context probe answered with no tool use; the task continuing from the in-flight or next step with no re-attempt of completed steps; and repository state equal to the pre-fault snapshot or a strict descendant of it. The native session id is recorded as an attribute (section 4.2) |
| Looks like a pass but is not | A UI on screen after reconnect. Stage A's supervised reconnect reached a *replacement* (FIND-085) | Output replayed from the 1 MiB ring while input is still owned by a stale client. The screen shows the agent but you cannot type | The agent starting a new session and redoing the task from the repository. The repository looks right, but the conversation was not recovered |
| Prior evidence | Synthetic process on this driver: survived gateway restart and short-grace termination (proposed FIND-088, FIND-089). Real agent under tmux, not OpenShell: survived pane close and Herdr pod replacement (FIND-076). Work while detached: never observed (EXP-006 K03 INCONCLUSIVE) | Synthetic: same-process ACK after reattach (FIND-088). Real-agent TUI through OpenShell: never | Claude Code resume through Herdr hooks, local (FIND-007, FIND-008). Never on OpenShell. Workload-pod loss gives a permanent `Error` (proposed FIND-090) |

Kubernetes or OpenShell readiness is evidence for none of the three (AGENTS.md).

## 2. What is known, and what Stage C has to measure

| # | Statement | Label | Source |
|---|---|---|---|
| K1 | The supervisor side owns the main-process PTY output. A reader drains it in 4 KiB reads into a ring of at most 1 MiB, whether or not a client is attached. Detaching ends only the attachment and the input ownership, and sends the workload no signal | S\* (buffer and detach constants); S (close path) | `crates/openshell-supervisor-process/src/main_session.rs:21,75-95,230-270`; `ssh.rs:44-46,525-540` |
| K2 | Therefore a detached TUI agent should not stall on a full PTY or get SIGHUP. The master fd's lifetime inside the Kubernetes boundary runtime was not read | I / U | — |
| K3 | Attach replays the retained ring as raw bytes, then goes live. There is no screen-state emulation, so the replay can start mid-escape-sequence and lose the alternate-screen entry. A client that falls behind is disconnected with "attachment fell behind by N output chunks" | S (replay); S\* (message, `ssh.rs:884`); I (garbling) | `ssh.rs:853`; `main_session.rs:96-110` |
| K4 | While a client owns input, Ctrl-P Ctrl-Q detaches. A Ctrl-D byte **anywhere** in the input ends the attachment and is not forwarded. A lone Ctrl-P is held pending. A second attach while an owner holds input prints "attached read-only; retry input after the owner disconnects" | S\* | `ssh.rs:44-46,57-70,862,2219` |
| K5 | Model-API egress goes workload → supervisor-pod proxy → internet. The gateway is not on the request path. A provider credential reaches the agent only as a placeholder (`openshell:resolve:env:…`), which the supervisor's proxy swaps for the real value on allowed endpoints | S | `docs/how-it-works/providers/overview.mdx` ~447-540; `docs/about/architecture.mdx` |
| K6 | A static API key should keep resolving during a short gateway outage, because the supervisor caches it. Expiring or gateway-refreshed credentials, and the 3600 s sandbox JWT, depend on the gateway | I (cache path not traced); S (JWT, Stage B revision 4 section 2.2 item 4) | `profiles.mdx` ~1233-1238 |
| K7 | Provider changes never reach a running process. Providers must be attached at `sandbox create` | S | `profiles.mdx` ~1237 |
| K8 | For the default `sandbox` user (or a numeric `run_as_user`), HOME is `/sandbox`, which on Kubernetes is the per-sandbox workspace PVC. A named user takes its passwd home. That PVC is deleted with the sandbox (reclaim `Delete`) | S\* (HOME: `crates/openshell-sandbox/src/process.rs:190-247`); O (PVC lifecycle, Stage B cleanup) | — |
| K9 | `workspace_mode = "shared"` maps workspaces to namespaces. It is not shared storage | S\* | `docs/kubernetes/workspaces.mdx` |
| K10 | A pre-existing PVC can be mounted through `--driver-config-json`, and "any mount under `/sandbox` replaces the default workspace PVC". This requires the gateway setting `allow_driver_config = true` (default off) and the PVC labels `openshell.ai/sandbox-attachable=true` and `openshell.ai/sandbox-attachable-workspace=<workspace>` | S\* | `docs/how-it-works/sandboxes/runtimes.mdx:324-357`; `docs/upgrade/0-1-0.mdx:61` |
| K11 | Claude Code stores each session as `$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<session-id>.jsonl`. `--resume <id>` restores history and the model, but not CLI flags such as `--settings`, `--tools` or MCP config (matches FIND-008). An interrupted turn is not continued by default. A tool that was running when the process died is not re-run. The transcript format is internal and version-dependent | S (docs, 2026-11-24); O (FIND-007, FIND-008, Claude Code 2.1.311) | — |
| K12 | Claude Code retries transient API failures up to 10 times (`CLAUDE_CODE_MAX_RETRIES`). Codex waits indefinitely on connection failure by default (`unbounded_connection_retries`, delay capped at 60 s) | S | Claude docs; Codex `features/src/lib.rs:1667-1672`, `core/src/responses_retry.rs:24` |
| K13 | Codex stores rollouts as `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`, and `codex exec resume <uuid>` resumes one | S (at 0.172.0, not at the 0.169.0 pin) | `codex-rs/rollout/src/lib.rs:88` |
| K14 | OpenShell ignores the image entrypoint (Stage A PLAN.md:78), so the published EXP-006 agent image could run `claude` directly as the main process without the image's sshd and tmux | O (entrypoint behaviour); I (usable as is) | — |

**To measure (H):**
- H1: work continues while detached, and during a graceful gateway restart, with model calls going through the supervisor proxy.
- H2: a fresh `connect` reattaches to the same process, and the TUI becomes coherent after a forced redraw.
- H3: after workload-pod loss, a new sandbox that mounts the same durable state restores the conversation and continues the task without re-doing completed steps.
- H4: Claude Code 2.1.323 accepts the provider placeholder as its API key.

## 3. Minimal design

### 3.1 Reuse, and what is new

**Reused unchanged:**
- the Stage B installation (OpenShell 0.1.9 gateway, Agent Sandbox v1.0.12) as run 3 left it, prerequisite fixes included;
- the Stage B harness pattern: fixed mutation allowlist, read-only Kubernetes wrapper, guard at every step, samplers, per-run inventory and diff, one attempt per step;
- the change freeze and the isolated CLI HOME with the owner's OIDC login.

**Reused image:** the published EXP-006 agent image `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18`.
- It is built on Stage B's workload base (`9c8fc9d0…7a16`) plus Claude Code 2.1.323, whose sha256 is verified at build (`experiments/exp-006/exec-image-agent/Containerfile:24-31`; `k8s/stage3/exec-pod.yaml:56`). O
- It runs with a launcher command passed to `sandbox create`. No rebuild is proposed; if C0 shows the image cannot run under OpenShell, stop and report.

**New in Stage C (each needs approval, section 8):**
1. **One OpenShell provider** holding a dedicated, capped Anthropic API key (section 5), with a reviewed copy of the upstream `claude-code` profile.
   - Endpoints: `api.anthropic.com:443` only.
   - `binaries: [/usr/local/bin/claude]`.
2. **One owner-created durable PVC** (`exp008c-state`, RWO, labelled as attachable for the `default` workspace), mounted into both sandboxes. It holds:
   - `repo/`: a seeded, throwaway local Git repository with no remote;
   - `claude/`: `CLAUDE_CONFIG_DIR`;
   - `launch/`: launcher identity records.
3. **The gateway setting `allow_driver_config = true`** for the run window, through GitOps, owner-performed, reverted afterwards.
   - It is the only route K10 documents for mounting a durable PVC.
   - Admission still rejects hostPath, CSI, projected, image and configMap volumes and requires both PVC labels (S, `crates/openshell-driver-kubernetes/src/resource_admission.rs` ~474). The real widening is that **any** user of this gateway could mount **any** PVC labelled for the workspace, so C0 lists the labelled PVCs (names only).
   - If the owner declines it, C4b and C4c are dropped and Q3 stays open (section 4.3).
   - This is one static, owner-created PVC. No conclusion about dynamic per-repository PVCs (REQ-010) follows from it.
4. **A harness extension** (`stagec.sh`, not written yet). It adds:
   - transcript and progress metrics read by exec;
   - a local tmux-hosted `sandbox connect` for screen capture;
   - termination-state capture on any pod that turns `Failed`, before a rollback can delete it (FIND-091 lesson);
   - a stop if either Argo app is not Synced/Healthy at `pre` (the Stage B harness limitation);
   - raw captures written **outside the working tree** (as Stage B's `~/.cache/hxb`), with the secret and hostname scan of section 5.1 MUST-6 run on the staged diff before every commit.

**Explicitly excluded** (AGENTS.md):
- Git remotes and pushes, GitHub credentials, signing, and the EXP-004 issuer;
- `agent-runner`, Kata, dynamic per-repository PVCs;
- multi-replica gateways, SIGKILL or node faults, supervisor-pod deletion, and gateway upgrade or rollback;
- Herdr itself, beyond what Stage A established. The client is a `sandbox connect` PTY that stands in for Herdr. FIND-082 showed the client chain ends with the Herdr server, so a Herdr stop looks to the sandbox like a client close. That equivalence is an inference.

### 3.2 Launch and identity

Sandbox S1 runs one main process, launched by a two-line `sh` wrapper. The wrapper:
- generates a random nonce;
- exports `EXP008_NONCE`;
- writes `pid`, `/proc` start time, boot id, nonce and UTC time to `launch/<ts>`;
- then `exec`s `/usr/local/bin/claude`.

Because the wrapper uses `exec`, the agent keeps the wrapper's PID. The flags are:
- `--settings <file on PVC>` and `--tools Read,Edit,Bash`;
- `--model claude-haiku-5-5` (as in EXP-006 run `s3b`);
- `--session-id <uuid>`;
- an `apiKeyHelper` that echoes `$ANTHROPIC_API_KEY`, the placeholder, so that no interactive key-approval prompt appears (I; checked in C0);
- the initial prompt as a positional argument.

The working directory is `<state>/repo` in both sandboxes, so the transcript slug is identical.

**Pre-seeded configuration.** A fresh `CLAUDE_CONFIG_DIR` shows onboarding and the folder-trust dialog, which would block the positional prompt until someone attached. The launcher therefore pre-seeds `hasCompletedOnboarding` and `hasTrustDialogAccepted` for `<state>/repo`, as EXP-006 did (`experiments/exp-006/exec-image-agent/entrypoint-agent.sh:98`). C0 confirms that no dialog appears.

**Exec identity.** The read-only exec that reads `/proc/<pid>/environ` must run as the agent's UID, or have ptrace rights (the Talos ptrace adjustment is relevant here). C0 records the exec user. If the read is refused, the launcher's `launch/<ts>` record is the fallback nonce source, and the step is marked accordingly.

S2, the recovery sandbox, uses the same wrapper with `--resume <uuid>` and **the same settings file and flags**. FIND-008 and K11 show resume does not restore flags.

### 3.3 Task

The task is the K03 fix: it must outlast every fault window and leave side effects that can be counted.

- The seeded repository has `step.sh N TOKEN`. It:
  - checks that `TOKEN` is the one-time token printed by step `N-1` (step 1 takes a fixed token), and refuses otherwise;
  - appends `attempt N <utc>` to `attempts.log`;
  - sleeps 20 s;
  - appends `done N <utc>` to `progress.log`;
  - commits;
  - prints a fresh random token for step `N+1`.
- `step.sh` refuses a repeated or out-of-order `N` and appends the refusal to `refusals.log`.
- The prompt tells the agent to:
  - run steps 1 to 120, one `step.sh` call per tool call, passing each printed token to the next step;
  - check each result;
  - remember a codeword that the harness never writes to a file (EXP-006 pattern).
- At about 20 s of tool time plus model latency per step, the task runs for roughly 45 min (I). That leaves margin for the C1 and C2 holds, the probes, and at least 8 steps still to do before C4a and 3 after resume.
- Faults are gated on observed progress, never on wall time: at least 3 `done` lines, and an `attempt` with no `done` (a step in flight).

**What counts as work during a window.** A `done` line alone is not evidence of model calls: the 20 s sleep that was in flight when the window opened finishes on its own, with no model involved. The token chain makes batching harder, but a shell loop could still parse tokens. So:
- A window is `progressed` only if there are **at least two** steps whose `attempt` is timestamped **after** the window opened. Each must be the first `step.sh` invocation of its own `tool_use` entry, and each must have an `assistant` transcript entry timestamped inside the window.
- A tool call that runs more than one `step.sh` is recorded as `batched`, and its steps do not count.

Because the gateway is not on the model-request path (K5), C2 mainly tests that the supervisor's proxy and its cached credential keep working while the gateway is down (K6). It does not test gateway effects on model calls.

## 4. Test matrix and classification

### 4.1 Identity and evidence keys

| Key | Source | Used for |
|---|---|---|
| **P**: PID, `/proc/<pid>/stat` start time, boot id, `EXP008_NONCE` read from `/proc/<pid>/environ` (that variable only) | read-only exec | Process identity |
| **W**: workload pod UID, container ID, restartCount, node | Kubernetes reads | Pod identity |
| **S**: session id, transcript path, line count, sha256 of the first *k* bytes as of the last pre-fault sample | read-only exec on the PVC | Native session identity and prefix preservation |
| **T**: `attempts.log`, `progress.log` and `refusals.log` (index, timestamp), `git rev-parse HEAD`, `git status --porcelain`, `git ls-files -s \| sha256sum`, presence of `.git/index.lock` | read-only exec | Work done and repository state |
| **Q**: for each probe turn, the unique probe token in a transcript `user` entry, the reply in the following `assistant` entry, and the **number of `tool_use` entries in that turn** | read-only exec on the transcript | Whether input reached the agent, and whether an answer came from context rather than from reading files |
| **R**: attach latency; replayed bytes; whether the client printed the read-only notice (K4) or "fell behind" (K3); a tmux `capture-pane` as replayed and after a forced redraw (two resizes) | local tmux around `sandbox connect` | Reattachment and terminal state |
| **X**: on any transition to `Failed`, the container exit code, reason and `lastState`, plus workload container logs | Kubernetes reads | FIND-091 lesson |

### 4.2 Classification (pre-registered; one value per axis per step)

**Thresholds, fixed before the run.** *M* is the median interval between consecutive `attempt` lines over the first 5 steps of C0.
- A process is **frozen** if it shows no new `attempt` and no new transcript entry for more than 3 × *M*.
- The **in-flight allowance** at C4 is exactly one step: the step whose `attempt` has no `done` in the C4a snapshot.

| Axis | Values |
|---|---|
| **Process** | `survived` (P and W unchanged) · `survived-frozen(N s)` (P unchanged, frozen for N s) · `restarted` (any P or W change) · `unavailable` · `inconclusive` |
| **Work during window** | `progressed` (section 3.3 rule) · `stalled-then-recovered` (frozen during the window, `progressed` within 3 × *M* after it) · `stalled` · `batched` · `n/a` |
| **Reattachment** | `same-process-writer`: P unchanged, no read-only notice, and the probe token appears in a transcript `user` entry. A late reply from a busy agent is still writer evidence.<br>`same-process-read-only`: P unchanged, read-only notice printed, probe token absent.<br>`replacement`: P changed, or the connect reached something other than the original process (the FIND-085 pattern).<br>`lagged`: "fell behind" disconnect; one reconnect is allowed within the step, and both attempts are recorded.<br>`failed` |
| **Terminal state** | Decided mechanically on the `capture-pane` text, with captures kept local.<br>`coherent-on-replay`: Claude Code's input prompt line is present in the replayed capture, with no literal escape-sequence fragments (`\x1b[` remnants or `[?1049` visible as text).<br>`coherent-after-redraw`: the same rule holds only after the forced redraw.<br>`garbled`: neither holds.<br>`n/a` |
| **Native recovery** | Judged on **content**. The session id is recorded as a separate attribute (`same-id` or `new-id`), because FIND-007 and FIND-008 never recorded whether 2.1.323 keeps the id on resume.<br>`resumed-auto-continued`: pre-fault transcript prefix preserved, the in-flight or next step attempted **before any input**, codeword answered with **zero `tool_use`** in the probe turn.<br>`resumed-continued-after-prompt`: as above, but work resumed only after the fixed "continue" prompt.<br>`resumed-context-lost`: prefix preserved, codeword wrong or found by a tool call.<br>`re-executed`: prefix not loaded, or steps already done were re-attempted (repeated `attempt N` or `refusals.log` entries beyond the in-flight step).<br>`failed`<br>`not-tested` |
| **Repository** | `intact`: equals the C4a snapshot.<br>`intact-descendant`: C4a commits preserved, plus new ones, with at most the in-flight step re-attempted.<br>`blocked-by-lock`: a stale `.git/index.lock` from the kill, recorded separately so it is not misread as an agent failure.<br>`diverged`<br>`lost` |

A step that hits a stop condition is recorded as it stands and never retried (as in Stage B).

### 4.3 Steps

All steps run in one run, in this order, with one attempt each.

| Step | Action | Answers | Expected (H) |
|---|---|---|---|
| **C0** preflight | See section 5.3 for the credential checks. Then:<br>• create S1 (provider attached, durable PVC mounted);<br>• check that HOME, `CLAUDE_CONFIG_DIR` and `repo/` are writable by the sandbox user, and whether `/sandbox` seeding was skipped;<br>• first attach;<br>• confirm the agent started steps with the placeholder key (H4) | Viability. Any failure stops the run | — |
| **C1** detach while working | Gated on progress, **abruptly** end the only client: SIGKILL the local `sandbox connect` process, which is how a Herdr server stop looks (FIND-082). No Ctrl-P Ctrl-Q, no Ctrl-D (K4). Hold for at least 4 × *M* with no client. Record the window metrics, then reattach | Q1 without a gateway fault (closes the K03 gap); Q2 after an abrupt client loss, including how long the stale input owner lasts | survived · progressed · same-process-writer (or read-only for a while: measured) · coherent-after-redraw |
| **C2** gateway restart while detached and working | Gated on progress, with no client attached: `scale` the gateway 0 → hold 90 s → 1 (Stage B's B2 shape; outage ceiling 240 s). Record the window metrics. Reattach only after the sandbox is Ready again | Q1 in full (client gone, gateway restarting, model calls through the supervisor proxy and cached credential); Q2 after a gateway replacement | survived · progressed (I: K5, K6) · same-process-writer · coherent-after-redraw |
| **C3** reattach and terminal check | Part of C1 and C2, and only **after** that window's metrics are recorded. On each reattach:<br>• capture the screen as replayed;<br>• force a redraw and capture again;<br>• type one probe with a unique token: "Reply PROBE-<token> and the last step you completed, then continue the task";<br>• record **Q** and **R** | Q2's terminal state and input path, without the probe ending the task | coherent-after-redraw; garbled on replay is plausible (K3) |
| **C4a** workload-pod loss (short-grace) | Gated on progress, with a step in flight and at least 8 steps still to do:<br>• snapshot **S** and **T** by exec (the C4a reference state);<br>• take a local, non-repository `tar` of `repo/` and `claude/` as a backup **only** (stored outside the working tree, never committed, never used as the recovery path);<br>• immediately `delete pod <workload> --grace-period=1` (SIGTERM, then SIGKILL after 1 s), cutting the in-flight step.<br>Record W, X and the sandbox phase. After the delete nothing can exec into S1 (FIND-090) | Confirms FIND-090 with a real agent under a near-abrupt loss; fixes the reference state | restarted/unavailable; S1 `Error`. A graceful (30 s) pod loss is **not tested**; Claude Code could flush and exit cleanly there, so the two must not be generalised to each other (AGENTS.md) |
| **C4b** state survives the sandbox | Delete S1. Verify that the durable PVC object still exists (UID unchanged). Its contents are checked by S2's launcher: before it `exec`s `claude --resume`, it writes the transcript line count, prefix hash and **T** to `launch/<ts>`. The harness compares that with the C4a snapshot. The only allowed difference is the in-flight step (at most one `attempt` line, and possibly its `done` line and commit) | Whether durable state outlives sandbox deletion, and what the in-flight step left behind | PVC retained (H: OpenShell does not delete a PVC it did not create) |
| **C4c** native recovery | Create S2 with the same provider, mount and flags, plus `--resume <uuid>`. Then follow a fixed sequence:<br>(a) **observe 4 × *M* with no input**, attached but typing nothing;<br>(b) one probe with a unique token: "Reply PROBE-<token> with the codeword from this conversation. Do not use tools.";<br>(c) one fixed prompt: "Continue the task from the next step.";<br>(d) run until at least 3 further `done` lines, then stop the task.<br>The classification records which stage, (a) or (c), resumed the work | Q3 | `resumed-continued-after-prompt` is the likely result (K11: an interrupted turn is not continued by default); repository intact-descendant or blocked-by-lock |
| **Cleanup** | Delete S2. The owner deletes the provider and the durable PVC, reverts `allow_driver_config`, and revokes the key. Post-run inventory diffed against this run's `pre` **and** against the Stage B run-3 baseline | Installation left as found | — |

**Dropped to stay minimal:**
- a B3-style 1 s-grace gateway kill (no new information expected beyond FIND-089 unless C2 fails);
- second clients and single-writer behaviour (FIND-086);
- multi-hour soaks;
- network-blocking tests of the agents' retry behaviour (K12);
- every lifecycle event Stage B listed as untested.

**If `allow_driver_config` is declined:**
- Run C0–C3 and C4a with the default per-sandbox PVC.
- Record C4b and C4c as `not-tested`.
- Q3 stays open. Do **not** substitute helper pods, `kubectl cp` from the orphaned PVC, or a resume inside the same sandbox. None of them is the recovery path in question.

**Coupling between steps.** Q3 does not depend on Q1. If C1 or C2 reads `restarted`, record it, re-baseline P and W, and continue to C4 once progress gates again. Native recovery matters most when continuity fails. C4 is skipped only if S1 is `unavailable` or fewer than 8 steps remain.

**Scope of a Q3 result.** It holds only for durable state on an **externally owned** PVC. With the default per-sandbox PVC, the state dies with the sandbox (K8). The result template must say so.

**Stop conditions:**
- any credential check in section 5.3 fails;
- S1 `unavailable` in C1 or C2;
- guard, kube-context or Argo-state mismatch;
- gateway not Ready within 240 s;
- spend reaches 80 % of the workspace cap;
- wall clock over 90 min from C0.

## 5. Credentials and security boundaries

### 5.1 Requirements

**MUST:**
1. Use a **new, dedicated** Anthropic Console workspace with a spend cap and one new API key, created and revoked by the owner (EXP-006 pattern). Record the revocation in the evidence.
2. Deliver the key only as an explicit OpenShell provider, created by **one owner-run command in the owner's own terminal**.
   - `provider create --credential` accepts only `KEY=VALUE` (argv) or `KEY` (the value is read from the CLI process's environment). It has no file form (S\*: `crates/openshell-cli/src/main.rs:873-879`).
   - So the only form that keeps the key out of argv is the environment lookup, scoped to that one process, for example `env -i HOME=<isolated> PATH=<…> ANTHROPIC_API_KEY="$(cat <0600 file>)" openshell … provider create … --credential ANTHROPIC_API_KEY`.
   - For that process's lifetime, the key is readable through `/proc` by the same UID. Command lines and environments of this step must not be logged by the harness, and shell history must not record the value.
   - `KEY=VALUE` in argv is forbidden.
   - Never use `--auto-providers` or the interactive "create from local credentials" prompt. Both upload whatever `ANTHROPIC_API_KEY` the CLI's environment holds (S\*: `crates/openshell-cli/src/commands/provider.rs:382` `ensure_required_providers`, `:475-516` prompt "Create from local credentials?"). The harness's own CLI environment therefore never contains the variable (MUST-3).
   - Never use `--from-oidc-token`.
3. Run the CLI under an isolated HOME whose environment has none of `ANTHROPIC_*`, `OPENAI_*`, `CLAUDE_*`, `GH_*` or `SSH_AUTH_SOCK`, as in Stage B.
4. Run Claude Code in API-key mode only. No `/login`, no `claude setup-token`, no `CLAUDE_CODE_OAUTH_TOKEN`. Both subscription forms bind the owner's personal account and need token refresh, which a placeholder would break (S/I).
5. Use only a reviewed, edited profile: endpoint `api.anthropic.com:443` and binary `/usr/local/bin/claude`. Telemetry hosts are allowed only by explicit owner decision.
6. Keep transcripts, PTY captures, gateway logs and the durable PVC contents **local**. Commit only derived metrics, hashes, counts, timestamps and classifications. Before any commit, scan for key prefixes, `openshell:resolve:env`, JWT shapes, pod IPs and internal names.
7. Follow the AGENTS.md Git policy for all repository changes.

**MUST NOT:**
1. Use the owner's claude.ai or ChatGPT logins, `~/.claude/.credentials.json`, `~/.codex/auth.json`, or the upstream OpenShell Codex example as written (it builds its provider from the host's `~/.codex/auth.json`).
2. Place any GitHub, GPG, SSH or YubiKey credential or agent socket in the sandbox, the gateway or the CLI environment.
3. Fall back silently to a real key inside the sandbox if the placeholder fails. That is a recorded result (H4 falsified), and any fallback (for example, EXP-006's key-as-Secret-file) is a separate owner decision.
4. Implement any credential infrastructure in Stage C. That covers the EXP-004 issuer or helper, a GitHub provider, a new OpenShell credential driver and any signing relay.

### 5.2 Trust boundaries (condensed)

| Boundary | Credential present | Who can read it | Control |
|---|---|---|---|
| Owner workstation / CLI host | GPG/SSH/YubiKey, `gh` token, personal agent logins | The operator UID, including agent processes running as it (FIND-055) | Isolated CLI HOME and a clean environment. Agents never sign or push with the owner's keys |
| Run key file | The dedicated API key | Operator UID | Spend cap; revoke and shred after the run |
| OpenShell CLI session | The owner's OIDC token | Operator UID | Owner login for the run window, logout at cleanup (as in Stage B) |
| Kube credential | **cluster-admin** (Stage B B0) | Operator UID and harness | Harness allowlist, explicit context, freeze. RBAC cannot narrow it unless the owner provides a namespaced credential (decision) |
| Gateway | The provider secret (AES-GCM envelope in its DB, key-encryption key in a K8s Secret) and the JWT signing keys | The gateway process; cluster-admin can recover both (I) | Dedicated provider name, deleted at cleanup. The gateway DB is **shared state**; check names only for existing providers first |
| Supervisor pod | The real key in memory, and its JWTs | cluster-admin (exec); **not** the workload | Policy endpoint and binary binding. Its NetworkPolicy allows all egress (S, `isolation.rs:140-205`), so an optional owner-added Cilium FQDN policy is a second layer |
| Workload pod (the agent) | The **placeholder** only, plus everything on its PVC | The agent and any prompt-injected content | The agent can **use** the key through the proxy for allowed hosts but cannot read it. Response bodies are not scrubbed, so allow only `api.anthropic.com`. Its NetworkPolicy has empty egress (S) |
| Durable PVC | Transcripts and tool output that may echo sensitive text | The agent, cluster-admin | Never committed; deleted at cleanup |
| Model API | The key | Anthropic | Spend cap; revoke |
| GitHub | **None** in Stage C | — | No remote. A throwaway repository on the PVC |

### 5.3 Credential checks in C0

1. **Names only:** list existing providers and profiles and the credential backend on the gateway before creating anything (U today).
2. After S1 starts, an operator-side check confirms that the workload environment and the durable PVC contain the placeholder and **not** the real key. It matches a key suffix without printing it.
3. Run a negative egress probe from the workload to a disallowed host, which must fail, and a request to an allowed host from a non-allowlisted binary, which must not be credentialed. Stage B proved neither (U).
4. The first model call goes through the proxy. Check spend on the workspace afterwards (the EXP-006 lesson from K00b: an auth-only check does not show the key can spend).

### 5.4 How EXP-004 relates

- EXP-004 built a repository-scoped, short-lived GitHub credential path: an on-demand helper plus an issuer for App installation tokens, with revocation.
- Only its quick check ran against real GitHub (FIND-057, 16 checks). The issuer itself never has. Everything else is mock or offline (FIND-042 to FIND-056).
- Its key limit is FIND-044: inside a shared pod, a minted token belongs to the workload, not the agent, and reaches the agent's UID.
- OpenShell's supervisor-side substitution keeps a credential **out of the agent's process and filesystem**. That is a stronger boundary than EXP-004's in-pod helper (S for the mechanism, H for GitHub, untested). Two candidate later integrations follow (proposal only):
  - an EXP-004-issued, repository-scoped token held as an OpenShell provider, with `github.com` as its only endpoint;
  - EXP-004's revocation and audit model applied to provider lifetime.
- Stage C needs neither. It has **no Git credential**: work stays in a local repository on the PVC.
- The owner should treat "scoped agent Git authentication through OpenShell" as a **separate, later experiment** that builds on EXP-004 (section 8, item 14). Stage C does not decide it.

## 6. Which agent, in what order

**Recommendation: Claude Code first, alone. Codex second, narrowly, only after Claude Code's results are reviewed, and under a separate approval.**

**Why Claude Code first:**
- A pinned, sha256-verified image already exists on the same base as Stage B (O).
- This repository already holds Claude Code resume evidence (FIND-007, FIND-008) and real-agent continuity evidence (FIND-076). Stage C extends that evidence rather than starting a new baseline.
- API-key mode avoids subscription OAuth. `--session-id` and `--resume <id>` give an explicit session identity.
- The EXP-006 `apiKeyHelper` path avoids the interactive key prompt.

**Why Codex second:**
- No image exists. The only pin (0.169.0, EXP-002) was never run, and it differs from the analysed 0.172.0.
- A new image needs an owner-run CI build, because the agent token cannot install workflows.
- OpenShell's shipped `codex` profile is built for ChatGPT OAuth and copies the owner's `auth.json`, so a custom API-key profile with a separate OpenAI project key is needed.
- It is valuable later because its resume path is open source and checkable at the pinned tag, and because its retry behaviour differs (K12: it waits indefinitely on connection failure).

**Minimal Codex follow-up (sketch):**
- X0: preflight.
- X1: C2's shape.
- X4: C4's shape, with `codex resume <uuid>` and `CODEX_HOME` on the durable PVC.
- Same classifications.

Running both agents in Stage C would double credential setup, spend and owner review, for a second agent that has no baseline here.

## 7. Evidence and cleanup

**Evidence:**
- Commit per-step classifications.
- Commit the key tables, at these levels of detail:
  - P and W;
  - S: hashes and counts only;
  - T: indices, timestamps and Git hashes;
  - Q: whether the probe token was present, whether the codeword was correct, and the `tool_use` count; not the reply text;
  - R: timings, notices and the terminal-state rule outcome; not screen contents;
  - X: exit codes and reasons. Container logs stay local, because they carry TUI output.
- Commit the timeline and inventory diffs.
- Screen captures and transcripts stay local. Any excerpt needs an owner decision.

**Cleanup:** as in Stage B, plus:
- the provider is gone;
- `allow_driver_config` is back to its prior value (GitOps commit recorded);
- the durable PVC is deleted by the owner after evidence review;
- the Console key is revoked (owner);
- the post-run inventory diff is against both this run's `pre` inventory and the Stage B run-3 baseline.

**Residual items carried from Stage B:**
- the exact Talos ptrace setting (record it in GitOps or the node configuration notes);
- the orphan Agent Sandbox webhook Secret;
- whether to keep the cluster-wide controller.

## 8. Owner approval checklist

None of these items is granted. Items 1–3 come before any Stage C approval.

- [ ] 1. Review and accept, amend or reject proposed FIND-088 to FIND-091 and the Stage B corrections (PR #43). Decide #42's disposition separately.
- [ ] 2. Confirm whether the Stage B approval covered B1 attempts 1–3 (deviation 1 in the Stage B README).
- [ ] 3. Record the exact Talos ptrace adjustment applied before run 3 (FIND-091b).
- [ ] 4. Approve Stage C as scoped here: C0–C4c and cleanup, one run, one attempt per step, Claude Code 2.1.323 only, and the classification in section 4.2.
- [ ] 5. Agent and model: Claude Code 2.1.323 with `claude-haiku-5-5`, reusing image `sha256:b70f90a6…4f18`, with no rebuild.
- [ ] 6. A new Console workspace, its spend cap (value set by the owner), one API key, and its revocation after the run (owner-performed).
- [ ] 7. Import one reviewed `claude-code` profile into the shared gateway, and create and delete one provider there. List existing providers, profiles and the credential backend first (names only).
- [ ] 8. Telemetry hosts (`statsig.anthropic.com`, `sentry.io`): drop them (recommended) or allow them.
- [ ] 9. Optional: a Cilium FQDN egress policy on supervisor pods (owner-authored).
- [ ] 10. `allow_driver_config = true` on the gateway for the run window, through GitOps, with revert recorded. Without it, C4b and C4c are dropped.
- [ ] 11. The owner creates the labelled durable PVC `exp008c-state` and decides its retention after the run.
- [ ] 12. The change freeze on both Argo apps, the OIDC login and logout, and whether to provide a namespaced kube credential instead of cluster-admin.
- [ ] 13. Evidence policy:
  - what may be committed from transcripts and screen captures (default: nothing beyond metrics and hashes);
  - whether the local C4a backup `tar` is kept or shredded after review;
  - the owner runs the provider-creation command (section 5.1 MUST-2).
- [ ] 14. Whether a later, separate experiment should test EXP-004-style scoped Git credentials delivered as an OpenShell provider. This is not part of Stage C.
- [ ] 15. If Stage C passes: whether to plan the Codex follow-up (section 6) under its own approval.

## 9. Open uncertainties

1. Whether Claude Code 2.1.323 accepts the placeholder key and, with `apiKeyHelper`, shows no approval prompt (H4).
2. Whether supervisor-side credential resolution works through a gateway outage with a provider attached (K6).
3. The PTY master fd's lifetime in the Kubernetes boundary runtime, and whether the agent sees any EIO or SIGHUP on detach (K2).
4. Whether init-container seeding is skipped when a durable PVC is mounted at a sub-path of `/sandbox`, and whether the sandbox UID can write it.
5. Whether OpenShell leaves a PVC it did not create intact when it deletes an `Error` sandbox (C4b).
6. Whether Claude Code's `--resume` of a session killed mid-tool-call loads cleanly at 2.1.323, and whether `CLAUDE_CODE_RESUME_INTERRUPTED_TURN` exists at that version (K11 docs post-date the pin).
7. Whether a forced redraw makes a replayed TUI coherent (K3).
8. How long a stale input owner persists after an abrupt client kill (C1) and after a gateway restart (C2).
9. Total spend for the task at Haiku pricing. The workspace cap is the control, and the estimate is the owner's to set.
10. Whether Claude Code 2.1.323 keeps the session id on `--resume`, or writes the resumed history under a new id (recorded as an attribute, not as pass or fail).
11. Whether the agent follows the one-step-per-tool-call instruction. Batching is detected and recorded (`batched`), but it would weaken the C1 and C2 work evidence.
