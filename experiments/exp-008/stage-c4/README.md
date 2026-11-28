# EXP-008 Stage C4 Phase 1: harness and offline verification (agent-generated; offline only; no run authorized)

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · design: [STAGE-C4-PROPOSAL.md at `f19de00`](https://github.com/jlaska/herdrnetes/blob/f19de00c9f9ae6c8722e2000ec4111911e642fee/experiments/exp-008/STAGE-C4-PROPOSAL.md) (draft PR #48) · C0–C3: [`../stage-c/`](../stage-c/README.md), run [`1126-1017`](../stage-c/results/1126-1017.md) · REQ-003, REQ-006, REQ-009, REQ-011 · ADR-0001 unchanged

**Status (2026-11-26).** The owner reviewed draft PR #48 and approved **Phase 1 implementation and offline testing only**. On review of this PR at `eca1d50`, the owner approved it with targeted corrections and decided D-1 and the items in section 12. The decisions are recorded in the proposal's "Owner decisions" section (PR #48), and the corrections are below.
- This directory holds that implementation and its offline tests.
- Nothing here has touched a cluster. No sandbox, provider, profile, PVC, gateway setting or GitOps commit was created or changed, and no API key or model was used.
- **No C4 run is authorized.** Section 12 is the readiness checklist for a later, separate owner authorization.
- **Corrective packaging PR (2026-11-27, offline only).** The one authorized run, `1127-1814` (record in PR #50), stopped at `sandbox create`. OpenShell v0.1.9 refused the 40,960-byte inline package element (`spec.command[3] exceeds 32768 byte limit`), so no C4 behaviour was tested. The owner approved one corrective change:
  - **A.** A gzip-compressed package transport with a local byte budget (section 4, item 18).
  - **B.** A stub CLI that enforces the limit.
  - **C.** A cleanup that deletes only a sandbox it has discovered (item 19).

  Nothing in C4a, C4b, C4c, the ledger, the probe, the tail rule, the classifiers, the credential flow or C0–C3 changed. The corrected harness has not run against a cluster.
- FIND-095 to FIND-097 stay **proposed**. A clarification for the owner's review is in [`../stage-c/results/1126-1017-ADDENDUM.md`](../stage-c/results/1126-1017-ADDENDUM.md); the owner recommends accepting them at those narrowed scopes, and the decision is recorded on issue #39 by the owner.
- REQ-009, REQ-011 and REQ-013 stay Future.

Labels: **S** read in upstream source at the pin (OpenShell `v0.1.9` `ce58cf8`, Agent Sandbox `v1.0.12`), **B** static review of the pinned Claude Code 2.1.323 binary, **O-offline** observed in this directory's offline tests, **I** inference, **U** unknown until a live run.

## 1. Scope

Phase 1 only, as approved:
- one sandbox with its default per-sandbox PVC;
- C4a: `kubectl delete pod <workload> --grace-period=1 --wait=false`, without `--force`;
- C4b-N: `sandbox stop`, then `sandbox start`, on the same sandbox;
- C4c: a new Claude Code process with plain `--resume`;
- the hash-chained ledger, with no Git;
- the pinned image `herdrnetes-exec@sha256:b70f90a6…` (Claude Code 2.1.323), `claude-haiku-5-5` at medium effort, Bash-only permissions;
- `STEP_SLEEP=45`;
- the §5.6 control and probe lines;
- at most two typed inputs after resume, and the fixed line "Continue the task.";
- the §10 spend and time limits;
- a shared real-model-response predicate.

**Not implemented:** Phase 2 (external PVC, driver config, a second sandbox), `CLAUDE_CODE_RESUME_INTERRUPTED_TURN`, `--session-id` with `--resume`, a positional prompt on resume, a C0–C3 repeat, and any gateway, GitOps, PVC, label, credential or image change.

## 2. Layout and relation to C0–C3

| File | Role | Relation to `../stage-c/` |
|---|---|---|
| [`stagec4.sh`](stagec4.sh) | The C4 harness: `pre`, `sampler-start`, `c0-create`, `c0-baseline`, `c4a`, `c4b`, `c4c`, `cleanup`, `post`, `sampler-stop`, `logout` | Derived from `stagec.sh`. C0 is reused, with the C4 package, the real-model H4 gate and the control line. C1–C3, gateway scaling and the rollback trap are removed |
| [`launcher4.sh`](launcher4.sh) | Package and `sandbox create` arguments | Same bootstrap, byte-identical (tested). The package carries the C4 `launch.sh` and `step.sh` plus the C0–C3 `prompt.txt` and `settings.json`, unchanged |
| [`task/launch.sh`](task/launch.sh) | State-aware launcher (Fresh / Resume / Refuse) | The C0–C3 launcher plus the resume path |
| [`task/step.sh`](task/step.sh) | Token-chained task step | The C0–C3 `step.sh` plus three changes: a 45 s default sleep recorded per attempt; boot-aware stale-lock rules; and an interrupted step (INT/TERM/HUP) exits 143 without writing `done` (section 4, item 11) |
| [`metrics4.py`](metrics4.py) | Real-model predicate, strict probe, C4b comparator, C4c decision procedure | Loads `../stage-c/metrics.py` by path for the reused functions |
| `tests/` | Offline suite (section 8) | Also runs the unchanged C0–C3 suite |

**The C0–C3 harness is byte-identical.** All 21 files match the sha256 list in the `1126-1017` record (`tests/c0c3-unchanged-test.sh`). The C4 mutations exist only in `stagec4.sh`, so no C0–C3 command can perform one (`tests/allowlist4-test.sh`, check 11). Reused unchanged by path: `../stage-c/metrics.py`, `restore-check.sh`, `export.sh`, `owner/owner-provider.sh` and the provider profile.

## 3. Mutation allowlist and guards

Every mutation goes through one wrapper. It is bound to its step and refused anywhere else. All of this is tested by `allowlist4-test.sh` (static, with 10 negative controls) and `wrapper4-test.sh` (dynamic).

| # | Mutation | Wrapper | Step | Guards and single attempt |
|---|---|---|---|---|
| M1 | `sandbox create --name $SBX` with the exact `CREATE -- LAUNCH` argv | `O` | `c0-create` | Only after `launch_check` passed: every element at most 32,768 bytes, the encoded payload at most 24,576 bytes, argv shape and count, the payload decoding to the original tar, a deterministic rebuild. `O` re-checks the record and the sizes, and the check runs before the `done-c0-create` marker. Exact argv only; refuses `--no-keep`, `--keep`, `--driver-config*`, `--upload*`, `--workspace*`, `--editor`, `--forward`, `--expose`; after create, STOP if the sandbox is `retention=ephemeral`; `once` |
| M2 | `sandbox connect $SBX` in a harness-owned tmux server | `client_start` | `c0-baseline`, `c4c` | Refused in any other step; no pre-existing client |
| M3, M3b | One fixed-form line plus Enter; Ctrl-L | `type_line`, `ctrl_l` | `c0-baseline`, `c4c` | Characters `[A-Za-z0-9 .,:=<>-]`, at most 240, so no control byte can be sent; logs length and hash only; **c4c: at most 2 lines** |
| M4b | Ctrl-P Ctrl-Q, with SIGKILL of the harness's own client tree as fallback | `client_detach`, `client_kill` | `c0-baseline`, `c4c` | Zero surviving clients required |
| M6 | `sandbox delete $SBX` | `O` | `cleanup` | Issued only when read-only discovery (`sbx_discover`) finds this run's sandbox (name, `exp008.run`, `exp008.stage=c4`, recorded id). If the sandbox is verified absent, the result is `delete=skipped-verified-absent`. Any other outcome STOPs without a delete. Cleanup has its own once-only marker. It runs after a STOP, never stops or starts the sandbox, and waits up to 300 s for a settled phase |
| M7 | `gateway logout exp008c` | `O` | `logout` | — |
| M8 | `sandbox exec … python3 -I -c <X5PY>` (TCP egress probes) | `O` | `c0-baseline` | Exact argv (as C0–C3) |
| **M9** | `kubectl -n openshell delete pod <recorded workload> --grace-period=1 --wait=false` | `kw` | `c4a` | Requires: step `c4a`; `obs/c4a-armed`, written only after a complete reference snapshot R; the M9 once-marker; the pod's labels **and UID** equal the recorded workload; the cluster identity guard. Refuses `--force`, grace 0, the default grace, other pods, `scale` and PVC deletes |
| **M10** | `sandbox stop $SBX` | `O` | `c4b` | Exactly 3 arguments; `done-m10` once-marker; `c4b` refuses to stop unless the phase is `Error`; a nonzero exit is `not-restartable` even if the phase later moves |
| **M11** | `sandbox start $SBX` | `O` | `c4b` | Only after M10, once (`done-m11`). `c4b` starts only when all of these hold: `Stopped` reached; no pod of the sandbox left; the CR exists, is not deleting and is suspended (`operatingMode: Suspended` or `replicas: 0`); the VolumeAttachment released; PVC/PV identity unchanged and not deleting. Any failure is `not-restartable` or `lost`, with no start. A nonzero exit from start is `not-restartable` |

**Read-only exec.** `kubectl exec` goes only into the **current** workload pod, with its labels and UID re-checked each time (`wpod_ok`), so it can never reach a same-name replacement pod. It runs only the fixed scripts X1–X10:
- X1–X7 are the C0–C3 scripts;
- X8 reads in-flight timing and the state-id and token-file hashes (never the token);
- X9 reads the launcher's identity, precheck and refusal records;
- X10 copies the resume launcher's frozen copy of the state.

**Out of scope for every wrapper:** gateway scale or restart, PVC or label operations, driver config, provider, profile or credential operations, and GitOps changes.

## 4. Implementation notes and clarifications (within the approved design)

These are choices the proposal left open, stated so they can be reviewed. None changes an approved decision.

1. **Real-model predicate** (`metrics4.is_real_model_entry`). A qualifying entry has `type: assistant`, a non-empty `message.id`, `message.model == "claude-haiku-5-5"` exactly, integer `usage.input_tokens` and `usage.output_tokens`, and no `isApiErrorMessage` or `error`. Synthetic entries and malformed lines never qualify. A dated model id fails closed (it is not counted). The predicate is used by the C0 H4 gate (`_tr_probe`), the R completeness check, probe evaluation, the C4c (a) activity count and the C4c procedure. The C0–C3 `metrics.py` and its historical classifications are unchanged.
2. **C0 control line.** The codeword line is the §5.6 control line. Its `LAST` is accepted if it is one of the 0–2 steps completed after it was typed, because the agent is mid-step and answers after the current step. The control result is recorded, and C0 stops only if the line was not delivered.
3. **C4a timing** (proposal §5.3, Sonnet S2):
   - R starts only on a step whose attempt is 3–12 s old.
   - R is taken as follows: `ident` (P, W, CR), `vread` (V), `snap` (task logs and transcript) and X8 (state-id and token-file hashes).
   - R is complete only if all of these hold: P and W keys are readable; V shows exactly one PVC with a bound PV; the snapshot succeeded; the ledger chain is intact; both hashes are 64-hex; the transcript has a real model entry; the in-flight step N is the last attempt and `done` has reached N−1; and R's transcript holds step N's `tool_use`.
   - X8 is then read again. M9 is issued only if N is unchanged, still has no `done`, and its attempt is at most 30 s old.
   - Waiting up to 15 min for a step in that age window is a gate. R itself is taken **once**: an incomplete or late R STOPs as `not-tested` and nothing is deleted (proposal §5.3).
4. **C4a outcome.**
   - `ended` means the original pod UID is absent **and** either a terminated container state was captured or a `DELETED` watch event was seen. An unreadable P alone is `inconclusive`.
   - The termination record is the captured state (exit code, reason, signal). A 1 s grace request is not evidence of a SIGKILL.
   - The sampler now captures a pod once when it starts deleting and once more when a container shows `terminated`.
5. **Resume launcher order.** Verification, freeze and precheck run **before** the credential checks, so C4b remains measurable if the credential path then fails. The approval-tail edit runs after the credential checks. It changes only `customApiKeyResponses.approved`, in both copies, and records hashes before and after.
6. **C4b comparison** (tail bound as amended by owner decision D-1, 2026-11-26).
   - The frozen copy taken by the launcher before `exec` is compared with R. The checks are: append-only logs; the token-file hash; the ledger chain; the transcript byte prefix; and the tail bounds.
   - The tail bounds are:
     - 64 KiB in total;
     - **at most 5 entries**;
     - entries 1–3 of the approved types (`assistant`, `api-request`, `cost-state`, `last-prompt`), or step N's own tool result;
     - **entries 4–5 only recognized metadata** (`api-request`, `cost-state`, `last-prompt`);
     - `parentUuid` continuity;
     - one partial final line, accepted only among entries 1–3, because a torn line at position 4 or 5 cannot be recognized as metadata.
      - **No tool activity:** no tail entry may carry a `tool_use`, because step N's call is already in R. Step N's own result entry must hold exactly that one tool result.
   - Anything else is `corrupt` (`tail-entry-4-5-not-metadata`, `tail-tool-activity`, `tail-too-many-entries`, …).
   - The in-flight write order maps to `in-flight-partial(1)`, `in-flight-partial(2)` or `in-flight-completed`.
   - A launcher refusal maps to `lost` (partial or missing state, session id, transcript or state id) or `corrupt` (a chain, settings or step.sh mismatch).
7. **C4c decision procedure** (`metrics4.c4c`). The proposal's ordered §6.3 procedure, with these precisions:
   - **Strict probe (owner correction B).** The first text block that carries the token must *be* the one line `PROBE-<8 hex> CODEWORD=<alnum> LAST=<0..999>`, with surrounding whitespace only. Any prefix or suffix text, a second line, punctuation, a placeholder, a leading zero or swapped fields fails `format_ok`. A later well-formed line does not rescue a malformed first reply. **Expected consequence:** a real model that adds backticks, a period or a preamble in the same text block fails the strict format. That reads as `resumed-context-lost` (or `inconclusive` if the control line also failed), never as a pass. The committed `metrics/c4c.json` keeps `format_ok`, `codeword_ok` and `last_ok` separately, so the owner can tell a formatting failure from lost recall.
   - **Session integrity (owner correction C).** The session axis is `same-id-same-file` only when the post-resume listing shows exactly the original transcript and its frozen bytes are an exact prefix. No listing gives `unavailable`. A duplicated file is `inconclusive (session-duplicated-file)`. A second session id inside the file, or an id that differs from the transcript's file name, is `inconclusive (session-id-ambiguous)`. **`primary_pass` additionally requires** session `same-id-same-file`, process `new-process`, the final transcript **and the launcher's frozen pre-resume copy** available, and one consistent session id (equal to the file name's). The R fallback boundary can classify a run, but it never passes it.
   - **Session axis:** the pre-fault file no longer starting with its frozen bytes is `fresh-no-history`; a different transcript basename is `new-id`; the same basename twice is `same-id-new-file`.
   - **Inconclusive when the probe is not delivered:** a probe that was typed but never reached the session, while the model was responding, is `inconclusive (probe-not-delivered)`. That is a harness or terminal failure, not memory loss.
   - **`probe-ignored`:** the value applies when any `tool_use` precedes the token-bearing reply. That covers "the first action is a tool".
   - **Primary pass:** a pass requires the accepted step N to come from a conforming `./step.sh N <token>` with the pre-fault token and **no** non-conforming Bash command after resume, as proposal §4 specifies.
8. **Process axis.**
   - `unreadable`: the exec failed with no launcher refusal recorded. It is `inconclusive` and never counted as `not-started`.
   - `same-as-original`: the old nonce was read after start. That is impossible after C4a, so it is `inconclusive`.
   - `not-started`: the launcher refused, or the workload is readable and no Claude Code process runs.
9. **After a STOP.** Only the stop path runs: cleanup (once), `post` (read-only), `sampler-stop` and `logout` (M7).
10. **Cleanup and restoration.** C4 never changes gateway replicas. If they differ from `pre`, that is recorded, not repaired. `post` allows only the provider and profile lists to differ, so any change to the gateway StatefulSet generation, gateway pod UID, PVC, PV or VolumeAttachment is `NOT-CLEAN`.
11. **Signal handling in `step.sh`** (a defect found offline and fixed in the C4 copy only).
    - **The defect.** The C0–C3 `step.sh` traps `EXIT INT TERM HUP` with only a lock removal, so the script continues after a signal. The offline SIGTERM-then-SIGKILL-after-1 s regression (what `--grace-period=1` does) showed the result: SIGTERM killed the `sleep`, and `step.sh` immediately wrote `done N`, rotated the token and appended the ledger line. The new token reached only the dying agent, so every graceful kill would have produced `chain-broken-by-fault`.
    - **The fix.** The C4 copy removes the lock on EXIT and exits 143 on INT/TERM/HUP **without** `done`, as the design's in-flight model assumes. `step4-test.sh` and the regression's SIGTERM variant both check it.
    - **C0–C3.** C0–C3 is unchanged. Its runs never signalled a step: C1 killed only the client, and C2 never touched the workload.
    - **Unknown (U).** Whether the OpenShell runtime forwards the container's SIGTERM to the agent's process group.
12. **Spend guard after M9** (Sonnet review blocker, fixed). After the workload pod is deleted, and while the relaunched agent is not running, `spend_check` cannot read the transcript. Nothing can spend then. The check is recorded as `usage=workload-not-running phase=<phase>` and does not STOP. A `Ready` sandbox, or an unreadable phase, with an unreadable transcript still STOPs. The fix is tested with the real `spend_check` in `wrapper4-test.sh`.
13. **A launcher refusal at start is a C4b result, not a restart failure.**
    - When the relaunched launcher refuses, the main process exits and the sandbox reads `Error`.
    - `c4b` then reads the refusal phrase from the exited workload pod's log (local copy) and classifies it. Partial or missing state, session id, transcript or state id is `lost`. A chain, settings or step.sh mismatch is `corrupt`.
    - A credential refusal, or a frozen copy that could not be read, is **`unmeasured`**. This is an added C4b value: a measurement gap is never reported as corrupt state.
    - A relaunch in Fresh mode (identity-2 `mode=fresh`) is `lost`.
    - `c4c` then records `not-started`.
14. **C4c robustness.**
    - A final transcript that could not be copied makes the session axis `unavailable`. That is `not-started` if the launcher refused or no process ran, and `inconclusive (final-transcript-unavailable)` otherwise; `fresh-no-history` is kept for a file that exists but lost its prefix.
    - A probe that was never typed is `inconclusive (probe-not-typed)`.
    - A new session id is `inconclusive (session-new-id-not-followed)`.
    - `start_t` is converted to the workload clock with the C0 skew.
    - If the frozen copy is missing, R is the boundary (attribute `boundary=R`).
15. **Kill deadline.** M9 is refused if more than 38 s could have passed since step N's attempt (the re-check age plus the time elapsed since the re-check), so a slow API cannot kill after `done N`.
16. **C4b gates before start.** All of these must hold, otherwise the sandbox is `not-restartable` with no start:
    - no pod left;
    - the CR suspended;
    - the VolumeAttachment released;
    - a zero exit from `stop`;
    - V after `start` compared with R.
17. **The tail allowance also admits step N's own tool result**, so `in-flight-completed` is reachable. A tool result for any other call is still `corrupt`.
18. **Package transport (corrective, after run `1127-1814`).**
    - **Package.** The deterministic tar (unchanged) is compressed with `gzip -9 -n` (no name, no mtime) and then base64-encoded. The bootstrap differs from C0–C3 in one step only: it decodes to `pkg.tar.gz`, runs `gzip -dc` to `pkg.tar`, then does exactly what C0–C3 did (sha256 of the original tar, `pkg.sha256`, extract, exec the launcher). Every failure exits under `set -eu` before the launcher runs.
    - **Sizes.** At this commit the tar is 30,720 bytes (sha256 `5f524cae…`, the run's), the gzip is 7,586 bytes, and the payload element is **10,116 bytes**. The elements are `7,2,334,10116,64`, against a 24,576-byte budget and a 32,768-byte limit.
    - **`launch_check`.** It records sizes, hashes and pass/fail only, in `obs/c0-launch-result.txt`. It runs before `done-c0-create`, so a failure STOPs with no create request and no marker.
    - **Pinned image (static layer inspection only).** `/bin/sh` is dash 0.5.12, gzip 1.13, GNU tar 1.35, and coreutils 9.7 for `base64` and `sha256sum`, with no later-layer whiteout. Running the bootstrap inside the pinned image is **not yet verified** (U); the offline tests ran it under bash and `bash --posix`.
19. **Cleanup after a failed create.** `done-c0-create` means a create request was sent, not that a sandbox exists. Before any delete, `sbx_discover` reads `sandbox get` and the Sandbox CR list.
    - `present`: the name, `exp008.run`, `exp008.stage=c4` and the recorded id (when one exists) all match. The existing guarded delete then runs once (`delete=issued`).
    - `absent`: the CLI says `sandbox not found` **and** a readable CR list has no CR for `$SBX`. The delete is skipped (`delete=skipped-verified-absent`).
    - Anything else: a failed or unparseable lookup, an unreadable CR list, not-found with a CR present, or a name, label or id mismatch. Cleanup STOPs with no delete and leaves the decision to the owner.

    The full residue checks are unchanged and run in every non-STOP case. The result is in `obs/cleanup-discovery.txt`.

## 5. Procedure (for a future authorized run; not to be run now)

All harness calls run under `env -i HOME USER LOGNAME TERM LANG` (the C0–C3 lesson). Owner steps are marked **[owner]**.

1. **[owner]** In the dedicated Console workspace, create a **new** API key, confirm the **$5** cap, and keep `BUDGET_USD=2`.
2. **[owner]** In the owner's own terminal, with `../stage-c/owner/owner-provider.sh`: `setup` if needed, `login`, `list`, `profile-import`, `create`, `list`. The profile and provider names are unchanged: `claude-code-exp008c`, `exp008c-anthropic`.
3. **[owner]** Confirm the GitOps/Renovate freeze, the redaction list and the pinned CLI. Name the harness commit in the authorization. Generate the run ID at the start of `pre`; a C0–C3 run directory is refused.
4. `stagec4.sh <RUN> pre`, then `sampler-start`, `c0-create`, `c0-baseline`. Checkpoint report.
5. `c4a`. Checkpoint report: R, the termination record, the replacement fate, the phase.
6. `c4b`. Checkpoint report: stop and start timings, the C4b value.
7. `c4c`. Checkpoint report: every C4c axis and the primary pass.
8. `cleanup`, then **[owner]** `owner-provider.sh delete` (provider, then profile), then `post`, `sampler-stop` and `logout`. Then **[owner]** revoke the key and record the Console spend.
9. Export with `../stage-c/export.sh <RUN> <absolute DEST>`, which runs its redaction scan. Write the results record. Findings are **proposed**.

**Stop conditions:**
- every Stage C guard (identity, Argo/GitOps freeze, competing Sandbox CR, provider list, the 00:30–07:00 window, spend at 80 %, unreliable usage);
- the gateway pod UID changing;
- 60 min since `c0-create`; 20 min since `start`;
- more than 10 refusals after resume;
- the c4a gate or R not met within 15 min;
- the phase not `Error` before stop;
- `Stopped` or `Ready` not reached within 300 s;
- PVC/PV identity changed or deleting before start.

A `not-restartable`, `lost`, `corrupt` or any C4c value is a recorded result, not a reason to retry.

## 6. Evidence and redaction

- **Unchanged:** `../stage-c/export.sh` and its scan. Its run-token list already covers `raw/codeword` and `raw/*-probe`, which holds the C0 and C4c probe tokens.
- **Committed:**
  - per-step `obs/*-result.txt` and `*-summary.txt`;
  - `metrics/*.json`, which holds V summaries (PVC/PV UIDs and a 12-hex sha256 of the volume handle) and the C4b/C4c outputs (booleans, counts, values);
  - the launcher's identity and precheck records (forms, hashes, counts, names);
  - samples, the timeline and inventory diffs.
- **Local only, in `raw/`:** transcripts, the frozen pre-resume copy, screen captures, the codeword and probe tokens, the raw volume identity, and container logs.
- **Never recorded anywhere:** a credential or placeholder value. The C4b and C4c input bundles (local paths) stay in `raw/`. Only `key_form` and the approval-tail result are recorded.

## 7. Requirement compliance (approved Phase 1 items)

| Approved requirement | Implemented as | Test |
|---|---|---|
| One sandbox, default per-sandbox PVC | M1 once; `vread` requires exactly one PVC with a bound PV | allowlist4, wrapper4 (O create) |
| C4a: `--grace-period=1`, no `--force` | `kw` exact argv; force, grace 0 and default grace refused | allowlist4 §3, wrapper4 kw |
| R complete and verified; ≥ 6 done; exactly one in-flight step; age window; no client; pod still the sandbox's | c4a loop (section 4.3); `kw` armed, once, UID | wrapper4 c4a (9 cases), test_metrics4 |
| Termination observed, not assumed; replacement and fence captured | c4a observe window; sampler terminated-state capture | wrapper4 c4a |
| C4b-N: stop then start, once each | M10/M11 markers; `c4b` from `Error` only | wrapper4 c4b (9 cases), allowlist4 |
| Identity and integrity before and after; distinguish intact, allowance, partial or chain-broken, corrupt, lost, not-restartable | `vread` V; launcher precheck and frozen copy; `metrics4.c4b` | test_metrics4 C4b (13), resume-regression (real files) |
| Never success from PVC existence alone | C4b requires state-id, logs, token file and transcript prefix | test_metrics4 `test_lost`, `test_unexpected_changes…` |
| No alternative recovery if not restartable | `nr` records, then STOP to cleanup; no helper pod or retry | wrapper4 c4b stophang/stopfail/starthang |
| C4c: observe, attach, probe, at most one "Continue the task.", bounded observation | `c4c` (a)–(d); `type_line` cap 2 | wrapper4 type_line; resume-regression (real binary) |
| Conversational and task-integrity evidence both required | Primary pass = Resume value × Repeat/skip × C4b; the step-N token check | test_metrics4 C4c, resume-regression |
| In-flight step tracked separately | `in_flight()`; `prior_attempts`; `in-flight-reattempt-only` | test_metrics4, step4, resume-regression |
| Ordered, mutually exclusive classes, a fixture per class, a totality test | `metrics4.c4c` decide(); `FIXTURES`; `Totality` (300 random) | test_metrics4 |
| No ledger repair, no replay | Nothing writes the task directory except the agent's `step.sh`; the launcher refuses a broken chain | launch4, allowlist4 (X8–X10 read-only) |
| Plain `--resume`; no `--session-id`; no positional prompt; auto-continue unset | `task/launch.sh` | launch4, allowlist4 §10, resume-regression (argv from `/proc`) |
| `STEP_SLEEP=45` | Launcher export and step default; C0 STOPs unless every attempt records `sleep=45` | launch4, step4 |
| §5.6 probe and control lines, verbatim | `c0-baseline`, `c4c` | wrapper4 type_line |
| Spend, time and retry limits | `guard_full` (60/20 min, 80 % spend), refusal cap, input cap; no retries | allowlist4, wrapper4 |
| Shared real-model predicate with negatives | `metrics4.is_real_model_entry` | test_metrics4 `Predicate` (16 negatives) |
| C0–C3 cannot perform C4 mutations | Separate harness; C0–C3 byte-identical | c0c3-unchanged, allowlist4 §11 |
| No provider/credential administration; no GitOps, gateway or external PVC change | Wrapper allowlists | allowlist4 §5, §7 |
| No sampler after successful cleanup; failed cleanup reports residue | `sampler_done`; `cleanup-residue.txt` and STOP | wrapper4 cleanup, sampler |

## 8. Offline verification (2026-11-26; counts updated 2026-11-27 for the corrective PR)

`bash experiments/exp-008/stage-c4/tests/run-all.sh` runs the C4 suite and the unchanged C0–C3 suite. No cluster, no network, no credential; the two pinned-binary tests run in loopback-only namespaces.

| Suite | Checks | Covers |
|---|---|---|
| `test_metrics4.py` | 61 unit tests | Predicate negatives; byte offsets and torn lines; strict probe (pass, tool before the reply, wrong codeword/LAST/format, synthetic reply ignored, queued-only, not delivered); C4b (intact, tail allowance, the three partial states, impossible orders, unexpected changes, rewritten log, prefix, broken chain, lost, refusal mapping); C4c fixture per value and axis; interrupted-turn values; precedence where rules overlap; a correct reply alone is not a pass; the D-1 five-entry tail (3, 4, 5 accepted; 6 rejected; an assistant, tool result, unknown type or torn line at position 4/5 rejected; prefix, continuity and byte limit; the allowance never hides corruption); the strict one-line probe (19 format cases); no ambiguous session can pass (duplicated file, new id, no listing, unavailable, fresh, unreadable or original process, a mixed session id); primary-pass implications over 120 random runs; totality over 300 random runs (one value each, and the primary pass is exactly the documented conjunction); no secret in output |
| `launch4-test.sh` | 61 | Deterministic package; byte-identical bootstrap, prompt and settings; CREATE argv; Fresh argv; Resume argv (no `--session-id`, no prompt); unset auto-continue variables; env names only; frozen copy; approval tail same and added in both copies; 11 refusal cases with no fallback; precheck before a credential refusal |
| `step4-test.sh` | 19 | Token chain and refusals; recorded sleep; SIGTERM during the sleep ends the step without `done`; stale-lock cases (live, empty start, other boot, dead pid, reused pid); lock break from a new PID namespace with `prior_attempts=1` |
| `allowlist4-test.sh` | 58 | Wrapper confinement, the exact allowlist, step binding, once-only, no C1–C3/Phase 2/gateway/credential path; **10 negative controls** (mutated harness copies must fail) |
| `wrapper4-test.sh` | 110 | Real `O`, `kw`, `kx`, `type_line` and the real c4a/c4b/cleanup step bodies against a stub CLI, kubectl and clock. c4a: complete R, a late, finished or old step, snapshot, identity or UID failure, R taken once, and the survived, deleting, not-captured, ran, fenced and none outcomes. c4b: normal; not from Error; stop hang, refused, or refused-but-Stopped; start hang or refused; CR not suspended; pods remaining; attachment not released; PVC changed or deleting; C4a not ended. Cleanup: from Stopped, Error, Ready, Starting and Stopping; a phase that never settles; residue; no create; twice. Sampler self-stop |
| `transport4-test.sh` | 45 | Corrective PR. Sizes: the run's 40,960-byte element refused by the stub as OpenShell refused it; 27,308 bytes under the limit but over the budget; the corrected payload within the budget; 32,767, 32,768 and 32,769 bytes; a poorly compressible package. The real bootstrap under `/bin/sh` and `bash --posix`: valid launch and relaunch; corrupted base64, truncation, invalid gzip, a raw tar, a wrong sha256, missing gzip and a sha-valid non-tar each exit nonzero with no launcher run and nothing extracted. The real `c0-create` body: one create request for the corrected package; a local STOP with no request and no marker for the original transport, a poorly compressible package or missing compression |
| `c0c3-unchanged-test.sh` | 3 | The 21 C0–C3 harness hashes from `1126-1017` |
| `resume-regression-test.sh` | 24 | Pinned 2.1.323 through the real C4 bootstrap and launcher, a scripted mock model, and a simulated pod loss with step 2 in flight, as SIGKILL and as SIGTERM+1 s (see below) |
| C0–C3 suite, unchanged | 28 unit + 176 checks | As recorded for `1126-1017` |

**What the resume regression shows** (O-offline). The scripted mock model answers from the request history only. The run used loopback only, a made-up placeholder and 4 s test pacing. Observed:
- the launcher selected Resume and froze the state;
- the resumed argv was `--resume <sid>`, with no `--session-id` and no prompt;
- no request was sent in 12 s without input (CR2);
- the first request after the probe carried the history (8 messages) and a synthesized `is_error` "interrupted" result for the killed call (CR3);
- the session file was the same, with the pre-fault bytes as an exact prefix (CR5);
- after "Continue the task.", step 2 was re-attempted with `prior_attempts=1`, using the token that existed only in the pre-fault conversation, and steps 3–4 followed;
- `metrics4` classified the real files as C4b `intact` and C4c `resumed-continued-after-prompt`, `synthesized-interrupted`, `same-id-same-file`, `in-flight-reattempt-only`, primary pass.

**SIGTERM-then-SIGKILL-after-1 s variant** (the 1 s-grace kill), with the fixed `step.sh`:
- step 2 did not complete during the grace;
- the transcript tail after R was **3 entries** (`cost-state`, `last-prompt`, `cost-state`; 1528 bytes), and C4b read `intact-with-allowance`;
- resume continued with no refusal.

The approved tail bound is 3 entries. CR1 had recorded 4 metadata rows on SIGTERM, including an `api-request` row, which here was already written before R. **The bound has no margin** (owner decision D-1, section 11).

This validates the harness, launcher and classifier path. It says **nothing about the real model's** recall or behaviour, OpenShell's `stop`/`start`, or the cluster.

## 9. Remaining runtime uncertainties (U; only a live run can answer)

1. Whether `sandbox stop` succeeds from the fence-suspended `Error` left by a workload-pod delete, and whether `start` reaches `Ready` (F3). The CR's runtime-identity check at start (`driver.rs:4258`) could refuse it.
2. Whether the per-sandbox PVC survives in `Error`, and whether Longhorn releases and re-attaches it on another node within 300 s.
3. The phase strings that `sandbox get -o json` reports for stop and start (`Stopped`, `Ready`, `Error` assumed from source).
4. How the 1 s grace delete ends Claude Code (exit code and signal), and whether its transcript then has a torn final line.
5. Whether the new supervisor resolves the provider at start with the same placeholder revision (the approval-tail path covers a change).
6. The real model's behaviour after the synthesized interrupted result: re-run step N, try N+1 first, or ask. Its codeword and `LAST` recall in a 10–15 step transcript. Whether a resume dialog appears.
7. Whether the probe line, typed while the TUI shows "Interrupted · What should Claude do instead?", is delivered as the next prompt (offline it was).
8. Spend and timing: about 20–35 requests and 20–30 min of agent life (estimate).

9. Under a real 1 s-grace delete: whether the OpenShell runtime delivers SIGTERM to the agent's process group (the fixed `step.sh` then exits without `done`), or only to the container's PID 1.
10. Whether a refusing relaunch leaves its workload pod readable for `kubectl logs` (Agent Sandbox's `failedPodPolicy: Retain` suggests so, I). If the pod is gone, the refusal reason is lost and C4b reads `not-restartable (no-single-workload-pod-after-start)`.

## 10. Risks and known limits

- **The harness is single-run code that a live run has never executed.** The stubs model the CLI and Kubernetes from source reading, not observation. A first live run may stop on a harness defect, as C0–C3 did twice. Every stop path leads to the same cleanup.
- **R timing depends on exec latency.** R is abandoned (not killed) if the re-check sees the step older than 30 s, so slow exec costs time, not correctness.
- **Lost state looks like a fresh launch to the launcher.** The harness guards this from outside: V is checked before `start`, and `lost` or `fresh-no-history` override every C4c value. A fresh session would still spend a little.
- **The permission rules are not an OS boundary.** The agent runs as uid 10001 on the PVC that holds its transcript. Every resumed Bash command is regex-checked, and the C4c pass requires zero non-conforming commands.
- **The CR4 auto-continue variant, Phase 2, graceful pod loss, node loss and supervisor-pod loss are not tested.**
- **The tail bound (D-1, decided 2026-11-26)** is up to 5 entries; entries 4–5 must be recognized metadata. The offline SIGTERM measurement gave 3, and CR1 once saw 4. Additional tool activity is never accepted.
- **The 60 min wall clock** (approved) can be tight in the worst case: C0 up to about 13 min, then up to 15 min for the gate and up to 15 min to arm, before C4b and C4c. A stop on it is a recorded `not-tested`, not a failure of the question.
- **The frozen copy and refusal records live on the PVC.** After a refusing relaunch they cannot be read through the supported path, because the container has exited. Only the logged refusal phrase is available.

## 11. Reviews (2026-11-26)

- **Independent Haiku verification.** The full suite was re-run independently, with all counts as recorded and 0 failures. Inventory, mutation and guard audit, coverage against §6, missing-case sweep, credential sweep: no blocker. Its should-fix items are adopted:
  - logout after a STOP documented;
  - stop/start exit codes enforced;
  - c4b gates made hard;
  - R taken once;
  - process `unreadable`;
  - C4a classifier tests (survived, deleting, not-captured, ran, fenced, none);
  - interrupted-turn, precedence and totality tests strengthened;
  - a start-refused case and a cleanup-from-Starting case added.
- **Independent Sonnet technical and security review.** OpenShell v0.1.9 facts were verified in source: stop/start take a name only and block, the phase strings, stop admitted from `Error`, start replaying the stored main-process spec, the CR and PVC kept, the `--no-keep` ephemeral path. **One blocker:** the spend guard STOPped at c4b and c4c. Ten should-fix items, S1–S10. All fixed (section 4, items 12–17) except S9 (freeze before refusing): after a refusal the frozen copy cannot be read through the supported path, so the logged refusal phrase is used instead (section 10). Nits N1–N4 and N6–N8 fixed (`CLAUDE_CODE_*` names recorded before unsetting; every `CLAUDE_CODE_RESUME_*` unset; both `.claude.json` copies validated before writing either; a torn last ledger line checked; `last_in` taken at the last input; explicit new-id path). N5 (slug check) is not adopted; a cwd mismatch shows as `not-started` or `failed`. N9 and N10 are documented (sections 10, 11). The vacuous `kx` assertion and the any-value c4b assertion were fixed. The review found no false pass in the classifier.
- **Found by the lead's SIGTERM variant of the regression:** the `step.sh` signal defect (section 4, item 11).

## 12. Execution readiness checklist (for a separate owner authorization)

- [ ] Owner review of this PR. A squash merge to `main`, and the authorization names that harness commit.
- [ ] **Corrective packaging PR** reviewed and squash-merged. A new authorization names the resulting commit; run `1127-1814` used `cb7899a`.
- [ ] Bootstrap verified inside the pinned image (`dash`, gzip 1.13), offline and with no network, before `pre`.
- [ ] The offline suite re-run on that commit immediately before `pre` (`tests/run-all.sh`, under `env -i`), with counts recorded.
- [ ] **[owner]** Decision on FIND-095 to FIND-097, including the addendum's narrowed wording.
- [ ] **[owner]** A new API key, the $5 cap and `BUDGET_USD=2`; provider and profile recreated with `owner-provider.sh`; the key never handled by an agent.
- [ ] **[owner]** GitOps/Renovate freeze for the window (start before 23:00 local), the redaction list confirmed, the pinned CLI sha256 confirmed.
- [ ] **[owner]** Availability for the checkpoint reports after C0, C4a, C4b, C4c and cleanup.
- [ ] **[owner]** After `cleanup`: delete the provider and profile, then `post`. After `logout`: revoke the key and record the Console figure.
- [ ] **[owner]** Decision on raw evidence retention (transcripts, the frozen copy, screens).
- [x] **D-1, the transcript tail bound:** decided (owner, 2026-11-26). Up to 5 entries; entries 4–5 must be recognized metadata. Implemented and tested.
- [x] **The C4 `step.sh` signal fix:** approved (owner, 2026-11-26). C0–C3 is unchanged.
- [x] **The added classification values:** approved (owner, 2026-11-26). They are:
  - C4b `unmeasured`;
  - session `unavailable`;
  - process `unreadable` and `same-as-original`;
  - the documented inconclusive reasons.
- [x] **The single reference snapshot:** approved (owner, 2026-11-26). An R that cannot be verified, or an expired timing gate, STOPs without deleting the pod. There is no second R.
- [ ] **[owner]** Record the FIND-095 to FIND-097 decision on issue #39 (draft language in PR #49's description).
- [ ] `sampler-stop` after every run, including after a cleanup STOP: the sampler stops itself only after a successful cleanup.
- [ ] Explicit owner authorization naming: Phase 1, one run, the harness commit, and the run window.
