# Experiment index and evidence conventions

GitHub Issues coordinate work. These Markdown records capture reproducible procedures, verified observations, findings, and architecture implications. Closing an issue without incorporating findings here is insufficient.

| ID | Experiment | Document |
| --- | --- | --- |
| EXP-001 | Herdr session recovery | [01-session-recovery](01-session-recovery.md) |
| EXP-002 | Trusted Kubernetes deployment and Argo CD upgrades | [02-kubernetes-deployment](02-kubernetes-deployment.md) |
| EXP-003 | Remote and mobile access | [03-remote-access](03-remote-access.md) |
| EXP-004 | Git credentials and commit signing | [04-git-identity](04-git-identity.md) |
| EXP-005 | Repository lifecycle / storage | [05-repository-storage](05-repository-storage.md) |
| EXP-006 | Independent agent execution / OpenShell/Kata | [06-isolated-execution](06-isolated-execution.md) |
| EXP-007 | Full-cluster hibernation and recovery | [07-cluster-hibernation](07-cluster-hibernation.md) |
| EXP-008 | OpenShell-owned execution with Herdr as a disposable client | [08-openshell-execution](08-openshell-execution.md) |

## Record for every run

- Hypothesis and measurable expected result.
- Exact tested images/digests, Herdr/agent versions, platform details.
- Procedures/commands and relevant redacted configuration.
- Observations and supporting evidence (logs, screenshots, reproducible steps).
- Result classification per relevant artifact: **Fully restored**, **Recoverable with manual action**, or **Lost**.
- Numbered important findings (`FIND-###`) cross-linked to `REQ-###`, issues, and ADRs.
- Contradictions, new hypotheses, follow-up tasks and implications.

A disproven hypothesis can still constitute a successful experiment. Never commit credentials or unredacted sensitive logs.
