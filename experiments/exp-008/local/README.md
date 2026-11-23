# EXP-008 stage A (local): three authorized runs; run 3 (`1123-122157`) reached A4b

**Result.**
- **Run 3 (`1123-122157`, the third and last authorized attempt)** passed P3, A1, A2, A3 and A4a.
- It **recorded A4b as FAIL and stopped**. The cause is a harness check defect, not a process-continuity failure:
  - `ACK a4b` arrived with the correct identity, in the counter log and in the new pane.
  - The pane was about 27 columns wide, so the ACK line wrapped onto three lines.
  - `verify_ack`'s exact-line grep of the pane capture could not match it.
- The new A4 stop rule ("ACK did not satisfy the primary criterion") then applied.
- **A5, A6 and A7 did not run.** Gateway restart, single writer, and retention/delete are still unobserved.
- Cleanup is **CLEAN** on the verified final state. The recurring overlay "Device or resource busy" made the intermediate classification RESIDUE.
- **Runs 1 and 2** both stopped at A1 (details below).
- No further run is authorized.

**What run 3 shows (one local run, OpenShell v0.1.9, Podman 5.8.9, Herdr 0.9.5).**
- The canonical main process kept one identity, on all three sources and through every lifecycle event:
  - pane attach and abrupt pane close;
  - reattach with replay;
  - a clean Herdr server stop/start;
  - a SIGKILL of the Herdr server.
- The counter ran without a gap (n=1–41).
- In both Herdr restarts, the whole client chain (CLI → ssh → proxy) was gone at the first scan after the server exited. Two scans found zero client processes while the counter advanced.
- **Not shown:**
  - the A4b pane criterion as the harness defines it;
  - any gateway-restart behaviour;
  - single-writer behaviour;
  - retention and delete.

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../../docs/experiments/08-openshell-execution.md) · REQ-009, REQ-011 (both remain **Future**) · ADR-0001 unchanged.

## Findings

| ID | Status | Statement (scope) |
|---|---|---|
| FIND-077 | **Accepted** (owner, 2026-11-23) at its observed, single-workstation scope: the workaround succeeded in run 2 | OpenShell v0.1.9's Podman driver gives the workload and supervisor a Podman healthconfig with `test ["NONE"]` and a 10 s interval. Rootless Podman 5.8.9 then needs `$XDG_RUNTIME_DIR/systemd/private` when the container starts. Run 1 observed this failure. In run 2, `DISABLE_HC_SYSTEMD=true` in the dedicated service's environment was sufficient: the probe and the real sandbox started with no healthcheck timer unit, and `State.Health` was absent (null). Scope: one workstation, Podman 5.8.9, a relocated runtime dir. REQ-011. |
| FIND-078 | **Accepted** (owner, 2026-11-23) at its documented scope | A disposable OpenShell v0.1.9 gateway can be isolated on a workstation that already has OpenShell registrations, a default rootless Podman store and agent-backed SSH. The ingredients are a dedicated store and socket, a run-local XDG/registry with `OPENSHELL_SYSTEM_GATEWAY_DIR`, a loopback mTLS listener and an agentless ssh wrapper. The protected baselines were unchanged in both runs. |
| FIND-079 | **Accepted** (owner, 2026-11-23) at its documented scope | Verify OpenShell v0.1.9 release provenance with `gh attestation verify --owner NVIDIA`. The signer is `release-publish.yml@refs/heads/main`, and the certificate names the `main` dispatch commit `624aceea`. The build commit `ce58cf8e` comes from the promote job's `SOURCE_SHA`. Runtime images carry no GitHub attestation. Re-verified in run 2's preflight. |
| FIND-080 | **Accepted** (owner, 2026-11-23) at its revised, documented scope: source reading plus run 3's process snapshots of the chain. The first version, "connect exec-replaces itself with `ssh` on a TTY", was **wrong** and stays withdrawn | **Source (v0.1.9, `crates/openshell-cli/src`):** `sandbox connect` dispatches `main.rs:3665` → `run::sandbox_connect` (re-export, `run.rs:100`) → `ssh.rs:674-681` → `sandbox_connect_supervised()` (`ssh.rs:540`) → `run_main_attach_supervised()` (`ssh.rs:396-417`), which **spawns the host `ssh` as a child** (`kill_on_drop`) and stays up as its supervisor. It forwards SIGINT/SIGQUIT/SIGTERM (`ssh.rs:304-329`); SIGHUP is not caught. If ssh exits 255 after at least 2 s attached and the main process has no terminal result, it creates a new SSH session and respawns ssh, retrying for up to 60 s (`ssh.rs:57-68`, `445-455`, `593-651`). The exec-replace in `exec_or_wait()` (`ssh.rs:241-247`) is reachable only from `sandbox exec` (`ssh.rs:1027-1035` → `1021`); every connect path spawns. ssh runs the ProxyCommand `<cli> ssh-proxy --gateway … --sandbox … --token …` (`openshell-core/src/forward.rs:931-969`) via `$SHELL -c 'exec …'`. An attached pane therefore holds a three-process chain: CLI → `ssh … -s sandbox openshell-main` → `ssh-proxy`. Client accounting must recognise the chain, zero-client checks must cover all three processes, and the session token appears in two processes' argv. **Runtime (run 2):** the gateway log shows `CreateSshSession`, an allowed token `ForwardTcp` and an opened relay that stayed up until cleanup cancelled it. That is consistent with a live chain, but no process snapshot was taken, so the chain itself is unobserved. |
| FIND-081 | **Accepted** (owner, 2026-11-23) at its proposed scope: one local run, one synthetic process, not a real agent or a production deployment. See the A4b note below | An OpenShell v0.1.9 sandbox's canonical main process (`counter.sh` from `sandbox create --detach --tty … --`) is independent of Herdr. The process and session continued, with identity unchanged on all three sources (counter pid/start/nonce, `main_process_instance_id`/`main_process_started_at_ms`, host PID and `/proc` start) and `restart_count` 0, through each of: pane close with no client (n 6→11), reattach with replay from tick 1, clean Herdr server stop/start, and SIGKILL of the server (n advanced while Herdr was down). A new pane's `sandbox connect` accepted input (`ACK a4a`, `ACK a4b`). Scope: Podman driver, loopback gateway, synthetic counter; A4b's pane check is recorded FAIL by a harness wrap defect. REQ-009, REQ-011. |
| FIND-082 | **Accepted** (owner, 2026-11-23) at its proposed scope: two observations in one local run; the mechanism stays inferred | When the Herdr 0.9.5 server stops cleanly or is SIGKILLed, the attached `openshell sandbox connect` client chain (supervising CLI, ssh transport, `ssh-proxy`) ends with it. In both cases no client process was present at the first scan (0 s wait), and none appeared before the next scan. No disconnected supervising CLI lingered; v0.1.9's 60 s reconnect did not keep it alive. Inferred mechanism (not traced): the pty hangup reaches the chain's foreground process group, and the CLI does not catch SIGHUP. |

**A4b: recorded result versus evidence (owner acceptance, 2026-11-23).**
- The **recorded** A4b result stays **FAIL**. The harness's exact-line parser could not match an ACK that the terminal had wrapped. Run 3's `results.tsv` is not rewritten, and the harness is not claimed to have passed A4b.
- The **committed evidence** shows separately that the correct ACK was received and that the main process kept its original identity:
  - the counter log line `ACK a4b pid=52 start=43423622 nonce=fdf5d2b339358279 n=38`;
  - the same text across three rows of [panes/a4b.txt](evidence/1123-122157/panes/a4b.txt);
  - identity on all three sources, unchanged from A1.
- FIND-081 is accepted on that evidence, at its narrow scope: one local synthetic process, not a real agent or a production deployment.

## Run 4 (owner-authorized fourth and last attempt): corrections, reviewed before the run

**Authorization (owner, 2026-11-23).** One more bounded local stage A execution, focused on A5–A7. It runs after the corrections below have been made and independently reviewed. No fifth attempt is authorized.

**Boundaries.** The same pinned software, images and isolation controls as run 3, with fresh P1–P3 checks and all existing stop conditions. The run is limited to 30 minutes, uses no credentials, paid inference or Kubernetes, and gets no repair-and-retry loop.

### Harness corrections

**1. Wrap-aware ACK verification** (`demo.sh`, region `# >>> pane-ack`).
- Raw pane captures are kept as read: `panes/<word>.txt` (visible), `-recent.txt`, and `-unwrapped.txt` (Herdr 0.9.5's `--source recent-unwrapped`, which `herdr --skill` documents as "recent output with soft wraps joined").
- The expected ACK is built from the loaded identity and the log's `n`. The counter-log line must equal it exactly.
- The pane check passes if any capture shows the complete expected ACK:
  - as one whole row; or
  - as exactly the rows a terminal of width W shows when it soft-wraps that line from column 0. Each row except the last is the next W characters, right-trimmed. W comes from the candidate first row only.
- Other text between or around the rows, a partial line, unequal row widths or any other identity cannot match. The method does not join arbitrary newlines.
- Per-source results go to `obs/ack-<word>.txt`.
- `mark` now polls this check instead of `wait-output --match`. That match string could itself wrap.
- Every marked word in A1, A6, A5a, A5b (and the uncalled A4) is verified this way (static test).
- Notices are matched by their key phrase on one row, or by the whole notice line wrap-aware. Herdr's unwrapped capture covers both.

**2. Sequence.** A1 → A6 → A7a → A5a → A5b → A7b. A2–A4 are covered by run 3 and are not called.
- `CUR_ID` names the identity of the current main-process incarnation. It changes only after a classified gateway restart whose identity settled.
- Before any gateway restart, an identity change stops the run.
- A1 now stops on FAIL.
- **A6:**
  - Pane 1 must show live output, and no read-only notice, before pane 2 attaches, so that pane 1 holds the input lease.
  - **Negative:** the viewer's `mark a6ro` never produces an ACK, whether the viewer types it while read-only or the check comes after the owner leaves.
  - **Positive:** the owner gets `ACK a6w` while the viewer is attached. After pane 1 closes, pane 2 gets `ACK a6ro2` (a second attempt is made only if the first left no log ACK), together with `openshell: input enabled`.
- **A7a:** all panes are closed. The create CLI is gone, the identity is the same, phase is Ready and `n` advances.
- **A5a / A5b:**
  - Each restart is classified separately:
    - **survived:** every key is equal;
    - **restarted:** every key was collected and a process-level key differs;
    - **inconclusive:** otherwise;
    - **unavailable:** see below.
  - `ident_settle` waits for an identity that is unchanged 15 s later, because the persisted phase can read Ready before startup recovery restarts the containers.
  - **Unavailable** means no Ready within 300 s, or no settled identity and no Ready sandbox with a running workload. It records and **stops**: no recreate and no reset.
  - A5b runs only if the sandbox was usable after A5a: Ready, a classified identity, and a new pane that ACKed. It records whether the pane's original supervising CLI recovered and accepted input, or a new pane was needed.
- **A7b:**
  - Runs only if the sandbox is still manageable.
  - Delete output must say `Deleted sandbox` or `deletion accepted`; `already deleted` is rejected.
  - The sandbox must then read `sandbox not found`, and every tracked counter and container process from every incarnation must be gone.
  - Phase and `exit_code` before the delete separate natural completion from explicit deletion.
  - A deletion done by the cleanup trap is recorded as `C-delete INFO` ("emergency deletion"), never as A7b.
- **Results:** every planned step without a row is recorded `NOT-RUN`. A missing result is never PASS.
- **Evidence:** after a stop, cleanup first takes a bounded, read-only capture of panes, client chains, containers and `sandbox get`. The gateway log tail kept in evidence grows from 400 to 1500 lines.

**3. Offline tests** ([tests/ack-test.sh](tests/ack-test.sh), [fixtures](tests/fixtures/ack/)).
- **61 cases**, all passing:
  - run 3's exact A4b captures (visible and recent) and ACK log lines;
  - normal widths (96 and 57 columns, and Herdr-unwrapped);
  - synthetic wraps at 47, 32 and 17 columns, including wraps just after a space;
  - wrong pid, start, nonce, n and word;
  - incomplete ACKs;
  - unrelated or interleaved rows;
  - `verify_ack` with stale or uninitialised identity;
  - `mark` through a Herdr stub;
  - A5 classification.
- The old exact-line grep is shown to fail on run 3's capture.
- **Mutation check:** a matcher that skips row comparison fails 11 cases.
- **Surviving mutants:** two survive, and both are equivalent: the prefix guard is implied by the chunk comparison, and widths above l+1 cannot match single-spaced text.
- `clients-test.sh` 9/9, `bash -n` and shellcheck pass.

**4. Independent review (Sonnet).**
- The review found no blockers.
- It found five should-fix defects, all fixed:
  - pane 2 could win the input lease;
  - an inconclusive A5 could hide an unavailable sandbox;
  - "already deleted" could pass A7b;
  - there was no live-state capture before a stop;
  - a failed unwrapped read discarded a good match.
- Six minor items were fixed.
- **Verified against v0.1.9 source:**
  - the read-only and input-enabled notice texts (`crates/openshell-supervisor-process/src/ssh.rs:862`, `:1024`);
  - forwarding of the triggering keystroke, and discard of read-only input;
  - lease release on channel close or connection drop;
  - the CLI's 60 s reconnect window and its retryable errors (`crates/openshell-cli/src/ssh.rs`);
  - graceful shutdown stops the sandboxes without changing the persisted phase (`compute/mod.rs:4133-4138`);
  - startup recovery restarts both containers when the gateway mints sandbox JWTs (`driver-podman/src/driver.rs:2069-2078`); run 3's gateway logged "gateway-minted sandbox JWT enabled";
  - the delete output, and the post-delete `sandbox not found` error.

**Source predictions (not results):**
- A5a: `restarted`.
- A5b: `restarted` (JWT enabled).
- A supervising CLI that sees FailedPrecondition "sandbox is not ready" while reconnecting exits, because that error is not retryable.

## Run 3: 1123-122157 (owner-authorized third attempt) — A1–A4a PASS, A4b recorded FAIL (harness), stopped

### Identity

| Item | Value |
|---|---|
| Run id / time | `1123-122157`. Harness 2026-11-23T17:24:39Z to cleanup start 17:25:56Z (t+77 s), final verification 17:26:06Z; exit 1. 30-minute budget not approached |
| Harness | `demo.sh` at commit `b09789b4e8bac5faa6f4bbe9a1e939f90dcc09d6`, sha256 `ecd188ad…1ba7a`. Base: reviewed commit `0cadef7` plus the A4 adjustment below |
| Host / software | Fedora 44, kernel 7.3.4-200.fc44, cgroup v2, Landlock ABI 11, seccomp `user_notif`. Podman 5.8.9 (dedicated service). Herdr 0.9.5 `32f81aa0…affc66`. OpenShell CLI 0.1.9 `2db8e54f…7e69` and gateway 0.1.9 `865e8c5a…3978` (tarballs `3856ac7b…bd2d`, `c32085d6…c6a3`). Same pinned sandbox `e57d07cd…866f`, supervisor `f1ec231b…99d3` and workload `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d0…7a16` as runs 1–2 ([versions.txt](evidence/1123-122157/versions.txt)) |
| Fresh preflight | New run root and port (25319). P1 host checks pass; new B0. P2: tag `v0.1.9` → `ce58cf8e`; tarball checksums match; `--owner NVIDIA` attestations verify (signer `release-publish.yml@refs/heads/main`, run 44149201744, cert commit `624aceea`); promote job log `SOURCE_SHA: ce58cf8e…`; binary sha256 match; help texts byte-identical to run 2 except an example IP that run 2's copy shows redacted; registry tags resolve to the pinned digests. Two preflight-script FAIL lines are explained in [preflight.txt](evidence/1123-122157/preflight.txt) (a redaction artefact, and a `gh run view --log` fetch that returned nothing; re-fetched through the jobs API) |

### A4 adjustment (owner-authorized for run 3; commit `b09789b`)

- **Recording.** A client process that outlives the Herdr server is recorded, not an automatic A4 failure. After the server is gone, two scans are written to `obs/a4<id>-clients.txt`: one after up to 10 s for clients to end, one after counter progress. Each scan records:
  - class, pid:start, ppid, state and fd0;
  - role: supervising CLI with or without a transport child, or SSH transport with a proxy and its gateway TCP sessions;
  - whether the original connection can still take input (its terminal's ptmx-master holders, named; a heuristic).

  The counter tail while Herdr is down is also saved, as is whether the new pane showed a read-only notice.
- **"Zero clients" claims.** One is made only if both scans found none and the counter advanced between them.
- **PASS** rests on PLAN's criteria: same identity, progress while Herdr is down, and a new pane's ACK with the same identity.
- **Survivors** are never signalled during the test. The run stops in any of these cases:
  - a survivor may have blocked the new pane;
  - survivors outside the new chain remain 75 s after reattach;
  - the A4 ACK fails;
  - a Herdr stop or restart fails.
- **Stop alignment** with the authorization's stop conditions: an attach failure in A3 or A6 now stops the run instead of continuing.
- **Review and checks.** An independent review (Sonnet) found two minor defects: an rc misreport in A3, and an over-claimed "capable of input". Both were fixed before commit. `bash -n`, shellcheck and the 9 offline client-detection tests (including the run-2 glob regression) pass.

### Results

| Step | Result | Observation |
|---|---|---|
| P3 | PASS | All 18 checks ([obs/p3-checks.txt](evidence/1123-122157/obs/p3-checks.txt)). The healthcheck probe matched run 2: `Health` null at 1 s and 12 s, no healthcheck units, no `$XDG_RUNTIME_DIR/systemd`. Orchestrator gate decision `proceed` (FIND-077 scope) |
| A1 | **PASS** | Ready about 1 s after create. `ACK a1` (n=5) in the log and the pane. The client chain was found and stayed up through the ACK. The counter's ancestors include no herdr, ssh or CLI process. The transport ssh has no agent-like unix peer |
| A2 | **PASS** | Pane closed. The pane's chain was gone and no CLI, ssh or proxy remained. Phase Ready, identity unchanged, n 6→11 with no client |
| A3 | **PASS** | A new pane reattached. Replay was visible (tick 1 shown after connecting at n=12). `ACK a3` at n=13, same identity |
| A4a (clean) | **PASS** | Server stop. Both scans: zero client processes, n 18→20 between them. Identity unchanged; n 16→20 while Herdr was down. Herdr restored the one earlier pane as a plain shell with no client (A4b: two). A new pane got `ACK a4a` n=25 |
| A4b (SIGKILL) | **FAIL (recorded) → STOP** | Identity unchanged; n advanced while Herdr was down; both scans zero (n 31→33). In the new pane, `mark` returned 0: the ACK was in the log and Herdr's `wait-output` matched `ACK a4b pid=52`. `verify_ack` then failed on its exact-line grep of the pane capture, because the line wrapped: `ACK a4b pid=52 start=434236` / `22 nonce=fdf5d2b339358279 n` / `=38` ([panes/a4b.txt](evidence/1123-122157/panes/a4b.txt)). The log line is exact: `ACK a4b pid=52 start=43423622 nonce=fdf5d2b339358279 n=38`. The new stop rule applied |
| A5a, A5b, A6, A7a, A7b | **not run** | Stopped after A4b |

**Identity throughout A1–A4b (all equal; [obs/](evidence/1123-122157/obs/)):**
- (i) counter `pid=52 start=43423622 nonce=fdf5d2b339358279`;
- (ii) `main_process_instance_id=94eb529c-993e-4cb4-98a9-9ceef48fa78e`, `main_process_started_at_ms=1795454716668`, `restart_count` 0;
- (iii) host PID 1564241 with `/proc` start 43423622.

The full counter log runs n=1…41 with no gap or reset, with four ACKs ([out/counter-final-full.log](evidence/1123-122157/out/counter-final-full.log)).

**Client process chain (observed):**
- A1: CLI `1565134` → `/usr/bin/ssh -F <run>/ssh_config -o IdentityAgent=none …` `1565254` → `<cli> ssh-proxy --gateway https://127.0.0.1:25319 --sandbox exp008-1123-122157 …` `1565262`, all in the pane shell's session ([snaps/01-a1-attached.txt](evidence/1123-122157/snaps/01-a1-attached.txt)).
- At the end of each A4 step, the new chain was the only client. Its proxy had one established TCP session to the gateway, and its stdin was a pipe; the CLI's and ssh's stdin was the pane pty.
- The gateway log shows `CreateSshSession` and `relay opened successfully` per attach.

**A4 client-lifecycle observations ([a4a](evidence/1123-122157/obs/a4a-clients.txt), [a4b](evidence/1123-122157/obs/a4b-clients.txt)):**
- **Control before each stop.** The original CLI's fd0 was a pts whose single ptmx-master holder was the Herdr server, which shows the holder probe works.
- **After the clean stop and after the SIGKILL, the result was the same:**
  - Scan 1 was taken with 0 s of waiting and counted cli=0 transport=0 proxy=0 run-ssh=0.
  - The original connection was "ended (cli, ssh and proxy all gone); capable of input: no".
  - Scan 2, 2–3 s later and after counter progress, was also zero.
- **What this means.** No surviving supervising CLI, SSH transport or proxy was observed, so nothing could have blocked or interfered with the new pane, and no "read-only" notice appeared. The counter progressed with zero clients, as verified by those two scans. Clients that might have started and ended between the scans would not have been seen.

**Cleanup.**
- Intermediate RESIDUE ([cleanup.txt](evidence/1123-122157/cleanup.txt)): the in-namespace store removal again hit `rm: cannot remove '…/podman/root/overlay': Device or resource busy`, and two `catatonit` pause processes were swept.
- Final ([cleanup-final.txt](evidence/1123-122157/cleanup-final.txt)): the run root is absent; all 12 recorded and swept processes are gone; no run markers, sockets or mounts remain; port 25319 is closed.
- Protected baselines are identical: final vs B1 for 6 listings, and final vs B0 for 4. These cover OpenShell config/state metadata, `~/.ssh` metadata, TCP listeners, the default Podman store, and the user systemd `libpod*`/`podman*` units.
- Classification: **CLEAN**.
- Post-run evidence scan: no key material, JWT, token, home path, hostname or non-loopback IP.

### Harness defect found (not corrected; no further run authorized)

`verify_ack` requires the exact ACK line in the pane capture (`grep "ACK <w> pid=… start=… nonce=…" panes/<w>.txt`). `pane_attach` splits an existing pane for each new pane, and Herdr restores the earlier panes after each restart, so by A4b the new pane was narrow. A minimal fix would be either of these:
- join the pane's wrapped lines before matching;
- create each new pane in a fresh workspace instead of splitting.

The ACK identity check against the counter log is unaffected. This is proposed only.

### Assumptions (run 3)

| Assumption | Status |
|---|---|
| The corrected client detection recognises a real attach | **Confirmed** (A1, A3, A4a, A4b chains found; A2 chain gone) |
| `sandbox connect` keeps the CLI and spawns ssh, which runs the proxy (FIND-080) | **Observed** in process snapshots (FIND-080 stays proposed for owner review) |
| The main process survives pane close and Herdr clean/forced restart, and a new pane reattaches with replay and input | **Observed** once each (FIND-081, proposed); the A4b pane check is recorded FAIL by the wrap defect |
| A client chain may outlive the Herdr server | **Not observed**: it ended at once in both cases (FIND-082, proposed) |
| Gateway restart replaces the main process (source reading) | **Not tested** (A5 not run) |
| Single writer and read-only viewers; retention and delete | **Not tested** (A6, A7 not run) |

## Run 2: 1123-072024 (owner-authorized retry) — stopped at A1 attach

### Identity

| Item | Value |
|---|---|
| Run id / time | `1123-072024`; harness start about 2026-11-23T12:29:25Z (first log line 12:29:26Z); A1 stop at 12:30:38Z (about t+73 s, including a 30 s decision-gate wait); exit 1 |
| Harness | `demo.sh` at commit `e7a5715`, sha256 `bca278df…f759ac` (diff from run 1: the three authorized corrections only) |
| Host / software | Same as run 1 (identity table below): Fedora 44, kernel 7.3.4-200.fc44, Podman 5.8.9 (dedicated service, `cgroup_manager=systemd`), Herdr 0.9.5 `32f81aa0…affc66`, OpenShell CLI and gateway 0.1.9 (same tarball and binary sha256), same pinned sandbox, supervisor and workload image digests |
| Fresh preflight | New run root and port. P1 host checks pass (cgroup v2, Landlock ABI 11, `user_notif`, user bus). New B0 taken. P2: tag `v0.1.9` resolves to `ce58cf8e`; tarball sha256 and checksum files match; `--owner NVIDIA` attestations verify (same signer and run 44149201744); the promote-job log shows `SOURCE_SHA: ce58cf8e…`; binary sha256 match; `create --help` semantics unchanged; registry tags still resolve to the pinned digests ([p2/](evidence/1123-072024/p2/)) |

### Corrections applied (authorized; nothing else changed)

1. **`DISABLE_HC_SYSTEMD=true`** was set only on the dedicated `podman system service` and on the harness's own `podman` calls (the `P` wrapper and the `podman unshare` calls).
   - P3 verified it in the effective environment of both the launched service and its re-executed listener ([obs/p3-service-env.txt](evidence/1123-072024/obs/p3-service-env.txt)).
2. **P3 healthcheck probe** ([obs/p3-hc-health.txt](evidence/1123-072024/obs/p3-hc-health.txt)).
   - **Method:** create and start through the dedicated socket, over libpod `v5.0.0` (as the driver does), with healthconfig `{"Test":["NONE"],"Interval":10000000000,"Timeout":2000000000,"Retries":10,"StartPeriod":5000000000}`. Podman stored the config exactly so.
   - **Health:** the container ran, and `State.Health` was `null` at 1 s and at 12 s (after the start period and one interval). Podman v5.8.9 source explains this: `HasHealthCheck()` is false for `NONE`, so inspect omits Health (`libpod/container.go:1319-1334`, `container_inspect.go:195-206`).
   - **Timers:** no healthcheck timer or service unit, no transient non-scope file, no healthcheck line in the service log, and no `$XDG_RUNTIME_DIR/systemd`.
   - **Units:** only the two pre-registered cgroup scopes (`libpod-*.scope`) appeared. After removal, no container, volume or unit with the probe's ID remained, and the owner's unit files were unchanged.
   - **Decision gate:** before A1, Sonnet assessed this result against OpenShell's Ready logic and recommended **proceed**.
     - OpenShell's Podman driver reports `driver_reports_runtime_readiness: false` (`driver.rs:728`).
     - Ready is set only when the supervisor session connects (`openshell-server/src/compute/mod.rs:8069-8076`).
     - A null health maps to `ContainerRunning` (`watcher.rs:537-552`).
     - Only `unhealthy` would block Ready.

     The orchestrator wrote `proceed` at t+50 s.
3. **Cleanup classification from the verified final state.** After run-root removal, a detection-only check runs. It looks for:
   - recorded and swept PIDs;
   - any process carrying the run's environment or argv markers;
   - unix sockets and mounts under the run root;
   - the port.

   It also recomputes the protected baselines against in-memory B1/B0 hashes. Intermediate notes stay in `cleanup.txt`.

### P3: all 18 checks passed

These are the 16 checks from run 1, plus the healthcheck probe and the readiness gate ([obs/p3-checks.txt](evidence/1123-072024/obs/p3-checks.txt)).

### A1 (observed): FAIL at pane attach → stop

- **Create and Ready (observed):**
  - `sandbox create --detach --tty … -- /usr/local/bin/counter.sh /sandbox/out` printed `Created sandbox: exp008-1123-072024`.
  - The sandbox was **Ready** about 1.1 s after create. Condition: `Ready=True, DependenciesReady, "Supervisor session connected"`. `restart_count` was 0.
  - The supervisor-to-gateway session over loopback mTLS was accepted at 12:30:17.729Z. This was a remaining risk after run 1, and it is now exercised.
- **Canonical main process identity at A1 (observed; [obs/a1-identity.txt](evidence/1123-072024/obs/a1-identity.txt)):**

  | Source | Value |
  |---|---|
  | (i) counter's identity file | `pid=52`, `start=41653728`, `nonce=166b0dafa48e8be7` |
  | (ii) OpenShell | `main_process_instance_id=1c8ae6af-20d8-41d4-aa07-2410b9ca2f5a`, `main_process_started_at_ms=1795437017729` |
  | (iii) host | PID `1405673` (a descendant of the workload container's `State.Pid`), `NSpid` 52, `/proc` start `41653728` (equal to the counter's own) |

  - Host process start, in ms from btime and ticks: `1795437017280`. OpenShell's `started_at_ms` is 449 ms later.
  - The counter's first `COUNT` was at `1795437017.73`.
  - The counter ran without interruption, `n=1…21`, until cleanup ([out/counter-final-full.log](evidence/1123-072024/out/counter-final-full.log)).
  - The main process is `counter.sh` launched by the sandbox, not a `sandbox exec` process.
- **Pane attach (observed and source):**
  - **Observed:** the harness opened a Herdr pane and ran the wrapped `openshell -g … sandbox connect …`.
  - **Observed:** the gateway logged `CreateSshSession` at 12:30:18.662Z and an **allowed** `ForwardTcp` with `ssh_session_token` at 12:30:18.713Z, both from 127.0.0.1.
  - **Observed:** the gateway then logged `relay opened successfully` and a claimed `RelayStream` at 12:30:18.714Z. The `ForwardTcp` stayed open until cleanup cancelled it at 12:30:38.308Z.
  - **Observed:** the connect reached the gateway. The harness's `clients_ge 1`, which looks for processes whose exe is the run's `openshell` binary with `sandbox connect` in argv, saw none within 20 s, and A1 recorded "could not attach a pane". The plan's unexpected-failure stop applied, and A2–A7 were not run.
  - **Cause (harness defect, reproduced offline):** `clients_pids()` tested `case " ${a[*]} " in *" sandbox "*" connect "*`. For the real argv `… -g exp008-<run> sandbox connect exp008-<run>`, the space between the adjacent words is consumed by `" sandbox "`, so `" connect "` cannot match. The predicate was false for every possible connect process; the exe and environment conditions were never the deciding factor. [tests/clients-test.sh](tests/clients-test.sh) case 2 reproduces this.
  - **Corrected diagnosis (2026-11-23):** the first diagnosis, that `connect` exec-replaces itself with `ssh` on a TTY, was wrong. In v0.1.9, `sandbox connect` keeps the CLI and spawns ssh as its child (FIND-080, revised).
  - **Inferred from source, not observed:** the pane held the supervising CLI, its wrapped `/usr/bin/ssh` child and an `ssh-proxy` grandchild.
  - **Not observed:** no pane content was captured, and `mark a1` was never typed, so attach, replay and `ACK a1` are unobserved.
- **Not run:** A2, A3, A4a, A4b, A5a, A5b, A6, A7a, A7b. There are therefore **no identity comparisons across lifecycle events**, and there is **no A5 graceful or crash classification**.

### Cleanup: CLEAN (verified final state); intermediate RESIDUE recorded

- **Intermediate** ([cleanup.txt](evidence/1123-072024/cleanup.txt), [obs/cleanup-store.out](evidence/1123-072024/obs/cleanup-store.out)):
  - The sandbox was deleted through the gateway (`deletion accepted`, then `sandbox not found`).
  - The gateway, the Podman service and listener, two `catatonit` pause processes, the Herdr server, the create CLI, the container main process and the counter were verified gone by PID and start time.
  - The in-namespace store removal again failed with `rm: cannot remove '…/podman/root/overlay': Device or resource busy`. Store paths were still present, so the intermediate classification was **RESIDUE**. Those notes are preserved.
- **Final** ([cleanup-final.txt](evidence/1123-072024/cleanup-final.txt), [final-status.txt](evidence/1123-072024/final-status.txt)):
  - The run root is absent.
  - All 10 recorded and swept processes are gone.
  - No process carries the run's markers.
  - There is no unix socket and no mount under the run root.
  - The port is closed.
  - B1 comparison: all six protected listings are identical.
  - B0 comparison: all four are identical.
  - **CLEAN.**
- **Independent post-run check (read-only):** `/tmp/hx8` is absent. No process, socket, mount or listener references the run. The evidence scan found no home path, hostname, key material, JWT, token or non-loopback IP.

### Assumptions (run 2)

| Assumption | Status |
|---|---|
| `DISABLE_HC_SYSTEMD=true` on the dedicated service avoids the run-1 failure without touching the owner's systemd | **Confirmed** (probe and real sandbox) |
| A NONE healthcheck leaves the sandbox able to reach Ready | **Confirmed** (Ready in about 1.1 s) |
| The supervisor (host network) reaches a 127.0.0.1 mTLS gateway | **Confirmed** |
| The canonical main process is the `--` command, identifiable by three independent sources | **Confirmed** at A1 (one sample) |
| `sandbox connect` stays an `openshell` process while attached (implicit in the harness) | **Supported by source** (FIND-080, revised); not yet observed. An earlier version of this table said "Disproved"; that was wrong |
| The harness's attach predicate can recognise a connect process | **Disproved**: an argv-glob defect made it always false (reproduced offline) |
| Reattach, replay, single writer, gateway-restart, retention and delete semantics | **Not tested** |

### Correction after run 2: client detection (owner-authorized harness and documentation change; **not run**)

An earlier version of this section proposed counting the wrapped `ssh` as the attachment, on the grounds that `connect` exec-replaces itself. That rationale was wrong (FIND-080, revised), and the proposal was not applied as written. The owner's review of 2026-11-23 authorized the correction below, but not a run. A third local execution needs separate authorization.

- **Process model (source):** one attached client is a chain of three processes: the supervising CLI `-g <gw> sandbox connect <gw>` → transport `/usr/bin/ssh -F <run>/ssh_config … -s sandbox openshell-main`, whose ProxyCommand names this run's CLI, the loopback gateway port and the sandbox → `<cli> ssh-proxy --gateway https://127.0.0.1:<port> --sandbox <gw> …`. Each process must have the run's `XDG_CONFIG_HOME`. Anything else is `other`, which covers the create CLI, a CLI without the run environment and unrelated ssh or openshell processes. Any other ssh that uses the run's ssh_config is `run-ssh` and counts as a client process. Exact argv positions are compared, not globs.
- **Matching to the pane:** `pane_attach` records a **new** complete chain whose CLI descends from the pane's shell. The shell pid comes from `herdr pane process-info`; its output format is evidenced in EXP-006 for restored panes. The chain is recorded as pid:start-time triples per pane.
- **Privacy:** unrelated processes are counted only. Their argv is never kept and their environ is never read. The ssh and proxy argv carry `--token`, and every new evidence writer passes through `redact`.
- **Primary versus corroborating evidence:** A1 still passes only on the PLAN criterion, `ACK a1` in the log and the pane with the recorded identity. The chain must also be found and must stay alive through the ACK. If no chain is found, A1 writes `obs/attach-a1.txt` before failing. The file contains:
  - the class counts and run-scoped processes;
  - the pane's `process-info`;
  - the process tree under the pane shell, with exe paths and redacted argv;
  - gateway session and relay log lines;
  - the visible and recent pane text;
  - the result of then typing `mark a1` (`mark` rc and ACK line).

  A1 then stops.
- **Client counts reconciled:**
  - "Attached" means a complete chain.
  - "No client remains" means no CLI, transport, proxy or run-ssh process. This applies to A2, A4a/b, `close_all_panes` and the A5b fallback.
  - A2 and A6 also require the closed pane's own recorded chain to be gone, checked by pid and start time.
  - A6 expects two chains, then one, because the read-only viewer has its own chain.
  - A5b records whether the pane's supervising CLI survived the gateway kill. From source, the CLI stays up and respawns ssh. This record is diagnostic only.
  - Cleanup, sweeps and pid-identity guards are unchanged.
- **Tests (offline):** [tests/clients-test.sh](tests/clients-test.sh) extracts the marked client-detection region of `demo.sh` and runs it against fake `/proc` trees. It covers:
  - normal attach;
  - the run-2 glob regression;
  - two clients;
  - a terminated CLI with an orphaned ssh and proxy;
  - lost transport during CLI recovery;
  - the detached state and recycled pids;
  - unrelated ssh, including the owner's own OpenShell connect to another gateway;
  - wrong-scope processes (another port, the create CLI, another sandbox, no run environment);
  - port-prefix collisions.

  Result: 9/9 pass. A mutation check confirmed that the cases detect broken predicates. `bash -n` and shellcheck pass for both files.
- **For the owner (not changed):**
  - The A4a/b check "connect clients survived the server" was always vacuous before, because the CLI count was always 0. It now takes effect, requiring the CLI, ssh and proxy to be gone within 10 s of a Herdr stop or kill.
  - From source this should hold: the PTY hangup and an uncaught SIGHUP should end the chain. But it is a harness condition, not a row in PLAN A4.
  - Decide before a third run whether it stays a FAIL input or becomes a recorded observation. **Decided by the owner before run 3:** a recorded observation (applied in commit `b09789b`; see run 3).

### Remaining risks (inferred)

- From source, both a graceful and a crash gateway restart are still expected to **replace** the main process (A5 would classify as `restarted`).
- The intermediate "Device or resource busy" on overlay removal recurs; final removal succeeds.
- The pane's attach, replay and read-only notices have never been observed.
- **A5b (source reading, not verified):** after a gateway restart, the supervising CLI's new `CreateSshSession` may be refused with FailedPrecondition until the supervisor re-registers. That message does not appear to match `connect_error_is_retryable`'s list (`ssh.rs:516-538`). If so, the CLI exits instead of retrying, which would be recorded as `auto_reattach=no` and is a product observation, not a harness fault.
- `pane_attach` now depends on `herdr pane process-info` returning `shell_pid` for a **fresh** pane. EXP-006 evidence shows the format only for restored panes. If the field is missing, A1 fails with diagnostics; it cannot falsely pass.

## Run 1: 1122-220034 — stopped at A1 (create)

### Identity of the run

| Item | Value |
|---|---|
| Run id / time | `1122-220034`, harness start 2026-11-23T03:57:58Z, stop 03:58:06Z (t+8 s) |
| Harness | `demo.sh` at commit `8102bb8bb281c52780828e573b0d29a215a00aed`, sha256 `794b06ea…ff1b15` |
| Plan | [PLAN.md](PLAN.md) at approved commit `55a4b9e42132224b7036982cf226ea16d77be605` |
| Host | Fedora 44, kernel 7.3.4-200.fc44.x86_64, cgroup v2, Landlock ABI 11, seccomp `user_notif` |
| Podman | 5.8.9 rootless, crun, netavark; dedicated service with `cgroup_manager=systemd` (reported by `podman info`) |
| Herdr | 0.9.5, sha256 `32f81aa0…affc66` (same binary as EXP-006) |
| OpenShell CLI | 0.1.9, `openshell` sha256 `2db8e54f…7e69`, from `openshell-x86_64-unknown-linux-musl.tar.gz` sha256 `3856ac7b…bd2d` |
| OpenShell gateway | 0.1.9, `openshell-gateway` sha256 `865e8c5a…3978`, from `openshell-gateway-x86_64-unknown-linux-gnu.tar.gz` sha256 `c32085d6…c6a3` |
| Runtime images | `ghcr.io/nvidia/openshell/sandbox@sha256:e57d07cd…866f` (amd64 `a22db029…5920`), `ghcr.io/nvidia/openshell/supervisor@sha256:f1ec231b…99d3` (amd64 `e93c39c4…25e5`) |
| Workload image | `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16` (EXP-006 stage 2), reused as approved |

Full values: [evidence/1122-220034/versions.txt](evidence/1122-220034/versions.txt), [p2/](evidence/1122-220034/p2/).

### P1–P3 (observed)

- **P1 host:** rootless Podman 5.8.9, cgroup v2, Landlock ABI 11, `user_notif` present, a free loopback port (not the default 17670). Baseline B0 of protected metadata captured (hashes only in evidence).
- **P2 release:**
  - Both tarballs match `openshell-checksums-sha256.txt` / `openshell-gateway-checksums-sha256.txt`.
  - `gh attestation verify -R ai-openshell/openshell` returns 404. The repository was transferred from `NVIDIA/OpenShell` (same repo id), and the attestations live in the **NVIDIA owner store**: `--owner NVIDIA` verifies both tarballs (SLSA v1 provenance, signer `NVIDIA/OpenShell/.github/workflows/release-publish.yml@refs/heads/main`, run 44149201744).
  - The certificate's source commit is the `main` dispatch commit `624aceea`, not the tag. The link to the tag is the same run's "Select Qualified Prerelease" job log, which records `SOURCE_SHA: ce58cf8e9b953281352d98a637e41616295b1318` and creates `refs/tags/v0.1.9` at that commit ([p2/provenance.txt](evidence/1122-220034/p2/provenance.txt)). `ce58cf8e` is the `v0.1.9` tag commit pinned by PLAN.md.
  - The runtime images have no GitHub attestation under either owner; they are pinned by registry digest only.
  - Release semantics matched the PLAN table: `--detach` ("Start the canonical main process without attaching to it"), explicit `--tty`/`--no-tty`, `--no-keep` (so retention is the default), `--restart-policy` default `never` ([p2/create-help.txt](evidence/1122-220034/p2/create-help.txt)).
- **P3 isolation gate: all 16 checks passed** ([obs/p3-checks.txt](evidence/1122-220034/obs/p3-checks.txt)):
  - **Dedicated Podman:** store, runroot, socket and `XDG_RUNTIME_DIR` all under the run root; `podman info` through the dedicated socket reports them. The dedicated socket listed no containers, volumes, secrets or images while the owner's default store holds some (counts only). The listener on the dedicated socket is the service we started, with no peer connection to the owner's default socket.
  - **Images:** the pinned images were pulled anonymously, with the digests verified.
  - **Probe:** a cgroup-limits probe container (`--memory --cpus --pids-limit`, `--entrypoint /bin/true`) passed.
  - **Gateway:** mTLS certificates were generated in the run root, and `config preflight` passed. The gateway listened only on `127.0.0.1:<port>`; it was registered under a run-local config with `OPENSHELL_SYSTEM_GATEWAY_DIR` pointing at an empty run directory. `status` succeeded over mTLS, and a curl without a client certificate was refused.
  - **SSH:** `ssh -G` through the wrapper showed `identityagent none`, `identityfile none` only, and `userknownhostsfile /dev/null`.
  - **Herdr:** the socket is under the run root; the pane environment resolves `openshell` and `ssh` to the run wrappers, and no controller variables leaked.

### A1 (observed): FAIL → stop

`openshell -g exp008-1122-220034 sandbox create --detach --tty --name … --from <workload digest> --label exp008.run=1122-220034 -- /usr/local/bin/counter.sh /sandbox/out` exited 1 after ~1 s:

```
create sandbox failed: podman API error (500): create healthcheck: unable to get systemd
connection to add healthchecks: lstat <run>/e/run/systemd: no such file or directory
```

The Podman service log shows healthcheck-timer removal errors for two containers ([logs/podman-service.log](evidence/1122-220034/logs/podman-service.log)). PLAN's "unexpected exit code" stop condition applied; the harness went straight to cleanup. **A2, A3, A4a, A4b, A5a, A5b, A6, A7 were not run**, so no identity (counter PID/start/nonce, `main_process_instance_id`/`main_process_started_at_ms`, host PID/start) was ever observed.

### Cause

- **Source-derived (OpenShell v0.1.9):**
  - Every sandbox container's base spec carries a Podman healthconfig with `Interval = 10 s` (`crates/openshell-driver-podman/src/container.rs:1379-1394`).
  - The workload (`:1674`) and the supervisor (`:1806-1816`, when `health_check_interval_secs` is unset) override only `test = ["NONE"]`, so the interval stays 10 s.
  - No TOML key removes it: `health_check_interval_secs = 0` is rejected (`config.rs:805`).
- **Inferred (Podman 5.8.9, from the binary's symbols and error strings; libpod source not read):**
  - At create time, rootless Podman sets up a transient systemd timer for any healthconfig with a nonzero interval, regardless of `test = NONE`. It connects through `$XDG_RUNTIME_DIR/systemd/private`.
  - The run's `XDG_RUNTIME_DIR` was deliberately relocated into the run root, and that path does not exist there.
  - The cgroup manager uses the session bus (which was provided), which is why the P3 probe — which had no healthcheck — passed.
- **The earlier source review got this wrong:** it reported both healthchecks as disabled, because `NONE` replaces only the test and the tests at `container.rs:2205` assert only the test.

### Cleanup: RESIDUE (recorded by the harness); nothing remained after the run

- **Removed:** the sandbox never existed. The gateway, the Podman service and its listener, two rootless pause processes (`catatonit`), the Herdr server, the create CLI and the watchdog were all verified gone, by PID plus start time. Port closed.
- **Recorded residue:** the in-namespace store removal (`podman unshare rm -rf`) failed with `rm: cannot remove '…/podman/root/overlay': Device or resource busy`, so the harness recorded RESIDUE.
- **Root removal:** the subsequent run-root removal succeeded (`final-status.txt`: run root removed: yes).
- **Protected baselines** (B2 against B1, and B2 against B0): identical for
  - `~/.config/openshell` and `~/.local/state/openshell` metadata;
  - `~/.ssh` metadata;
  - TCP listeners;
  - the owner's default Podman containers, volumes, networks, secrets and images;
  - the user systemd `libpod*`/`podman*` units.

  The UDP listener set changed during the run and is reported as INFO. Pre-registered: UDP churn is not classified.
- **Independent post-run check (read-only):** `/tmp/hx8` absent; no process, socket or mount referencing the run; port closed.
- **Classification:** reported as **RESIDUE** because that is what the harness recorded. The residue was transient and is not present now. The harness should re-evaluate store paths after the final root removal (see proposal).

Evidence: [cleanup.txt](evidence/1122-220034/cleanup.txt), [baselines/](evidence/1122-220034/baselines/) (hashes and line counts only), [obs/cleanup-store.out](evidence/1122-220034/obs/cleanup-store.out).

### Pre-registered corrections to PLAN.md (made before the run, source-derived)

1. The start-time field is top-level `main_process_started_at_ms` in `sandbox get -o json`, not `status.main_process_started_time`.
2. `generate-certs` belongs to `openshell-gateway` (`--output-dir`). The CLI imports the bundle via `OPENSHELL_LOCAL_TLS_DIR`. The gateway is given explicit `--tls-cert/--tls-key/--tls-client-ca`, because preflight does not apply local-TLS defaults.
3. The gateway ignores `OPENSHELL_NETWORK_NAME`; the run network is set in a `--config` TOML (`network_name`).
4. The CLI also reads `/etc/openshell` unless `OPENSHELL_SYSTEM_GATEWAY_DIR` is set, so it is pointed at an empty run directory.
5. The dedicated Podman service uses the systemd cgroup manager over the user bus, because the driver applies CPU/memory/pids limits by default. Store, socket, runroot and runtime dir stay isolated, and transient-unit residue is baselined.
6. P3 adds a one-shot cgroup-limits probe of the approved workload image in the dedicated store.
7. **A7b:** no sandbox-scoped network is expected; the gateway-scoped network persists until cleanup. **A5b:** runs with one attached pane to observe auto-reattach. The `/tmp/out` fallback is not exercised, because it would need a second create.
8. Cleanup classification uses the TCP listener set; UDP changes are INFO.

### Assumptions

| Assumption | Status |
|---|---|
| PLAN: GitHub build attestations exist for the tarballs | **Confirmed**, but under the NVIDIA owner store, signed by a `main` workflow; tag linkage via the run log |
| PLAN: `--detach`, `--tty`, retention default, `--restart-policy never` | **Confirmed** (help text only; behaviour not reached) |
| A 127.0.0.1-bound mTLS gateway is usable locally | **Confirmed** for CLI↔gateway. Supervisor↔gateway was not reached |
| A disposable gateway can be isolated from an existing OpenShell install, Podman store and SSH identity | **Confirmed** for P3's checks; protected baselines unchanged |
| OpenShell's Podman driver works against a dedicated rootless Podman service with a relocated `XDG_RUNTIME_DIR` | **Disproved** as configured: it needs healthcheck timers (above) |
| Source review: workload/supervisor have no Podman healthcheck | **Disproved** (interval remains 10 s) |
| Canonical main process, reattach, replay, single-writer, gateway-restart semantics | **Not tested** |

### Findings as proposed after run 1 (current statuses: [Findings](#findings))

- **FIND-077 (proposed, observed + source):** OpenShell v0.1.9's Podman driver gives the workload and supervisor containers a Podman healthconfig with a 10 s interval (test `NONE`). Rootless Podman 5.8.9 therefore needs the user systemd private socket under `$XDG_RUNTIME_DIR` at create time. A dedicated rootless Podman service with a relocated runtime dir cannot create OpenShell sandboxes unless Podman's systemd healthcheck timers are disabled or provided. This matters for any isolated or pod-hosted Podman driver deployment (REQ-011).
- **FIND-078 (proposed, observed):** A disposable OpenShell v0.1.9 gateway can be isolated on a workstation that already has OpenShell registrations, a default rootless Podman store and agent-backed SSH. The ingredients are a dedicated store and socket, a run-local XDG/registry with `OPENSHELL_SYSTEM_GATEWAY_DIR`, a loopback mTLS listener and an agentless ssh wrapper. All protected baselines were unchanged.
- **FIND-079 (proposed, observed):** OpenShell v0.1.9 release provenance must be verified with `gh attestation verify --owner NVIDIA`. The signer is `release-publish.yml@refs/heads/main`, and the build commit is established from the release run's promote job (`SOURCE_SHA`), not from the certificate. Runtime images carry no GitHub attestation.

### Proposed correction after run 1 (approved for the retry; applied in run 1123-072024)

This is the minimum change that addresses the stop, keeping full isolation. It requires a fresh preflight, because the run root, including the verified binaries, was removed.

1. **Disable Podman's systemd healthcheck timers** in the dedicated service only: add `DISABLE_HC_SYSTEMD=true` to the `podman system service` environment (and to the harness's own `podman` CLI calls). Rationale: the `disableHealthCheckSystemd` code path exists in the Podman 5.8.9 binary (inferred behaviour). Nothing is written to the owner's systemd, and the healthchecks are `NONE` anyway.
   - **Rejected alternatives:**
     - Linking `$E/run/systemd` to the owner's systemd would place timers in the owner's user manager, which breaks isolation.
     - Using the real `XDG_RUNTIME_DIR` would share the owner's pause process, rootless netns and auth state.
     - `cgroupfs` does not avoid the timer path.
     - No OpenShell setting exists.
2. **Extend the P3 probe** so this failure class is caught before A1:
   - create a container through the dedicated socket with the driver's exact healthconfig (`test ["NONE"]`, interval 10 s, timeout 2 s, retries 10, start period 5 s);
   - start it and record `State.Health`;
   - remove it;
   - assert no timer lines in the service log and no new user units.

   If `State.Health` stays `starting`, that is a separate A1-readiness risk to report before spending A1.
3. **Cleanup accuracy:** re-check store paths after the final run-root removal, and record the earlier `Device or resource busy` as INFO when nothing remains. This reflects the final state rather than an intermediate one. No change to what is removed.

The minimum next experiment is the same stage A A1–A7 run, unchanged in scope, with items 1–3, as one new authorized attempt.

### Remaining risks for a re-run (inferred)

- `State.Health` for `NONE` healthchecks might read as starting, and the OpenShell watcher (`watcher.rs:385, 537-548`) could then hold the sandbox out of Ready.
- From source, both a graceful and a crash gateway restart are expected to **replace** the main process (A5 would classify as `restarted`).
- Supervisor-to-gateway connectivity over loopback (host-network supervisor) has not yet been exercised.

### Files (run 1)

- [demo.sh](demo.sh) — the harness (as run).
- [evidence/1122-220034/](evidence/1122-220034/), with redaction as follows:
  - `$HOME`, user and hostname are redacted, as are tokens and non-loopback IPs;
  - no keys, certificates, gateway database or raw protected listings are included;
  - post-run scan: no key material, JWTs, tokens, non-loopback IPs or hostname.

## Files (run 3)

- [demo.sh](demo.sh): the harness as run in run 3 (commit `b09789b`).
- [evidence/1123-122157/](evidence/1123-122157/), redacted as in runs 1–2. It also has [preflight.txt](evidence/1123-122157/preflight.txt) and [preflight.sh](evidence/1123-122157/preflight.sh), the orchestrator's P1/P2 script (its repo path line generalised).

## Files (run 2)

- Run 2 used commit `e7a5715` (sha256 `bca278df…f759ac`), and run 1 used commit `8102bb8`.
- [tests/clients-test.sh](tests/clients-test.sh): offline client-detection tests.
- [evidence/1123-072024/](evidence/1123-072024/), redacted as in run 1. It includes `cleanup-final.txt` (verified final state) and the healthcheck-probe records `obs/p3-hc-*.txt`.
