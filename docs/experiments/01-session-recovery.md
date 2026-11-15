# EXP-001: Herdr session persistence and recovery

**Status:** Planned; no verified findings yet.

## Hypotheses

- Herdr can restore workspace, tab, pane and working-directory structure after exit or crash.
- Native agent conversation state remains recoverable after processes die, subject to CLI capabilities.
- Application and agent version changes may introduce compatibility constraints.

## Proposed test matrix

1. Record Herdr, Claude Code and Codex versions plus platform and configuration.
2. Create multiple workspaces with multiple tabs/panes, shell state and Claude/Codex conversations; make uncommitted repository edits.
3. Record observable baseline (layouts, cwd, agent session IDs where safe, process IDs, files).
4. Perform **clean shutdown**; restart and inspect restoration.
5. Perform **forced termination**; restart and inspect restoration.
6. Change **Herdr version only**, restore state, and observe compatibility.
7. Change **agent CLI version only**, resume the prior conversation and observe compatibility.
8. With pre-upgrade state backup, **roll back** version and record results.

## Evidence

Not yet executed. Record exact versions, commands, test setup and observed restoration per component.

## Findings and implications

No verified findings. Map results to REQ-003 and REQ-006 and identify paths needing persistent storage in EXP-002.
