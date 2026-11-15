# Requirements

This is a **living requirements register**. Requirements are not implementation decisions.

**Status key:** Agreed = user-selected objective/constraint; Candidate = needs validation; Future = explicitly deferred.

| ID | Status | Requirement |
| --- | --- | --- |
| REQ-001 | Agreed | One unified Herdr server manages multiple terminal workspaces and Git repositories. |
| REQ-002 | Agreed | Application images are immutable with pinned Herdr and agent CLI versions, deployed by Argo CD/GitOps. |
| REQ-003 | Agreed | Herdr session data, native agent history, and repository changes survive application image replacement. |
| REQ-004 | Agreed | Initial trusted implementation uses one shared repository/workspace PVC and separate persistent home/session state. |
| REQ-005 | Agreed | Optional integration services use independent pods; same vs separate Kubernetes namespaces remains open. |
| REQ-006 | Candidate | Restore usable Herdr layouts, directories, and agent conversations after clean/forced restart, GitOps upgrade, rollback, pod deletion, and node maintenance. Exact guarantees are experimental. |
| REQ-007 | Candidate | Support remote Herdr client attachment and mobile browser access (e.g. Ovis) independent of a particular workstation. |
| REQ-008 | Candidate | Support Git access and commit signing without a YubiKey physically attached to the Herdr host. |
| REQ-009 | Future | Agent processes remain alive while Herdr itself upgrades/restarts, using independently managed execution lifecycles. |
| REQ-010 | Future | Lazily provision and hydrate a PVC per repository without restarting the unified Herdr server. |
| REQ-011 | Future | Support agent isolation via OpenShell and potentially Kata Containers. |
| REQ-012 | Future | Recover safely from full-cluster shutdown/hibernation with backed-up persistent state. |

## Initial trusted MVP non-goals

- Transparent process live migration or independent agent process continuity.
- Strong agent-to-agent isolation inside one trusted container.
- Per-repository PVC dynamic mount orchestration.
- Integrating or refactoring the separate `agent-runner` project before validation.

## Traceability and updates

Link findings (`FIND-###`) and architecture decisions (`ADR-####`) back to requirement IDs. Do not promote a candidate requirement or hypothesis to verified behavior without reproducible evidence.
