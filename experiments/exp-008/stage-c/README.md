# EXP-008 Stage C, C0–C3: harness and execution request (agent-generated; NOT approved; nothing run)

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../../docs/experiments/08-openshell-execution.md) · [Stage C proposal](../STAGE-C-PROPOSAL.md) · REQ-003, REQ-006, REQ-009, REQ-011 · ADR-0001 unchanged

**Status (2026-11-25).** This directory holds the prepared harness for Stage C steps C0–C3 and one consolidated execution request (section 8) for owner review.
- No cluster read, sandbox, provider, profile, gateway change, model call or API key was made or used in preparing it.
- Upstream facts come from reading OpenShell `v0.1.9` source (`ce58cf8`) and static `strings` of the Claude Code 2.1.323 binary (sha256 verified, never executed). They are labelled **S** (source/docs), **B** (binary strings) or **I** (inference). Nothing here is **O** (observed) until the run.
- C4a–C4c (native recovery after workload-pod loss) are **out of scope**: no durable PVC, no `allow_driver_config`.
- FIND-088 to FIND-091 are treated as accepted at their documented scopes, per the owner's Stage C instruction (2026-11-25). The Stage B record in the repository still says "proposed"; this PR does not edit it (D11).

## 1. Questions and pass rules (C0–C3)

| | Q1: process and work continuity | Q2: session reattachment |
|---|---|---|
| Fault windows | C1: the only client killed abruptly (SIGKILL of its whole process tree), then ≥ max(4×*M*, 120 s) with no client. C2: gateway scaled 0 → 90 s → back, no client attached | C3a after C1, C3b after C2 |
| Pass | **Both**: process keys **P** and workload keys **W** unchanged (`survived`), **and** `work=progressed` inside the window (section 5) | P unchanged, **and** the screen is coherent on replay, after a resize redraw or after Ctrl-L, **and** the probe is *delivered* into the same session (not just queued), **and** it is answered in that session (same session id, transcript prefix preserved) |
| Not a pass | A UI after reconnect; a `done` line from a step that was already running; batched steps | A replayed screen with input owned by a stale client; a queued-only probe; a new process |

C2's primary window is **gateway absent or not Ready** (`c2-gwdown`: scale-down → new gateway pod Ready). `c2-full` (until the sandbox reads Ready) is recorded too. Native resume is **not tested** and is recorded as such.

## 2. Discrepancies found during preparation (reported, not silently absorbed)

| # | Proposal or assumption | Finding | Effect on the plan |
|---|---|---|---|
| D1 | `step.sh` commits to a local Git repo; T key uses `git rev-parse` (proposal 3.3, 4.1) | The pinned image has **no git** (EXP-006 base adds tmux, openssh-server, tini, procps; the agent layer adds python3-minimal, ca-certificates). **O** from repo Containerfiles, not from the image | `step.sh` keeps a **hash-chained ledger** instead of commits (each line carries sha256 of the previous one). Sufficient for C0–C3; C4's repository checks would need git (rebuild) or the ledger. **Owner decision** |
| D2 | Main process runs as the image user (uid 1000, home `/tmp/home`) | The Kubernetes driver sets `runAsUser` from `sandbox_uid`, **default 10001**; HOME is the workdir `/sandbox`; cwd `/sandbox`; the argv after `--` is exec'd **directly, no shell** (S: `openshell-driver-kubernetes/src/config.rs:487`, `driver.rs:7498`; `openshell-sandbox/src/process.rs:190-340`; `openshell-supervisor/src/lib.rs:1146`) | Launcher is `/bin/sh -c …`; sets its own HOME/CLAUDE_CONFIG_DIR under `/sandbox/c`. **Risk:** uid 10001 has no passwd entry in the image; if Claude Code needs one, C0 stops (recorded) |
| D3 | "Import one reviewed `claude-code` profile" (item 7) | v0.1.9 ships **no** built-in profiles; `provider create --type claude-code` fails until one is imported (S: `docs/how-it-works/providers/profiles.mdx:301`) | Owner imports [`task/profile-claude-code-exp008c.yaml`](task/profile-claude-code-exp008c.yaml) (default workspace, not `--global`) and deletes it at cleanup. Shared gateway state is touched |
| D4 | Placeholder `openshell:resolve:env:…` | Revision-scoped: `openshell:resolve:env:v<rev>_ANTHROPIC_API_KEY` (S: `openshell-core/src/secrets.rs:1002`) | Checks match the prefix only; the value is never hard-coded or printed |
| D5 | Task files reach the sandbox | `sandbox create --upload` cannot be combined with a command (S: `openshell-cli/src/main.rs:1486`) | The task package (4 files from [`task/`](task/)) travels inside the create argv as base64; the bootstrap verifies its sha256 before extracting |
| D6 | `ANTHROPIC_API_KEY` = placeholder, plus `apiKeyHelper` echoing it (proposal 3.2) | With `--bare`, an exported `ANTHROPIC_API_KEY` **wins** over the helper and still triggers the blocking "Detected a custom API key … use this API key?" dialog in interactive mode (B) | Launcher moves the placeholder to `EXP008_ANTHROPIC_KEYREF`, unsets `ANTHROPIC_API_KEY`, and the settings' `apiKeyHelper` prints it (EXP-006 s3b's dialog-free path). The proxy substitutes by placeholder **value** in the `x-api-key` header (S) |
| D7 | "A request to an allowed host from a non-allowlisted binary must not be credentialed" (5.3 item 3) | Binary matching also admits **descendants** of a listed binary, and static substitution is **endpoint-scoped** (S: `docs/.../network-rules.mdx` "Binary Matching"; `profiles.mdx:255`). The agent's own Bash children can use the key via the proxy | The negative probe runs through `sandbox exec` (a mediated process that is **not** a claude descendant) and, separately, through `kubectl exec` (outside OpenShell mediation). TCP connects only: no HTTP, no credential use |
| D8 | — | A placeholder found in a request **body** is refused with 403 `credential_placeholder_in_request_body` (S: `openshell-supervisor-network/src/l7/relay.rs:760`) | Prompt forbids reading env; settings deny `env`/`printenv`/`cat`; no agent-readable file contains the placeholder prefix literally. If it still happens, the agent stalls: recorded, not repaired |
| D9 | Stale input owner after an abrupt client kill (open uncertainty 8) | Released on channel EOF, or at worst by the 60 s SSH peer deadline; a read-only client gains input on its next keystroke and prints `openshell: input enabled` (S: `ssh.rs:47-48,862,1011-1026`) | If the reattach shows the read-only notice, the single probe is typed only after 75 s from the previous client's end. Never Ctrl-C (it closes a non-owner) |
| D10 | Detached agent output | PTY is 80×24 until a client attaches (S: `process.rs:566`); ring 1 MiB, **whole ring replayed on every attach** (S) | Resize redraw, then Ctrl-L (Claude Code's documented full redraw that keeps input) only if still incoherent; recorded as `coherent-after-ctrl-l` (new value) |
| D11 | Repository references | The Stage C proposal cites Stage B revision 4 (`33291ef`) and `844580c`; neither is on `main` (reachable via PR #42/#43 refs). `STAGE-B-PROPOSAL.md` on `main` is the pre-revision text. Docs still say FIND-088–091 "proposed". `k8s/README.md:19` gives the CLI sha256 tail as `7c69`; it is `7e69` | Not edited here (Stage B record preserved). Listed for owner follow-up |
| D12 | Codeword in the first prompt (EXP-006) | Positional prompts are visible in `/proc/<pid>/cmdline` | The codeword is typed at the first attach in C0 (also the C0 input-path baseline); kept in a local 0600 file, never committed |
| D13 | `--tools Read,Edit,Bash` | The task needs only Bash | `--tools Bash`, `dontAsk`, allow only `Bash(./step.sh *)` (minimum surface) |
| D14 | Renderer unspecified | 2.1.323 may default to the alternate-screen renderer when feature flags are not fetched (S docs; B strings) | Not pinned (the default is what is tested); the mode is recorded from the raw stream (`rawmode`) |

## 3. Design (what runs)

- **Sandbox:** `exp008c-<RUN>`, created once by [`stagec.sh`](stagec.sh) `c0-create`, with image `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18` (Claude Code 2.1.323, sha256 `604d29a6…e348e` verified at build; no rebuild), `--provider exp008c-anthropic --detach --tty --restart-policy never --no-auto-providers`, the **default per-sandbox PVC** at `/sandbox`.
- **Launcher** ([`launcher.sh`](launcher.sh) → [`task/launch.sh`](task/launch.sh)): keeps OpenShell's environment (CA bundle variables, placeholder), adds only its own variables, writes `/sandbox/c/launch/identity` (pid, `/proc` start, boot id, random nonce, uid, key **form**), then `exec`s `claude --bare --settings … --strict-mcp-config --tools Bash --model claude-haiku-5-5 --effort medium --session-id <uuid> "<prompt>"` with the same PID. Telemetry, error reporting, autoupdate and non-essential traffic are disabled.
- **Task** ([`task/step.sh`](task/step.sh), [`task/prompt.txt`](task/prompt.txt)): 120 token-chained steps, 20 s each, one per Bash tool call. Only `sha256(next token)` is stored, so reading `.state/` cannot reveal it. Each log line records the invoking shell's PID, start time and command hash (batching detector) and the key **forms** seen by an agent descendant.
- **Client** (Herdr stand-in): `openshell sandbox connect` in a harness-owned local tmux server; raw output piped to a local file; screens captured with `capture-pane`.
- **Metrics** ([`metrics.py`](metrics.py)): derived numbers and classifications only; never prints transcript text, prompts, replies, tokens or commands.

## 4. Stage B harness limitations, fixed

| Stage B limitation (k8s/README.md) | Stage C harness |
|---|---|
| `pre` recorded but did not require Argo Synced/Healthy | `pre` stops unless both apps are Synced/Healthy |
| No container exit code/reason; rollback deleted pods first | Sampler captures state, `lastState` and logs of **any** pod of the sandbox (both roles) on termination, `Failed`/`Succeeded` or deletion, once per pod UID |
| `b1-t0` overwritten | Timestamps are write-once (`put1`) |
| Sampler launch defect (attempt 1) | `sampler-start` stops unless data appears within 8 s |
| Inventory had no PVs; generation diff not pre-declared | PVs in the namespace inventoried; sandbox PVC→PV recorded and checked gone; expected diffs (gateway generation, provider list) declared |
| Allowlist-only guard; ACK process HUP/TERM/KILL | Static allowlist test; C1 SIGKILLs the whole client tree (CLI → ssh → sh → ssh-proxy) and proves zero survivors twice |
| — (new) | Clock-skew measurement (workload vs workstation) with margin in every window; spend guard; wall-clock guard; supervisor-token-expiry guard before C2; provider list must not change; `kx` re-checks workload labels before every exec |

## 5. Pre-registered classification (proposal 4.2, with the changes marked †)

- **M** = median interval between the first attempts of steps 1–6 (C0). **Frozen** = no attempt and no transcript entry for > 3×*M*.
- **Work during a window**, all times on the workload clock with |skew| + its uncertainty + 1 s as margin:
  - `progressed`: ≥ 2 steps whose first `attempt` is inside the window, each the only `step.sh` of its own `tool_use`, whose `assistant` entry is inside the window **and before** that attempt†, and no two of them started by the same shell (ppid + start time)†.
  - `batched`: any counted step shares a `tool_use` or a shell. `stalled-then-recovered`: frozen inside, ≥ 2 qualifying steps within 3×*M* after. `stalled`: otherwise. `turn_ended_by_close`† flags an agent that ended its turn (stopped early) rather than froze.
- **Process:** `survived` · `survived-frozen(N s)` · `restarted` · `unavailable` · `inconclusive`. P = launcher record **and** live process agree on pid, start and nonce (nonce from the live environ, or `nonce_source=launch-record` if unreadable†); W = workload pod UID, container ID, restart count.
- **Reattachment:** `same-process-writer` (probe **delivered**: a `user` entry or a `queued_command` attachment†) · `same-process-read-only` · `replacement` · `lagged` · `failed`. `probe_queued_only`† is recorded separately and is **not** writer evidence.
- **Terminal state:** `coherent-on-replay` · `coherent-after-redraw` · `coherent-after-ctrl-l`† · `garbled`. Rule†: ≥ 2 rule lines of ≥ 20 `─` (the 2.1.323 input box, s3b `pane-k02-ready.txt`) and no literal escape fragments.
- **Conversation continuity:** one session id; the C0 transcript prefix hash still matches; the reply contains the probe token; codeword and last-step mention recorded.
- **Native resume:** `not-tested`.

## 6. Offline verification (done)

| Check | Result |
|---|---|
| `tests/test_stagec.py` (16): step chain, refusals, concurrency, ledger tamper, window rules incl. in-flight completion, batching, shared shell, freeze, skew margin, queued vs delivered probe, usage dedupe, screen rule, no text in output | pass |
| `tests/launch-test.sh` (19): deterministic package, sha256 mismatch refused, no placeholder → agent not started, placeholder moved and `ANTHROPIC_API_KEY` unset, CA variable kept, PID preserved across exec, argv, first-run seed, placeholder never on disk, state reuse refused, argv size 27 KB | pass |
| `tests/allowlist-test.sh`: raw kubectl only in wrappers, no delete/patch/apply, CLI only via `O`/`client_start`, no provider/profile/credential mutation, `send-keys`/`kill` confined, every mutating step once-only (cleanup: own marker), `kw` allows scale only | pass |
| `tests/wrapper-test.sh` (22): the real `O()`, `client_scan()` and `type_line()` run against a stub CLI and fake processes: M8's exact argv accepted, 13 near-miss argvs refused; client scan sees all four client-chain processes and ignores kubectl, harness reads and unrelated openshell processes; typed text never logged; Ctrl-D/Ctrl-P refused | pass |
| Independent pre-execution review (2026-11-25, two reviewers): 3 blockers found and fixed (M8 argv arity; client scan matching the harness's own kubectl; reattach arithmetic abort), plus cleanup-after-STOP, rollback trap on signals, typed-text logging, egress gate scope, gate "in flight", stale step lock, identity pins, redaction gaps | fixed; regression tests added |
| `export.sh --scan`: key/placeholder/JWT/private-IP/transcript-shape/site-literal detection on synthetic files | pass |

Run: `uv run --no-project python -I -m unittest discover -s experiments/exp-008/stage-c/tests` and `bash experiments/exp-008/stage-c/tests/{launch,allowlist,wrapper}-test.sh`. The unit suite is now 18 tests (stale-lock break, leading-zero refusal added).

## 7. Spend estimate (I)

Claude Haiku 5.5 list price: $0.10 / MTok input, $0.50 / MTok output (prompts ≤ 100K); cache write/read taken as 1.25× / 0.1× (inference). About 125 requests (120 steps + probes); context grows to ~60K tokens, mostly cache reads.
- Expected: ≈ $0.05–0.15. Worst case with no caching: ≈ $0.60–1.00.
- Controls: the Console workspace **hard cap set by the owner (recommended $5)**; the harness's transcript-usage estimate stops the run at 80 % of `BUDGET_USD` (default $2). The Console figure is the authority; a zero Console figure is not proof of no spend (EXP-006 s3b).

## 8. Execution request (one package; nothing is authorized until the owner approves it)

**8.1 Commands and resources.** All cluster access uses the kube context in `~/.cache/hxc/site.env` (not committed) and stops if `kube-system` UID, gateway StatefulSet UID or gateway data PVC UID differ from `pre`.
- *Read:* namespaces `openshell` and `agent-sandbox-system` (objects, pods, logs, events), the Sandbox CRD and CRs, PVs bound in `openshell`, the two Argo `Application`s, GitOps `main` SHA via `gh api`, `sandbox get/list`, `provider list --names`.
- *Identity pins:* `pre` also compares the `kube-system`, gateway StatefulSet and gateway data PVC UIDs with values pinned in `site.env` from Stage B run 3's recorded references, so a wrong context cannot become the baseline.
- *Changed by the harness (complete list, [`stagec.sh`](stagec.sh) header):* M1 `sandbox create exp008c-<RUN>` (which makes one Sandbox CR, a workload pod, a supervisor pod, a per-sandbox PVC/PV, Secrets, a Service and NetworkPolicies, all labelled with the sandbox id); M2 `sandbox connect` (local tmux); M3 one fixed-form line typed per attach (+ M3b Ctrl-L if needed); M4 SIGKILL of the harness's own client processes; M4b Ctrl-P Ctrl-Q; M5 `kubectl -n openshell scale statefulset/openshell --replicas=0` then back to the `pre` value (1); M6 `sandbox delete exp008c-<RUN>`; M7 `gateway logout exp008c`; M8 one `sandbox exec … python3` TCP probe. `kubectl exec` only into this sandbox's workload pod, only scripts X1–X7.
- *Changed by the owner:* profile `claude-code-exp008c` and provider `exp008c-anthropic` on the shared gateway (created, then deleted); `~/.cache/hxc` (local).

**8.2 Agent:** image `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18`, Claude Code **2.1.323** (sha256 `604d29a6869409106b6a1110bdadcc8b72e8654a5a865d23258f938a696e348e`), model **`claude-haiku-5-5`**, effort `medium`, Claude Code only.

**8.3 Spend:** new dedicated Console workspace, owner-set hard cap (recommended **$5**), estimated maximum ≈ **$1**; harness stop at 80 % of `BUDGET_USD=2`.

**8.4 OpenShell profile and provider:** [`task/profile-claude-code-exp008c.yaml`](task/profile-claude-code-exp008c.yaml): endpoint `api.anthropic.com:443` only (statsig/sentry dropped), binary `/usr/local/bin/claude` only, credential `ANTHROPIC_API_KEY` in `x-api-key`. Provider `exp008c-anthropic` of that type. Optional owner-authored Cilium FQDN policy on supervisor pods: not required, not included.

**8.5 Owner-operated steps** ([`owner/owner-provider.sh`](owner/owner-provider.sh), owner's own terminal only):
1. Console: create the workspace, set the cap, create one API key.
2. `owner-provider.sh setup` (creates `~/.cache/hxc`, copies the verified CLI, writes `site.env` and `login-c.sh` from the Stage B files), then `owner-provider.sh login` (OIDC, isolated registration `exp008c`).
3. `owner-provider.sh list` (names only, recorded), `profile-import`, `create` (hidden prompt; the key is exported only inside a cleared subshell and read by the CLI from its environment; never in argv, a file or history), `list` again.
4. After cleanup: `owner-provider.sh delete` (provider, then profile), `list`; revoke the key in the Console; record the Console spend.

**8.6 Change freeze:** the owner holds merges to the GitOps repository and confirms no open Renovate PRs for the OpenShell and Agent Sandbox apps for the run window. The harness stops at every step boundary if either app's Argo state or GitOps `main` moved, and refuses to run between 00:30 and 07:00 local time (Renovate automerge at 01:00). The run needs ≈ 60–75 min, so it should start before 23:00 local.

**8.7 Allowlist, safeguards, cleanup:** M1–M8 and X1–X7 above; once-only steps; no retries; stop on any guard. Guards: cluster identity, Argo/GitOps freeze, competing Sandbox CRs, provider list unchanged, CLI registration present, credential-like variables in the harness environment, wall clock 90 min from create, spend 80 %, gateway Ready ≤ 240 s after scale-down, sandbox Ready ≤ 300 s after gateway Ready, supervisor-token expiry ≥ 15 min away before C2, a real-key-shaped value anywhere in the workload (env or `/sandbox`), placeholder absent, launcher/live identity disagreement. Cleanup is the stop path: it runs once **even after a STOP**, restores gateway replicas first if they differ from `pre`, and resolves the sandbox id if `c0-create` failed. It kills the harness's tmux server (survivors recorded), takes a final snapshot, runs `sandbox delete`, and waits until no pod/PVC/Secret/Service/NetworkPolicy/ConfigMap/ServiceAccount/Role/RoleBinding carrying the sandbox's labels or name, no Sandbox CR, no PV of its PVCs (recorded or by claim) and no Cilium policy naming it remains. `post` diffs the inventory against `pre` and writes `restoration=matches-pre` or `restoration=NOT-CLEAN`; then `logout` and the owner steps in 8.5.4.

**8.8 Evidence retention:** commit only what [`export.sh`](export.sh) copies (timeline, per-step results, identity summaries with node names replaced, metrics JSON, terminal-rule JSON, filtered samples, inventory diffs) after its scan passes. Transcripts, screen captures, PTY logs, container/gateway logs, task-log copies, codeword and probe tokens stay in `~/.cache/hxc/run/<RUN>/raw` (0700) until owner review; the owner decides retention or shredding. Any excerpt needs an owner decision. `export.sh` deletes its copy if the scan fails. The owner adds cluster, node and gateway host names to `~/.cache/hxc/redact.txt`; the scan refuses them and site.env values.

**8.9 Sequence and stop conditions (one run, one attempt per step):**

| Step | Command | Proceeds when | Stops when |
|---|---|---|---|
| owner | 8.5.1–8.5.3 | provider listed | — |
| pre | `stagec.sh <RUN> pre` | Argo Synced/Healthy, digests match Stage B, replicas 1, no Sandbox CRs, provider present | any mismatch |
| sampler | `stagec.sh <RUN> sampler-start` | data within 8 s | no data |
| C0 | `c0-create`, `c0-baseline` | Ready ≤ 300 s; launcher key form `placeholder`; live env `keyref=placeholder`, `ANTHROPIC_API_KEY` absent; no real-key shape in env/files; disallowed host and python→api.anthropic.com both **blocked** under `sandbox exec`; transcript with assistant entries ≤ 180 s (H4); first attach not read-only; codeword acknowledged; first attempts of steps 1–6 → *M*. The kubectl-exec probe (outside OpenShell mediation) is recorded, not gated | any check fails |
| C1 | `c1` | gate: ≥ 3 and ≤ 112 done; then, immediately before the kill, a step in flight (step lock held, attempts > done); client tree killed, zero survivors; hold ≥ max(4*M*, 120 s); P/W read | survivor; unreadable identity → `unavailable` |
| C3a | `c1-reattach` | one probe; Q/R recorded; clean detach | identity unreadable |
| C2 | `c2` | gate as C1 (in-flight check just before scale-down); token expiry ≥ 15 min; scale 0, 90 s, scale back (rollback trap also on INT/TERM/HUP, then exit); gateway Ready ≤ 240 s; sandbox Ready ≤ 300 s | outage over ceiling; `unavailable` |
| C3b | `c2-reattach` | as C3a | as C3a |
| cleanup | `cleanup`, `post`, `sampler-stop`, `logout`; owner 8.5.4 | residue none, replicas restored | residue (owner decides; no manual finalizer edits) |

Cleanup is itself single-attempt: if it stops on residue or a guard, the remaining objects are listed in `obs/cleanup-residue.txt` and the owner decides how to remove them (no finalizer edits by the agent). A result of `restarted`, `stalled` or `garbled` is a recorded result, not a stop, unless the process is `unavailable`. Nothing is retried. Checkpoint reports follow C0, C1, C2, C3 and cleanup.

## 9. Deferred security requirement: Kata Containers and Talos ptrace restoration (not part of Stage C)

The cluster's Talos GitOps patch `talos/<cluster>/patches/global/yama-ptrace.yaml` sets `kernel.yama.ptrace_scope: "1"` node-wide so that OpenShell v0.1.9's mandatory task-memory probe works. Source review suggests why: the supervisor side reads the notifying task's memory with `process_vm_readv` (fallback `/proc/<tid>/mem`) and self-tests parent→child access (`openshell-sandbox/src/linux/task_memory.rs:48-107`, S; the link to Yama scope is I). **Stage C does not modify or revert it.**

Intended direction (owner, proposal only): OpenShell sandboxes behind Kata Containers, and a return to the Talos KSPP default `ptrace_scope=2`. A future, separately approved experiment must establish:
1. whether OpenShell's task-memory operations work inside the Kata guest;
2. which ptrace restrictions apply in the guest versus on the Talos host;
3. whether sandboxes operate with host `kernel.yama.ptrace_scope=2`;
4. whether the Talos patch can be removed without affecting other workloads (inventory of ptrace-dependent workloads first);
5. whether the resulting isolation meets REQ-011;
6. the migration and rollback of the node-wide relaxation: an ordered plan (Kata RuntimeClass validated → OpenShell sandboxes moved → patch reverted via GitOps → verification), with the patch restore as the rollback.

No Kata deployment, RuntimeClass change or Talos machine-configuration change is proposed here.

## 10. Not done and open

- Nothing in section 8 has run. Owner approval items from proposal section 8 that remain relevant: 4–9, 12, 13 (items 10–11 and the durable PVC are C4 only).
- Open uncertainties to be observed in C0–C3: Bun's acceptance of the proxy CA via `NODE_EXTRA_CA_CERTS` (I); uid 10001 without a passwd entry (D2); Haiku stopping early; Claude Code's retry budget across a ~105 s gateway outage (the proxy, not the gateway, is on the model path, S); whether `/proc/<pid>/environ` is readable from `kubectl exec`; renderer mode.
- Every finding from a run will be **proposed**; none is accepted by the agent.
