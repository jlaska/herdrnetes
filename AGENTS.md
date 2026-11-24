# Agent instructions

This repository records **evidence-driven architecture discovery** for a Kubernetes-hosted Herdr environment. It is not a mandate to build an entire platform now.

## Read before starting work

1. [Project overview](README.md)
2. [Requirements](docs/requirements.md)
3. [Provisional architecture](docs/architecture.md)
4. Accepted [architecture decisions](docs/decisions/)
5. Your assigned GitHub issue and corresponding [experiment](docs/experiments/)

## Current focus

Replicate the unified Herdr terminal experience with **one trusted Herdr instance**, immutable pinned images, a persistent home/state volume, and **one shared workspace PVC**. The MVP may interrupt agents on Herdr upgrades; native restore behavior must be measured, not assumed.

Future work includes surviving Herdr updates without stopping agent processes, dynamic per-repository PVCs, OpenShell/Kata isolation, and cluster hibernation. Optional services have independent pod lifecycles; whether to use one namespace or multiple is not yet decided.

## Rules for agents

- Distinguish **accepted decisions**, **requirements**, **hypotheses**, **observed evidence**, and **proposals**.
- Do not quietly change an accepted ADR or mark a proposal accepted. Propose changes for human review.
- Record **exact image digests, Herdr/agent versions, environment, commands, test inputs, and observed behavior**.
- Test clean restart, forced restart, image upgrades and rollback separately. Kubernetes readiness does not demonstrate that sessions recovered.
- Link important findings to `REQ-###`, `EXP-###`, `FIND-###`, and `ADR-####` identifiers.
- Never commit tokens, secrets, private keys, internal hostnames, or sensitive log contents to this **public** repository.
- A failed hypothesis is a valid experimental result.
- Avoid importing `agent-runner`, OpenShell, Kata, or dynamic per-repo PVC complexity into initial experiments without an approved decision.

## Agent Git policy

Owner decision, 2026-11-23. Follow-up to [#29](https://github.com/jlaska/herdrnetes/issues/29) (FIND-055).

- **Branches.** Agents commit and push only on `agent/*` branches. They never commit or push to `main`, `release/*` or any other branch.
- **Unsigned commits.** Agent commits are unsigned. Disable signing explicitly on every agent Git command (`-c commit.gpgsign=false`), without changing global Git configuration.
- **Identity.** Author agent commits with the GitHub noreply address, never a private address. Never forge the owner's authorship or signature. Agent commits currently use the owner's noreply identity. This is a temporary consequence of the shared-account workflow and does not imply human authorship or approval. Agent-created PRs must identify themselves clearly as agent-generated. A dedicated agent identity is planned.
- **Credentials.** Push over the existing permitted HTTPS workflow with `SSH_AUTH_SOCK` unset. Never use the owner's GPG agent, SSH agent, hardware keys or YubiKeys, and never ask the owner to unlock one for an agent. If a signed commit is needed, the owner makes it in their own terminal. Disabling commit signing and unsetting `SSH_AUTH_SOCK` prevent incidental signing. They do **not** isolate agents from the owner's GPG agent or other credentials while agent processes share the owner's UID.
- **Integration.** Agent changes reach `main` only through pull requests, and **squash merge** is the only approved method. Merge commits and rebase merges are not approved. The owner reviews and merges; agents do not merge their own PRs and do not bypass repository protections. A GitHub Verified signature on the squash commit is not a substitute for owner review.
- **Future.** Scoped, short-lived agent credentials (see [EXP-004](docs/experiments/04-git-identity.md)) are planned. They will replace the shared HTTPS credential. They are not implemented yet.

## Experiment completion

An experiment can close after a reproducible result is committed, evidence is linked in its issue, architecture and requirements implications are reviewed, and follow-up work is recorded. It does **not** need to produce deployable code.
