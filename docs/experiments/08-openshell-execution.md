# EXP-008: OpenShell-owned execution with Herdr as a disposable client

**Status:** Stage A **complete** (four authorized local runs; owner conclusion 2026-11-23). Stage B was executed on 2026-11-24 under owner approval (proposal revision 4, draft PR #42); results and *proposed* FIND-088 to FIND-091 are in [experiments/exp-008/k8s/README.md](../../experiments/exp-008/k8s/README.md). With the Kubernetes driver, the synthetic process survived a graceful gateway restart and an API short-grace gateway termination, while workload-pod loss failed closed. Stage C is deferred. Issue [#39](https://github.com/jlaska/herdrnetes/issues/39) remains the parent tracker. Stage A plan: [PLAN.md](../../experiments/exp-008/local/PLAN.md).

- **Run `1122-220034`** stopped at `sandbox create`: Podman healthcheck timers need the user systemd socket.
- **Run `1123-072024`** stopped at the first pane attach. An argv glob in the attach predicate could never match `sandbox connect` (FIND-080, revised).
- **Run `1123-122157`** (third attempt, with the owner's A4 client-lifecycle adjustment) passed A1, A2, A3 and A4a.
  - The canonical main process kept one identity on all three sources through pane close, reattach with replay, and a clean Herdr restart. It also did so through the SIGKILL Herdr restart.
  - The `connect` client chain ended with the Herdr server both times.
  - A4b is **recorded FAIL**, which stopped the run. The ACK arrived with the correct identity, but it wrapped in a narrow pane, so the harness's exact-line pane check could not match it (a harness defect).
  - A5 (gateway restart), A6 (single writer) and A7 (retention/delete) **did not run**.
  - Cleanup was CLEAN on the verified final state.
- **Run `1123-142020`** (fourth and last attempt, with a reviewed wrap-aware ACK check and the owner-approved order A1 → A6 → A7a → A5a → A5b → A7b) recorded:
  - A1, A6, A7a and A7b PASS;
  - A5a **restarted** and A5b **restarted**.

  Exit 0; cleanup CLEAN.
  - The first attachment owned input. A second client was read-only, its input was discarded, and it gained input after the owner's pane closed.
  - Both a graceful (SIGTERM) and a forced (SIGKILL) gateway restart **replaced the canonical main process**.
    - The graceful stop stopped the containers.
    - After the SIGKILL, the process kept running until gateway startup recovery restarted the containers. `sandbox get` read Ready before the new process ran.
    - The supervising `connect` CLI reattached its pane by itself, but to the new process.
  - A detached sandbox outlived its creating CLI, and an explicit delete removed its resources. Natural completion was not exercised.

Results, findings and proposals: [experiments/exp-008/local/README.md](../../experiments/exp-008/local/README.md).

**Hypothesis (not an adopted architecture).** OpenShell can replace EXP-006's custom tmux/SSH execution ownership. Its gateway would own the agent session's lifecycle, its sandbox would provide policy-based isolation, and Herdr panes would only attach to the session as disposable clients. Production integration is not authorized, and ADR-0001 is unchanged.

**Basis.** EXP-006 showed that a process owned outside Herdr survives Herdr pane closure, Herdr restart and Herdr pod replacement, and that a new pane can reattach to it:
- FIND-071: local;
- FIND-074: Kubernetes, synthetic;
- FIND-076: Kubernetes, real agent.

Reattaching was manual (FIND-072). The OpenShell properties this experiment relies on come from upstream documentation and source and have not been tested here:
- a gateway-owned, detached sandbox lifecycle;
- `sandbox connect` reattaching to the sandbox's canonical main process and PTY;
- egress-substituted credentials.

**Stage A (local only).** A pinned OpenShell release, rootless Podman, a dedicated disposable local gateway, Herdr, and the EXP-006 synthetic counter as the sandbox's canonical main process. No credential, cluster or API spend. Each test records PID, `/proc` start time and nonce:
- **A1–A4:** the same canonical main process and session survive attach, abrupt detach, reconnect, and clean and forced Herdr restart.
- **A5 (exploratory):** gateway restart, graceful versus crash. Record whether the process survives, restarts or becomes unavailable.
- **A6:** one attachment can write; the others are read-only.
- **A7:** a detached, retained sandbox outlives the CLI that created it; explicit deletion removes its resources; any other termination conditions are recorded.

**Later stages (separate approval each).**
- **B:** the Kubernetes driver in a scratch namespace (cluster-scoped Agent Sandbox controller/CRD and gateway RBAC).
- **C:** a real agent with an egress-substituted credential. It covers work through a pane close (the EXP-006 K03 gap) and workload-pod loss, classified as resume rather than continuity.

**Evidence:** [run 1122-220034](../../experiments/exp-008/local/evidence/1122-220034/), [run 1123-072024](../../experiments/exp-008/local/evidence/1123-072024/), [run 1123-122157](../../experiments/exp-008/local/evidence/1123-122157/), [run 1123-142020](../../experiments/exp-008/local/evidence/1123-142020/).
- FIND-077, FIND-078 and FIND-079 are accepted at their stated scopes (FIND-077: observed, single workstation).
- FIND-080, FIND-081 and FIND-082 are accepted (owner, 2026-11-23) at their documented scopes: one local run and one synthetic process.
  - FIND-080: supervised `connect` spawns `ssh`.
  - FIND-081: the main process is independent of Herdr. Run 3's A4b stays recorded FAIL because of the harness wrap defect; its committed evidence shows the correct ACK and an unchanged identity.
  - FIND-082: the client chain ends with the Herdr server.
- FIND-083 to FIND-087 are accepted (owner, 2026-11-23) at their documented scopes: one local run, one synthetic process, OpenShell v0.1.9 with the Podman driver as tested.
  - FIND-083: a graceful gateway restart replaces the main process.
  - FIND-084: a crash restart with JWT minting replaces it at startup recovery, and Ready precedes the new process.
  - FIND-085: supervised client recovery reaches the new process.
  - FIND-086: single writer with read-only viewers.
  - FIND-087: retention and explicit delete.
- **Stage A conclusion (owner, 2026-11-23):**
  - For the tested local configuration, OpenShell provides independent execution ownership, terminal reattachment and single-writer semantics. At that scope it is a viable replacement for EXP-006's custom tmux/SSH-server execution mechanism.
  - OpenShell gateway lifecycle events can interrupt the canonical agent process: both tested restart modes replaced it under the Podman driver.
  - A connection that recovers automatically is not evidence that the original process survived.
  - Agent recovery through native session resume is a separate capability that stage A did not demonstrate.
  - These results do not extend to the Kubernetes driver, gateway upgrades, real agents or other configurations.
  - REQ-009 and REQ-011 remain Future, and ADR-0001 is unchanged.
- Run 3's A4b remains **recorded FAIL**. A harness exact-line check missed an ACK that the terminal had wrapped. Its committed evidence separately shows the correct ACK and an unchanged identity, which the owner accepted as part of FIND-081.

**Requirements:** REQ-009, REQ-011. **Related:** EXP-006 ([#7](https://github.com/jlaska/herdrnetes/issues/7)), FIND-071/074/076.
