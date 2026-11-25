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
| `tests/test_stagec.py` (28): step chain, refusals, concurrency, stale lock, leading zeros, ledger tamper, window rules incl. in-flight completion, batching, shared shell, freeze, skew margin, queued vs delivered probe, usage dedupe, screen rule, no text in output; **spend (10, correction A):** base vs long-context card at exactly 100,000 / 100,001 prompt tokens, cache writes and reads counted toward the threshold, per-request tier, unknown cache TTL priced at the 1-hour rate, per-field max over repeated entries, US-geo multiplier, synthetic messages and a partial final line tolerated, and `reliable=false` for missing usage, unknown model, non-integer field, corrupt earlier line, missing message id, missing output count and unpriced server-tool use | pass |
| `tests/launch-test.sh` (19): deterministic package, sha256 mismatch refused, no placeholder → agent not started, placeholder moved and `ANTHROPIC_API_KEY` unset, CA variable kept, PID preserved across exec, argv, first-run seed, placeholder never on disk, state reuse refused, argv size 27 KB | pass |
| `tests/allowlist-test.sh`: raw kubectl only in wrappers, no delete/patch/apply, CLI only via `O`/`client_start`, no provider/profile/credential mutation, `send-keys`/`kill` confined, every mutating step once-only (cleanup: own marker), `kw` allows scale only | pass |
| `tests/wrapper-test.sh` (47): the real `O()`, `client_scan()`, `type_line()`, `kw()` and `spend_check()` run against stubs and fake processes: M8's exact argv accepted, 16 near-miss argvs refused (incl. `profile list -o json`, `profile delete`, `profile export`); `profile list` accepted; client scan sees all four client-chain processes and ignores kubectl, harness reads and unrelated openshell processes; typed text never logged; Ctrl-D/Ctrl-P refused; `kw` records generation before/after each scale and `restore-check.sh` explains exactly that chain; **spend_check** stops when the transcript is unlocated after `c0-create` (except inside `c0-baseline`), when the copy fails, when usage is missing, when there are zero assistant messages, when the long-context card takes the estimate over 80 %, and when the estimate decreases; `providers()`/`profiles()` turn a CLI failure into an `ERROR` marker (never an empty-looking list), and the profile table is normalised (header dropped, "No profiles found." → empty) | pass |
| `tests/scan-test.sh` (26, correction B): ten **synthetic** secret-shaped values assembled at run time (key shape, placeholder, JWT, private IPv4, private-key header, transcript JSON, site literal, redact-list name, codeword, probe token): the scan fails, reports `category / lines / file` for each, and its output contains none of the values, their random fragments or any line text; an unreadable path fails closed; a file with NUL bytes is scanned, and a path with spaces is reported whole; a full export with a secret refuses, removes DEST and names only the file; a clean export completes, maps the node name and redacts the pod IP; an existing DEST is neither overwritten nor removed | pass |
| `tests/restore-test.sh` (31, correction C): generation explained only by an unbroken chain of recorded scale operations (+1 per successful op, 0 per failed op); changes before, between or after recorded ops, a +2 step, a failed op that changed the generation, and unreadable values are `UNEXPLAINED`; provider/profile lists `removed`, `present-owner-delete-pending`, `UNEXPECTED` (added, removed, swapped) or `UNVERIFIABLE` (name absent from `pre`, a similar name only, list missing, CLI error text, an `ERROR` marker in `pre` or `post`); a genuinely empty list after deletion is `removed`; verdict `matches-pre` only with no other diff, an explained generation and both names `removed`; `INCOMPLETE` when only the owner deletion is pending; `NOT-CLEAN` otherwise | pass |
| Independent pre-execution review (2026-11-25, two reviewers): 3 blockers found and fixed (M8 argv arity; client scan matching the harness's own kubectl; reattach arithmetic abort), plus cleanup-after-STOP, rollback trap on signals, typed-text logging, egress gate scope, gate "in flight", stale step lock, identity pins, redaction gaps | fixed; regression tests added |
| Found while writing the scan test: `export.sh` exited silently under `pipefail` during redaction when a `grep` matched nothing (e.g. no node names), leaving an **unscanned** copy in DEST. Fixed: every redaction `grep` is guarded, and an EXIT trap removes DEST unless a scan has passed | fixed; covered by `scan-test.sh` |

Run: `uv run --no-project python -I -m unittest discover -s experiments/exp-008/stage-c/tests` and `bash experiments/exp-008/stage-c/tests/{launch,allowlist,wrapper,scan,restore}-test.sh`. Last run 2026-11-25 after corrections A–C and the review fixes: 28 unit tests OK; 15 + 19 + 47 + 26 + 31 shell checks (allowlist, launch, wrapper, scan, restore), 0 failures.

Review of corrections A–C (2026-11-25): an independent re-run (Haiku) reproduced the counts and found no secret pattern in the scan test's output. An independent review (Sonnet) found no blockers and these should-fix items, all fixed with tests: the scan skipped files with NUL bytes (`grep -I` → `-a`); a failed `provider list` printed nothing and could look like a successful removal (now an `ERROR` marker, `UNVERIFIABLE`); `post` was single-attempt, leaving `INCOMPLETE` a dead end (now read-only and re-runnable, each run kept as `inv/post-N`); the profile table was not normalised (verified against the 0.1.9 source: columns NAME TYPE CATEGORY SOURCE SCOPE, no timestamps; empty catalog prints "No profiles found."). Nits fixed: generation reads moved outside C2's timed section (windows start at the scale's issue time); the decrease check reads fixed-point values; `obs/scale-ops.txt` and the restore checks are exported; scan records are tab-separated.

## 7. Spend estimate and enforcement (correction A)

Rate card (Claude Haiku 5.5, USD per MTok, read from the Anthropic pricing page 2026-11-25, S): two cards chosen **per request** by prompt length, where the prompt counts input tokens plus cache writes plus cache reads.

| Card | Input | Cache write 5 min | Cache write 1 h | Cache read | Output |
|---|---|---|---|---|---|
| prompt ≤ 100,000 tokens | 0.10 | 0.125 | 0.20 | 0.01 | 0.50 |
| prompt > 100,000 tokens | 0.50 | 0.625 | 1.00 | 0.05 | 2.50 |

US-only `inference_geo` adds 1.1× (not expected; applied if the transcript reports it). Where the transcript does not split cache writes by TTL, every write is priced at the 1-hour rate.

- **Expected:** about 125 requests (120 steps plus probes); context grows to about 60K tokens, mostly cache reads, so all requests should stay on the base card: ≈ $0.05–0.15. Worst case with no caching on the base card: ≈ $0.60–1.00. If context passed 100K, each later request would cost about 5× more; `max_prompt_tokens` and `long_context_messages` are recorded at every check.
- **The harness figure is an estimate.** `metrics.py usage` prices what the transcript records. Requests it never records (aborted streams, client retries, side requests) and any second session file (only the one transcript located in C0 is read) are invisible, so it can undercount. **The Console workspace cap ($5, owner-set) is the authoritative control**; the owner records the Console figure after revocation. A zero Console figure is not proof of no spend (EXP-006 s3b).
- **Enforcement (`spend_check`, at every step boundary and once at the end of `c0-baseline`):** STOP at 80 % of `BUDGET_USD=2` (≈ $1.60). Once `c0-create` has run (model activity begun), STOP if the transcript is not located (allowed only inside `c0-baseline`, which must locate it within 180 s), if the copy fails, if `metrics.py` fails, if the result is not `reliable` (missing or non-integer usage, missing message id, unknown model, corrupt earlier line, unpriced server-tool use) or has zero assistant messages, or if the estimate decreases between checks. Every check is appended to `obs/spend.txt` with the label "transcript estimate; Console cap is authoritative".

## 8. Execution request (one package; nothing is authorized until the owner approves it)

**8.1 Commands and resources.** All cluster access uses the kube context in `~/.cache/hxc/site.env` (not committed) and stops if `kube-system` UID, gateway StatefulSet UID or gateway data PVC UID differ from `pre`.
- *Read:* namespaces `openshell` and `agent-sandbox-system` (objects, pods, logs, events), the Sandbox CRD and CRs, PVs bound in `openshell`, the two Argo `Application`s, GitOps `main` SHA via `gh api`, `sandbox get/list`, `provider list --names`, `profile list` (inventory only), the gateway StatefulSet generation before and after each M5 operation.
- *Identity pins:* `pre` also compares the `kube-system`, gateway StatefulSet and gateway data PVC UIDs with values pinned in `site.env` from Stage B run 3's recorded references, so a wrong context cannot become the baseline.
- *Changed by the harness (complete list, [`stagec.sh`](stagec.sh) header):* M1 `sandbox create exp008c-<RUN>` (which makes one Sandbox CR, a workload pod, a supervisor pod, a per-sandbox PVC/PV, Secrets, a Service and NetworkPolicies, all labelled with the sandbox id); M2 `sandbox connect` (local tmux); M3 one fixed-form line typed per attach (+ M3b Ctrl-L if needed); M4 SIGKILL of the harness's own client processes; M4b Ctrl-P Ctrl-Q; M5 `kubectl -n openshell scale statefulset/openshell --replicas=0` then back to the `pre` value (1); M6 `sandbox delete exp008c-<RUN>`; M7 `gateway logout exp008c`; M8 one `sandbox exec … python3` TCP probe. `kubectl exec` only into this sandbox's workload pod, only scripts X1–X7.
- *Changed by the owner:* profile `claude-code-exp008c` and provider `exp008c-anthropic` on the shared gateway (created, then deleted); `~/.cache/hxc` (local).

**8.2 Agent:** image `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18`, Claude Code **2.1.323** (sha256 `604d29a6869409106b6a1110bdadcc8b72e8654a5a865d23258f938a696e348e`), model **`claude-haiku-5-5`**, effort `medium`, Claude Code only.

**8.3 Spend:** new dedicated Console workspace, owner-set hard cap **$5** (authoritative), estimated maximum ≈ **$1**; harness stop at 80 % of `BUDGET_USD=2` on the two-card estimate, and on any unreliable or unobtainable usage after model activity begins (section 7).

**8.4 OpenShell profile and provider:** [`task/profile-claude-code-exp008c.yaml`](task/profile-claude-code-exp008c.yaml): endpoint `api.anthropic.com:443` only (statsig/sentry dropped), binary `/usr/local/bin/claude` only, credential `ANTHROPIC_API_KEY` in `x-api-key`. Provider `exp008c-anthropic` of that type. Optional owner-authored Cilium FQDN policy on supervisor pods: not required, not included.

**8.5 Owner-operated steps** ([`owner/owner-provider.sh`](owner/owner-provider.sh), owner's own terminal only):
1. Console: create the workspace, set the cap, create one API key.
2. `owner-provider.sh setup` (creates `~/.cache/hxc`, copies the verified CLI, writes `site.env` and `login-c.sh` from the Stage B files), then `owner-provider.sh login` (OIDC, isolated registration `exp008c`).
3. `owner-provider.sh list` (names only, recorded), `profile-import`, `create` (hidden prompt; the key is exported only inside a cleared subshell and read by the CLI from its environment; never in argv, a file or history), `list` again.
4. **After `cleanup` and before `post`:** `owner-provider.sh delete` (provider, then profile) and `list`. `post` then verifies the removal explicitly (section 8.7). After `logout`: revoke the key in the Console and record the Console spend.

**8.6 Change freeze:** the owner holds merges to the GitOps repository and confirms no open Renovate PRs for the OpenShell and Agent Sandbox apps for the run window. The harness stops at every step boundary if either app's Argo state or GitOps `main` moved, and refuses to run between 00:30 and 07:00 local time (Renovate automerge at 01:00). The run needs ≈ 60–75 min, so it should start before 23:00 local.

**8.7 Allowlist, safeguards, cleanup:** M1–M8 and X1–X7 above; once-only steps; no retries; stop on any guard. Guards: cluster identity, Argo/GitOps freeze, competing Sandbox CRs, provider list unchanged, CLI registration present, credential-like variables in the harness environment, wall clock 90 min from create, spend 80 %, gateway Ready ≤ 240 s after scale-down, sandbox Ready ≤ 300 s after gateway Ready, supervisor-token expiry ≥ 15 min away before C2, a real-key-shaped value anywhere in the workload (env or `/sandbox`), placeholder absent, launcher/live identity disagreement. Cleanup is the stop path: it runs once **even after a STOP**, restores gateway replicas first if they differ from `pre`, and resolves the sandbox id if `c0-create` failed. It kills the harness's tmux server (survivors recorded), takes a final snapshot, runs `sandbox delete`, and waits until no pod/PVC/Secret/Service/NetworkPolicy/ConfigMap/ServiceAccount/Role/RoleBinding carrying the sandbox's labels or name, no Sandbox CR, no PV of its PVCs (recorded or by claim) and no Cilium policy naming it remains. `post` diffs the inventory against `pre`. Only three files may differ, and each is validated explicitly by [`restore-check.sh`](restore-check.sh) (correction C), never accepted by name: the gateway StatefulSet generation must be explained by an unbroken chain of the M5 operations the harness recorded in `obs/scale-ops.txt` (generation before and after each scale; +1 per successful operation, 0 per failed one); the provider list and the profile list (read with `profile list`, read-only) must equal `pre` minus exactly `exp008c-anthropic` and `claude-code-exp008c`. `post` writes `restoration=matches-pre`, `restoration=INCOMPLETE pending-owner-delete=…` (if the owner deletion has not happened) or `restoration=NOT-CLEAN <reasons>`, with the individual results in `inv/restore-checks-N.txt`. A failed list command is recorded as an `ERROR` marker and gives `UNVERIFIABLE`, never "removed". `post` is read-only and may be re-run (for example after a late owner deletion, but before `logout`); every run is kept as `inv/post-N` and `inv/restoration.txt` is the latest. Then `sampler-stop` and `logout`.

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
| cleanup | `cleanup`; owner 8.5.4 (provider and profile delete); `post`; `sampler-stop`; `logout`; owner revokes the key | residue none, replicas restored; `restoration=matches-pre` | residue (owner decides; no manual finalizer edits); `NOT-CLEAN` or `INCOMPLETE` is reported as such |

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

## 10. Owner decisions (2026-11-25) and process record

Owner review of draft PR #45, recorded as stated by the owner (the agent has not changed their status):
- **Approved for C0–C3, conditional** on corrections A–C (done above, section 6) and on owner confirmation that the Console workspace, profile and provider, OIDC login and GitOps freeze are complete. Execution has **not** started.
- D1: the hash-chained ledger replaces Git commits for C0–C3; no image rebuild; Git persistence stays a C4 question.
- Agent: the pinned Claude Code 2.1.323 image, `claude-haiku-5-5`, effort medium. Tools: Bash only, with the narrow task allowlist. Renderer: default, observed and recorded.
- Spend: dedicated workspace, $5 monthly cap, `BUDGET_USD=2`.
- Environment: the existing OpenShell 0.1.9 and Agent Sandbox 1.0.12 installation.
- If C0 fails because the existing image lacks a dependency (including a passwd entry for uid 10001), the failure is recorded and the run stops; no image change without further approval.
- Not authorized: C4, a durable PVC, `allow_driver_config`, Kata, RuntimeClass changes, Talos ptrace changes.
- REQ-013 kept as a Future requirement (documentation only).
- Sequence note (agent): the owner's provider and profile deletion sits between `cleanup` and `post`, so that `post` can verify it. The harness's own step order is unchanged.

**Agent-policy deviation (recorded at the owner's request).** During preparation on 2026-11-25 the agent ran one plain `git fetch origin`. The origin remote is SSH, so the command reached the owner's SSH agent, contrary to the [Agent Git policy](../../../AGENTS.md#agent-git-policy). The hardware-backed agent refused the operation: nothing was signed, authenticated or fetched over SSH. Every later Git network operation used HTTPS with `SSH_AUTH_SOCK` unset and the `gh` credential helper, with an explicit `https://github.com/jlaska/herdrnetes.git` URL and refspec, and future agent Git operations will use only that workflow. Commits stay unsigned (`-c commit.gpgsign=false`), only on `agent/*` branches; the owner squash-merges.

## 11. Not done and open

- Nothing in section 8 has run (corrections A–C are offline changes only). Owner approval items from proposal section 8 that remain relevant: 4–9, 12, 13 (items 10–11 and the durable PVC are C4 only).
- Open uncertainties to be observed in C0–C3: Bun's acceptance of the proxy CA via `NODE_EXTRA_CA_CERTS` (I); uid 10001 without a passwd entry (D2); Haiku stopping early; Claude Code's retry budget across a ~105 s gateway outage (the proxy, not the gateway, is on the model path, S); whether `/proc/<pid>/environ` is readable from `kubectl exec`; renderer mode.
- Every finding from a run will be **proposed**; none is accepted by the agent.
