# EXP-008: OpenShell-owned execution with Herdr as a disposable client

**Status:** Planned (issue [#39](https://github.com/jlaska/herdrnetes/issues/39)). Not authorized for execution. Stage A local execution plan: [experiments/exp-008/local/PLAN.md](../../experiments/exp-008/local/PLAN.md), awaiting owner review.

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

**Evidence:** None yet. **Requirements:** REQ-009, REQ-011. **Related:** EXP-006 ([#7](https://github.com/jlaska/herdrnetes/issues/7)), FIND-071/074/076.
