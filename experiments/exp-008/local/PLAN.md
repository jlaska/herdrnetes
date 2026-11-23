# EXP-008 stage A: local execution plan (NOT RUN; for owner review)

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · plan record [08-openshell-execution.md](../../../docs/experiments/08-openshell-execution.md) · REQ-009, REQ-011 · follows EXP-006 FIND-071/074/076 · ADR-0001 unchanged

**Status.** This is a plan only. Nothing has been downloaded, installed, created or run. Running it needs owner approval of this plan at an exact commit. Until then the harness script (below) is not written.

**Question.** Can an OpenShell sandbox's canonical main process take over the role tmux played in EXP-006? That means a process that survives Herdr pane closure and Herdr restart, which a new pane reattaches to with `openshell sandbox connect`. A second question: what does an OpenShell gateway restart do to that process?

**Hypothesis.** Herdr is a disposable client, the OpenShell gateway owns the session, and the sandbox holds the process. This is not an adopted architecture.

## What the release says (v0.1.9, read from source and docs, not yet executed)

The sources are tag `v0.1.9` (`ce58cf8e9b953281352d98a637e41616295b1318`, 2026-11-17), now published from `ai-openshell/openshell`. Paths are relative to that tree. Stage A step P2 confirms each item against the downloaded binaries before any test.

| Item | v0.1.9 behaviour | Source |
|---|---|---|
| Canonical main process | The trailing `-- cmd` of `sandbox create` runs as the sandbox user under `openshell-sandbox` (PID 1 of the workload container). It is not shell-parsed. `sandbox exec` starts a separate process in the same PID namespace. | docs `how-it-works/sandboxes/overview.mdx`; `crates/openshell-driver-podman/README.md` |
| `--detach` | Starts the main process without attaching. The CLI returns. | `crates/openshell-cli/src/main.rs` (`SandboxCommands::Create`), `run.rs` |
| Retention | Kept by default (`--keep` is deprecated). `--no-keep` marks the sandbox ephemeral, and the gateway deletes it after the main process exits. | `overview.mdx`; `compute/mod.rs` |
| Restart policy | `--restart-policy never` (default), `on-failure` or `always`. A restart launches a fresh main process (backoff 1 s to 3 min) and restores no memory. | `overview.mdx` |
| PTY | Present only if `tty` is set at create. It is auto-detected from the creating CLI's terminal, so a scripted detached create needs an explicit `--tty`. `connect` honours the stored value. | `run.rs`, `ssh.rs` |
| `connect` | Runs the host `ssh` with `ProxyCommand openshell ssh-proxy` to the main session. Replay is 1 MiB. Ctrl-D always detaches and is never forwarded; Ctrl-P Ctrl-Q also detaches. Auto-reattach lasts 60 s after a transport failure. | `ssh.rs`; `supervisor-process/src/main_session.rs`, `ssh.rs` |
| Multiple clients | The first attachment owns input, and later ones are read-only (keystrokes discarded). A viewer gains input after the owner releases it, on its next keystroke. There is no takeover. | `supervisor-process/src/ssh.rs`, `main_session.rs` |
| Identity fields | `sandbox get -o json` has `status.main_process_instance_id` and `main_process_started_time`, but no PID field. | `proto/openshell.proto` |
| Gateway restart | Docs say only that a sandbox may return to Provisioning while its supervisor reconnects. Source suggests that a graceful shutdown stops the Podman sandboxes and relaunches them on start, and that after a crash the startup recovery restarts both containers. **Either way the main process would be replaced.** This is unconfirmed. | `compute/mod.rs` (`stop_persisted_sandboxes_on_shutdown`, `start_persisted_sandboxes`), `driver-podman/src/driver.rs` |
| Supervisor loss | The workload is frozen, then terminated after 30 s by default (range 10–300 s). | `sandbox-backend/src/boundary_protocol.rs`; docs `about/architecture.mdx` |
| Delete | May be asynchronous (`ACCEPTED`, then poll). Each sandbox gets a workload container, a supervisor container, channel/control/workspace volumes and several Podman secrets, all labelled `openshell.*`. | `driver-podman/README.md`, `container.rs`, `isolation.rs` |
| Other termination | No idle timeout or TTL was found. Main-process exit gives `Completed` or `Error` (retained unless `--no-keep`). Graceful gateway shutdown stops the sandboxes. On host reboot, recovery depends on the gateway starting. | as above |
| Host requirements | Rootless Podman 5 with cgroups v2, Landlock ABI ≥ 3, seccomp user-notify. Checked at launch, fail closed. | docs `about/support-matrix.mdx` |

Workstation, read-only checks on 2026-11-22:
- Fedora 44, Linux 7.3.4, with `landlock` in the active LSM list.
- Podman 5.8.9, rootless, cgroups v2.
- Herdr 0.9.5. `openshell` is not on `PATH`.

## Isolation from the existing OpenShell setup

The workstation already has OpenShell state:
- `~/.config/openshell` holds two gateway registrations, one of them remote with an OIDC token, plus an active-gateway selection.
- `~/.local/state/openshell` holds a gateway database.

The plan must not read, use or change any of it. It also must not touch the owner's SSH or GPG agents.

1. **Run root.** Everything lives under `/tmp/hx8/<run-id>`: binaries, `HOME`, and `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_DATA_HOME` and `XDG_RUNTIME_DIR`. Every command runs under `env -i` with an allowlist, as in EXP-006 `local/demo.sh`. There is no `SSH_AUTH_SOCK`, no `GNUPGHOME`, no `OPENSHELL_*` from the caller, and no `HERDR_*`. `generate-certs` writes its client bundle under `$XDG_CONFIG_HOME/openshell/...`; with the isolated `XDG_CONFIG_HOME` that is inside the run root.
2. **Dedicated Podman store.** A Podman API service runs from the run root:
   `podman --root <run>/podman/root --runroot <run>/podman/runroot system service --time=0 unix://<run>/podman.sock`.
   The gateway is pointed at it with `OPENSHELL_PODMAN_SOCKET`, and gets a run-specific `OPENSHELL_NETWORK_NAME`. The reason: the v0.1.9 Podman driver lists every `openshell.managed=true` container on its socket, with no per-gateway label, and its admission reconcile could stop containers belonging to another gateway. A separate store means it cannot see the owner's containers at all.
3. **Dedicated gateway.** It runs as a foreground child process of the harness:
   `openshell-gateway --name exp008-<run> --bind-address 127.0.0.1 --port <free port ≠ 17670> --compute-driver podman --db-url <run>/state/...`.
   It uses mTLS from `generate-certs`, inside the isolated config. `--disable-tls` is a documented fallback only, needs owner approval, and stays loopback-only. The CLI is registered with `gateway add ... --local --name exp008-<run>` and selected per command with `-g exp008-<run>`.
4. **SSH client.** `connect` runs the host `ssh`. OpenSSH reads the passwd home's `~/.ssh/config`, not `$HOME`'s, and the owner's config names the YubiKey identity. So the run `PATH` starts with a wrapper `ssh` that runs `/usr/bin/ssh -F <run>/ssh_config -o IdentityAgent=none -o IdentitiesOnly=yes "$@"`. It uses an empty run config and no identity files. P3 verifies this with `ssh -G` and by checking that no harness process opens the agent socket.
5. **Guards.** A wrapper refuses every mutating `openshell` call unless both of these hold:
   - the resolved config directory is inside the run root;
   - the gateway endpoint is `127.0.0.1:<run port>`.

   Mutating `herdr` calls keep EXP-006's run-socket guard.
6. **Baselines.** These are captured before and after the run, and must be identical:
   - a listing (names, sizes, mtimes) of `~/.config/openshell` and `~/.local/state/openshell`;
   - the owner's default-store `podman ps -a`, `volume ls`, `network ls` and `secret ls`;
   - listening TCP ports;
   - `~/.ssh` file mtimes.

## Images and binaries (pinned before the run)

- **CLI and gateway.** The v0.1.9 release tarballs `openshell-x86_64-unknown-linux-musl.tar.gz` and `openshell-gateway-x86_64-unknown-linux-gnu.tar.gz` are downloaded into the run root. Their sha256 is checked against the release checksum files and `gh attestation verify` (GitHub build attestations exist for the tarballs; no GPG or cosign signature was found). The tarballs are not installed system-wide, and there is no systemd service and no `install.sh`.
- **Runtime images.** `ghcr.io/nvidia/openshell/sandbox:0.1.9` and `ghcr.io/nvidia/openshell/supervisor:0.1.9` are resolved to digests before the run and pinned with `OPENSHELL_SANDBOX_RUNTIME_IMAGE` and `OPENSHELL_SUPERVISOR_IMAGE`.
- **Workload image.** This is the existing public EXP-006 stage-2 image, `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16`, so no new build is needed:
  - Debian trixie-slim with bash;
  - non-root user 1000 with a passwd entry;
  - `counter.sh` at `/usr/local/bin`, byte-identical to EXP-006 stage 1.

  OpenShell ignores the image entrypoint, so its sshd and tmux never start. If P2 shows the image is unusable (for example, a missing writable workspace), stop and report; any replacement image needs owner approval.
- **Policy.** The default OpenShell policy applies, with deny-by-default egress and no providers. The counter needs no network access.

## Procedure

Each step records UTC timestamps, exit codes and the outputs named. **Identity** means all three of:
- (i) the counter's own `pid`/`start`/`nonce`, from its `identity` file and its `ACK` lines;
- (ii) OpenShell's `main_process_instance_id` and `main_process_started_time`;
- (iii) the counter's host PID and `/proc` start time.

| Step | Action | Pass |
|---|---|---|
| P1 | Host checks: Podman rootless/cgroups v2, Landlock, free port. Capture baselines. | All present; baselines captured |
| P2 | Fetch and verify the binaries and image digests. Run `openshell --version` and `sandbox create --help`, and confirm that `--detach`, `--tty`, `--no-keep` and `--restart-policy` (default `never`) match the table. | Matches. **Any difference: stop and report before A1.** |
| P3 | Start the dedicated Podman service and gateway, register the gateway, and run `ssh -G` through the wrapper. | Gateway healthy on its port; `identityagent none`; no owner config read |
| A1 | `sandbox create --detach --tty --name exp008-<run> --from <workload digest> --label exp008.run=<run> -- /usr/local/bin/counter.sh /sandbox/out` (falls back to `/tmp/out` if `/sandbox` is not writable, and the fallback is recorded). Then attach a Herdr pane with `openshell -g … sandbox connect exp008-<run>` and type `mark a1`. | `ACK a1` in the pane and the log; identity (i)–(iii) recorded |
| A2 | `herdr pane close` (abrupt). | No `connect`/`ssh` process remains; sandbox Ready; identity unchanged; `n` advances with no client |
| A3 | New pane, `connect`, `mark a3`. | Same identity; replayed output visible; `n` larger than at A2 |
| A4a/b | Attached pane. A4a: `herdr server stop` and start. A4b: `kill -9` of the Herdr server and start. Then a new pane, `connect`, `mark a4a` or `mark a4b`. | Same identity after each; counter progressed while Herdr was down |
| A5a | **Exploratory.** Detached. Stop the gateway gracefully (SIGTERM, wait for exit), sample the containers and counter while it is down, start it again, then `connect` and `mark a5a`. | Classify as **survived** (all of identity (i)–(iii) unchanged), **restarted** (new instance ID or nonce; record the counter-log gap and whether the sandbox reached Ready without action), or **unavailable** (no Ready within 5 min; record phase and conditions). No PID continuity is assumed. |
| A5b | **Exploratory.** As A5a, with SIGKILL of the gateway. Also note whether an attached pane's `connect` auto-reattached within 60 s. | Same classification, recorded separately from A5a |
| A6 | Pane 1 connects, then pane 2 connects. Pane 2 types `mark a6ro`; pane 1 types `mark a6w`. Close pane 1; pane 2 types `mark a6ro2` twice. | Pane 2 shows "attached read-only"; no `ACK a6ro`; `ACK a6w` present; after pane 1 closes, pane 2 gets input ("input enabled") and an `ACK a6ro2` appears; same identity throughout |
| A7 | (a) The A1 creating CLI exited at create time; confirm its PID is gone while the sandbox stays Ready and ticking. (b) `sandbox delete`, then poll `sandbox get` until absent. | (a) Sandbox outlives the CLI. (b) Counter host PID gone; no `openshell*` containers, volumes or secrets and no run network left in the dedicated store |
| C | Stop the gateway and the dedicated Podman service, kill any recorded PIDs still alive, `podman unshare rm -rf` the store, and remove the run root (evidence is copied out first). | No recorded PID alive; port closed; **all P1 baselines identical** → CLEAN, else RESIDUE |

A5 runs after A1–A4 so that a restart cannot hide their result. If A5 replaces the process, the harness records the new identity, which A6 and A7 then use. Other termination conditions are not provoked; they are documented from source, using A5's observation for gateway shutdown.

## Stop conditions

The harness stops and goes straight to C on any of these:
- an unexpected exit code;
- a guard failure;
- a P2 semantic mismatch;
- any attempt to read the owner's OpenShell config, Podman store or SSH/GPG agent;
- a sandbox not Ready within 5 minutes;
- an identity change in A1–A4 (a FAIL; still recorded);
- the run exceeding 30 minutes.

## Evidence

Evidence is committed under `experiments/exp-008/local/evidence/<run>/`:
- versions with sha256 of the binaries and image digests;
- the P2 help excerpts;
- the counter `identity` and `counter.log`;
- pane reads;
- `sandbox get -o json` snapshots, with IDs kept and host paths redacted;
- process snapshots;
- the A5 classification;
- the resource listings for A7;
- the baseline hashes.

No credentials exist in this stage.

## Implementation slice (after plan approval)

One harness script, `experiments/exp-008/local/demo.sh`, adapted from EXP-006 `local/demo.sh`:
- the same env allowlist and Herdr isolation;
- the tmux steps replaced by the OpenShell steps above;
- the `ssh` wrapper and the guard wrapper.

It adds no image, runtime, service, controller or credential. Static checks (`bash -n`, shellcheck) come before review, and the first execution is the approved run.

## Owner decisions needed

1. Approve this plan for one local run at a named commit. That covers downloading the pinned v0.1.9 tarballs and runtime images into the run root, a dedicated Podman store and a loopback gateway.
2. Confirm that reusing the EXP-006 stage-2 image as the workload is acceptable.
3. Fallbacks needing a decision only if P2 or P3 fail: `--disable-tls` on loopback, or a different workload image.
