# EXP-008 stage A (local): runs 1122-220034 and 1123-072024 — both stopped at A1

**Result:** two authorized attempts, both **stopped at A1**; A2–A7 have never run. No further attempt is authorized.

- **Run 1 (`1122-220034`)** stopped at `sandbox create` (Podman healthcheck timers need the user systemd socket). Cleanup was recorded as RESIDUE (details unchanged below).
- **Run 2 (`1123-072024`, the owner-authorized retry)**:
  - **The healthcheck correction worked.** The sandbox was created and reached Ready, and the counter ran as the canonical main process, with its identity triangulated.
  - **The run then stopped at A1's pane attach**, because of a harness defect. In a terminal, `openshell sandbox connect` replaces itself with `ssh` via `exec()`, and the harness only counted `openshell … sandbox connect` processes.
  - **Cleanup** is CLEAN on the verified final state. The intermediate RESIDUE notes are kept.

**The research question is still unanswered.**
- Nothing has yet observed the following:
  - reattach and replay through a Herdr pane;
  - survival of pane closure or a Herdr restart;
  - single-writer behaviour;
  - gateway restart;
  - retention and delete.
- None of the three candidate conclusions in [PLAN.md](PLAN.md) can be selected.

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../../docs/experiments/08-openshell-execution.md) · REQ-009, REQ-011 (both remain **Future**) · ADR-0001 unchanged.

## Findings

| ID | Status | Statement (scope) |
|---|---|---|
| FIND-077 | **Proposed, pending validation** (owner, 2026-11-23). Run 2 supports it; recommended for acceptance at the scope stated | OpenShell v0.1.9's Podman driver gives the workload and supervisor a Podman healthconfig with `test ["NONE"]` and a 10 s interval. Rootless Podman 5.8.9 then needs `$XDG_RUNTIME_DIR/systemd/private` when the container starts. Run 1 observed this failure. In run 2, `DISABLE_HC_SYSTEMD=true` in the dedicated service's environment was sufficient: the probe and the real sandbox started with no healthcheck timer unit, and `State.Health` was absent (null). Scope: one workstation, Podman 5.8.9, a relocated runtime dir. REQ-011. |
| FIND-078 | **Accepted** (owner, 2026-11-23) at its documented scope | A disposable OpenShell v0.1.9 gateway can be isolated on a workstation that already has OpenShell registrations, a default rootless Podman store and agent-backed SSH. The ingredients are a dedicated store and socket, a run-local XDG/registry with `OPENSHELL_SYSTEM_GATEWAY_DIR`, a loopback mTLS listener and an agentless ssh wrapper. The protected baselines were unchanged in both runs. |
| FIND-079 | **Accepted** (owner, 2026-11-23) at its documented scope | Verify OpenShell v0.1.9 release provenance with `gh attestation verify --owner NVIDIA`. The signer is `release-publish.yml@refs/heads/main`, and the certificate names the `main` dispatch commit `624aceea`. The build commit `ce58cf8e` comes from the promote job's `SOURCE_SHA`. Runtime images carry no GitHub attestation. Re-verified in run 2's preflight. |
| FIND-080 | **Proposed** (source-verified; consistent with run 2's observations) | When its stdin is a terminal, `openshell sandbox connect` (v0.1.9) **replaces itself with the host `ssh`** via `exec()`: `crates/openshell-cli/src/ssh.rs:241-247`, `exec_or_wait`, on the `sandbox_connect` path. A Herdr pane's attachment is therefore an `ssh … -s sandbox openshell-main` process with a ProxyCommand `openshell ssh-proxy`, not an `openshell` process. Any client accounting or "no client remains" check has to look for that `ssh` process. With no terminal, the CLI spawns `ssh` and waits. |

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
  - **Observed:** the connect reached the gateway. The harness's `clients_ge 1`, which looks for processes whose exe is the run's `openshell` binary with `sandbox connect` in argv, saw none within 20 s, and A1 recorded "could not attach a pane". The plan's unexpected-failure stop applied, and A2–A7 were not run.
  - **Source:** `connect` exec-replaces itself with `ssh` when stdin is a TTY (FIND-080), so the predicate could never be true in a pane.
  - **Inferred, not observed:** the pane then held the wrapped `/usr/bin/ssh`, which the harness's `ssh_pids` would have matched.
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
| `sandbox connect` stays an `openshell` process while attached (implicit in the harness) | **Disproved** for a TTY (FIND-080) |
| Reattach, replay, single writer, gateway-restart, retention and delete semantics | **Not tested** |

### Proposed correction (needs owner approval; not applied; no further run is authorized)

This is the minimum change for a third attempt, with the same scope:

1. Count an attachment as the run's wrapped `/usr/bin/ssh` process: `-F <run>/ssh_config` plus the `openshell-main` subsystem argument. Add the `openshell … sandbox connect` process only for a non-TTY connect, where the CLI spawns `ssh` and waits.
2. Review every call site against this definition: A1 `pane_attach`; A2/A4 "no client remains"; A5b auto-reattach; A6 "two attachments"; and cleanup.
3. On an attach failure, capture a pane read before stopping.

Source (FIND-080) suggests that no other A1–A7 predicate depends on the CLI process staying alive. The proposer should re-check this before approval.

### Remaining risks (inferred)

- From source, both a graceful and a crash gateway restart are still expected to **replace** the main process (A5 would classify as `restarted`).
- The intermediate "Device or resource busy" on overlay removal recurs; final removal succeeds.
- The pane's attach, replay and read-only notices have never been observed.

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

## Files (run 2)

- [demo.sh](demo.sh): the harness as run in run 2 (commit `e7a5715`). Run 1 used commit `8102bb8`.
- [evidence/1123-072024/](evidence/1123-072024/), redacted as in run 1. It includes `cleanup-final.txt` (verified final state) and the healthcheck-probe records `obs/p3-hc-*.txt`.
