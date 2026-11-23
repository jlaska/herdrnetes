# Provisional architecture

> **Status:** Provisional and subject to experiments. This is not yet a final implementation specification.

## Trusted baseline

```text
Herdr desktop/SSH clients
          |
   Herdr StatefulSet (1 replica)
   immutable, pinned image
      |          |
   local      trusted shells,
   Herdr      Claude/Codex agents
      |
      +-- persistent home/session/agent state
      +-- shared workspace PVC (repositories/worktrees)

Optional mobile/integration services: separate pods (namespace decision open)
GitOps: Argo CD drives image and declarative configuration changes
```

Use a single active Herdr writer. Longhorn RWO may suffice for the first shared workspace PVC; NFS CSI/RWX is a future option. Distinct *logical* home/state vs repository storage boundaries are important even when the implementation is simple.

## Lifecycle and data boundaries

| Boundary | Lifecycle |
| --- | --- |
| Herdr and agent executables, OS libraries, build tools | Immutable OCI image, replaced on GitOps update |
| Declarative configuration | Versioned, applied with GitOps |
| Herdr session metadata and native agent history | Durable persistent storage, must outlive pods |
| Repository files, worktrees, uncommitted changes | Separate shared workspace PVC |
| Shells/PTYs/running agents | May terminate on MVP pod replacement; restoration to be measured |
| Credentials | Managed independently; never baked into images or public Git |
| Cache contents | Rebuildable; persistent only if demonstrated useful |

## Recovery contracts to investigate

- Clean process exit vs SIGKILL, pod deletion, node drain, ordinary image changes and rollbacks.
- Herdr-only vs Claude/Codex-only version change.
- Restore layout/cwd/transcript independently of restoring a running OS process.
- Startup/readiness of Herdr must be distinguished from recovery of individual agent sessions.
- State schema migration/rollback compatibility; snapshot/backup before potentially destructive changes.

## Future lifecycle separation

Eventually let Herdr restart or upgrade while trusted agent processes continue in other pods. Feasibility depends on remote PTY/session attachment and reconnection semantics. EXP-006 has observed (single runs, not a decision) a tmux-owned agent process in a separate pod surviving Herdr pane close and Herdr pod replacement, with manual reattach over SSH (FIND-074, FIND-076; accepted as experiment evidence); Herdr upgrades, execution-pod or node failure and automatic reattach remain **not validated**. OpenShell/Kata (hypothesis under [EXP-008](experiments/08-openshell-execution.md)) and per-repo storage are subsequent investigations, not initial dependencies.

See [ADR-0001](decisions/ADR-0001-trusted-mvp.md) and the [experiment index](experiments/README.md).
