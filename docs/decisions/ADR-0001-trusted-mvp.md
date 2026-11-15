# ADR-0001: Start with a trusted unified Herdr pod and immutable images

- **Status:** Accepted for the experimental baseline (not a final production decision)
- **Date:** 2026-11-15

## Context

We want a Kubernetes-native Herdr experience resilient to workstation restarts and GitOps upgrades. We ultimately want running agent processes to survive Herdr application updates, but attempting execution separation before observing native Herdr recovery adds unnecessary complexity.

## Decision

1. Run one Herdr instance with trusted local shells and agent processes for the initial experiments.
2. Build immutable OCI images with pinned Herdr and agent CLI versions. Do not depend on mutable tools installed into persistent volumes.
3. Keep Herdr/home/agent state durable and distinct from a **shared workspace PVC**.
4. Accept agent process interruption on Herdr pod replacement *temporarily*; test session and conversation recovery explicitly.
5. Deploy optional integration services in separate pods; defer namespace topology choice.
6. Defer agent-runner integration/refactoring, OpenShell/Kata, and dynamic per-repository PVCs.

## Consequences and risks

GitOps version changes are reproducible but still terminate in-pod PTYs. Agent resume, session-schema compatibility, and image rollback are not guaranteed; experiments must verify these. Shared trusted execution is not a security boundary. Process continuity requires a later independently managed execution model.

## Revisit

Revisit when experimental evidence contradicts restore assumptions, or when uninterrupted execution becomes a near-term requirement.
