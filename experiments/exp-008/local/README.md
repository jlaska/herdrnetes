# EXP-008 stage A (local): run 1122-220034 — stopped at A1

**Result:** the single authorized run **stopped at A1**. P1–P3 passed; `sandbox create` failed inside the isolated Podman service before the canonical main process started, so **A2–A7 were not run**. No second attempt was made (not authorized). Cleanup removed everything; the harness recorded **RESIDUE** for a transient store-removal error (details below), and an independent post-run check found nothing left.

**The research question is unanswered.** Nothing in this run observed OpenShell's canonical-main-process, reattach, multi-attach, retention or gateway-restart behaviour. None of the three candidate conclusions in [PLAN.md](PLAN.md) can be selected.

Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) · [EXP-008](../../../docs/experiments/08-openshell-execution.md) · REQ-009, REQ-011 (both remain **Future**) · ADR-0001 unchanged.

## Identity of the run

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

## P1–P3 (observed)

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

## A1 (observed): FAIL → stop

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

## Cleanup: RESIDUE (recorded by the harness); nothing remained after the run

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

## Pre-registered corrections to PLAN.md (made before the run, source-derived)

1. The start-time field is top-level `main_process_started_at_ms` in `sandbox get -o json`, not `status.main_process_started_time`.
2. `generate-certs` belongs to `openshell-gateway` (`--output-dir`). The CLI imports the bundle via `OPENSHELL_LOCAL_TLS_DIR`. The gateway is given explicit `--tls-cert/--tls-key/--tls-client-ca`, because preflight does not apply local-TLS defaults.
3. The gateway ignores `OPENSHELL_NETWORK_NAME`; the run network is set in a `--config` TOML (`network_name`).
4. The CLI also reads `/etc/openshell` unless `OPENSHELL_SYSTEM_GATEWAY_DIR` is set, so it is pointed at an empty run directory.
5. The dedicated Podman service uses the systemd cgroup manager over the user bus, because the driver applies CPU/memory/pids limits by default. Store, socket, runroot and runtime dir stay isolated, and transient-unit residue is baselined.
6. P3 adds a one-shot cgroup-limits probe of the approved workload image in the dedicated store.
7. **A7b:** no sandbox-scoped network is expected; the gateway-scoped network persists until cleanup. **A5b:** runs with one attached pane to observe auto-reattach. The `/tmp/out` fallback is not exercised, because it would need a second create.
8. Cleanup classification uses the TCP listener set; UDP changes are INFO.

## Assumptions

| Assumption | Status |
|---|---|
| PLAN: GitHub build attestations exist for the tarballs | **Confirmed**, but under the NVIDIA owner store, signed by a `main` workflow; tag linkage via the run log |
| PLAN: `--detach`, `--tty`, retention default, `--restart-policy never` | **Confirmed** (help text only; behaviour not reached) |
| A 127.0.0.1-bound mTLS gateway is usable locally | **Confirmed** for CLI↔gateway. Supervisor↔gateway was not reached |
| A disposable gateway can be isolated from an existing OpenShell install, Podman store and SSH identity | **Confirmed** for P3's checks; protected baselines unchanged |
| OpenShell's Podman driver works against a dedicated rootless Podman service with a relocated `XDG_RUNTIME_DIR` | **Disproved** as configured: it needs healthcheck timers (above) |
| Source review: workload/supervisor have no Podman healthcheck | **Disproved** (interval remains 10 s) |
| Canonical main process, reattach, replay, single-writer, gateway-restart semantics | **Not tested** |

## Proposed findings (for owner review; not accepted)

- **FIND-077 (proposed, observed + source):** OpenShell v0.1.9's Podman driver gives the workload and supervisor containers a Podman healthconfig with a 10 s interval (test `NONE`). Rootless Podman 5.8.9 therefore needs the user systemd private socket under `$XDG_RUNTIME_DIR` at create time. A dedicated rootless Podman service with a relocated runtime dir cannot create OpenShell sandboxes unless Podman's systemd healthcheck timers are disabled or provided. This matters for any isolated or pod-hosted Podman driver deployment (REQ-011).
- **FIND-078 (proposed, observed):** A disposable OpenShell v0.1.9 gateway can be isolated on a workstation that already has OpenShell registrations, a default rootless Podman store and agent-backed SSH. The ingredients are a dedicated store and socket, a run-local XDG/registry with `OPENSHELL_SYSTEM_GATEWAY_DIR`, a loopback mTLS listener and an agentless ssh wrapper. All protected baselines were unchanged.
- **FIND-079 (proposed, observed):** OpenShell v0.1.9 release provenance must be verified with `gh attestation verify --owner NVIDIA`. The signer is `release-publish.yml@refs/heads/main`, and the build commit is established from the release run's promote job (`SOURCE_SHA`), not from the certificate. Runtime images carry no GitHub attestation.

## Proposed correction (needs owner approval before any re-run)

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

## Remaining risks for a re-run (inferred)

- `State.Health` for `NONE` healthchecks might read as starting, and the OpenShell watcher (`watcher.rs:385, 537-548`) could then hold the sandbox out of Ready.
- From source, both a graceful and a crash gateway restart are expected to **replace** the main process (A5 would classify as `restarted`).
- Supervisor-to-gateway connectivity over loopback (host-network supervisor) has not yet been exercised.

## Files

- [demo.sh](demo.sh) — the harness (as run).
- [evidence/1122-220034/](evidence/1122-220034/), with redaction as follows:
  - `$HOME`, user and hostname are redacted, as are tokens and non-loopback IPs;
  - no keys, certificates, gateway database or raw protected listings are included;
  - post-run scan: no key material, JWTs, tokens, non-loopback IPs or hostname.
