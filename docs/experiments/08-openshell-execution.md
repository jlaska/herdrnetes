# EXP-008: OpenShell-owned execution with Herdr as a disposable client

**Status:** In progress (issue [#39](https://github.com/jlaska/herdrnetes/issues/39)). Stage A local plan [PLAN.md](../../experiments/exp-008/local/PLAN.md); two authorized attempts, **both stopped at A1**; A2–A7 have not run and the research question is unanswered.
- Run `1122-220034` stopped at `sandbox create`: Podman healthcheck timers need the user systemd socket.
- The retry, run `1123-072024`, applied the owner-approved correction. The sandbox reached Ready with the counter as its canonical main process, and its identity was recorded. It then stopped at the first pane attach on a harness defect: an argv glob in the attach predicate could never match `sandbox connect`. The first diagnosis (that `connect` exec-replaces itself with `ssh`) was wrong. In v0.1.9 the CLI supervises a child `ssh` (FIND-080, revised). The harness correction is committed but has not been run; a third run needs separate authorization.

Results, findings and a proposed correction (not authorized to run): [experiments/exp-008/local/README.md](../../experiments/exp-008/local/README.md).

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

**Evidence:** [run 1122-220034](../../experiments/exp-008/local/evidence/1122-220034/), [run 1123-072024](../../experiments/exp-008/local/evidence/1123-072024/).
- FIND-077, FIND-078 and FIND-079 are accepted at their stated scopes (FIND-077: observed, single workstation).
- FIND-080 is proposed (revised: supervised `connect` spawns `ssh`; the earlier exec-replace statement is withdrawn).

**Requirements:** REQ-009, REQ-011. **Related:** EXP-006 ([#7](https://github.com/jlaska/herdrnetes/issues/7)), FIND-071/074/076.
