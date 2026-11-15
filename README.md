# herdrnetes

Kubernetes-native Herdr workspaces with persistent sessions, GitOps lifecycle management, and secure agent execution.

> **Status: Architecture discovery.** First reproduce a trusted, unified Herdr terminal experience. Validate assumptions through experiments before defining the final architecture.

## Objectives

Host one unified Herdr server in Kubernetes, independent of any particular workstation. Preserve repository files, Herdr session state, and agent conversation history across application restarts and Argo CD image updates. Start with trusted agents and a shared workspace PVC, then explore uninterrupted agent execution, dynamic per-repository storage, sandbox isolation, and full-cluster recovery.

## Project navigation

- [Agent guidance](AGENTS.md) — what an agent must read and how to record changes
- [Requirements](docs/requirements.md) — agreed and candidate capabilities, with traceable IDs
- [Provisional architecture](docs/architecture.md) — lifecycle, execution and storage boundaries
- [Architecture decisions](docs/decisions/ADR-0001-trusted-mvp.md) — approved experiment baseline
- [Experiment index](docs/experiments/README.md) — test plans, findings and evidence format
- [Experiment issue template](.github/ISSUE_TEMPLATE/experiment.md)

## How to contribute findings

GitHub issues track experimental progress; Markdown in Git is the authoritative knowledge base. For each experiment, capture reproducible commands/configuration, exact image digests and versions, results and evidence, updated requirements, and proposed ADR changes. Failed hypotheses count as findings. Humans review proposed architecture decisions.

**Security:** This is a public repository. Do not commit credentials, tokens, private keys, private infrastructure details, or sensitive log output.
