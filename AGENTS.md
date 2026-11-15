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

## Experiment completion

An experiment can close after a reproducible result is committed, evidence is linked in its issue, architecture and requirements implications are reviewed, and follow-up work is recorded. It does **not** need to produce deployable code.
