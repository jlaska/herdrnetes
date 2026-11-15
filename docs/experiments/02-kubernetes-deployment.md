# EXP-002: Trusted Kubernetes deployment and GitOps lifecycle

**Status:** Planned; no verified findings yet.

## Objective

Reproduce the trusted Herdr experience inside Kubernetes with an immutable pinned OCI image, separate persistent home and **shared workspace PVC**, and Argo CD-driven updates.

## Proposed test matrix

- Inspect Herdr data paths and startup/shutdown semantics discovered in EXP-001.
- Deploy single-replica Herdr workload, ensuring persistent directories survive pod replacement.
- Verify clean pod deletion, SIGTERM grace-period behavior, forced termination, and node drain.
- Trigger a GitOps **Herdr-only** image update, leaving agent CLI versions fixed.
- Trigger an **agent-only** version change, leaving Herdr fixed.
- Exercise configuration changes, determine what triggers pod replacement.
- Snapshot durable state, then perform **image rollback** and test state compatibility.
- Compare Kubernetes pod readiness with actual workspace and agent-session recovery.

## Evidence and findings

Not yet executed. Record image digests, Argo CD revisions, PVC identity/mounts, Kubernetes events and restoration observations.

## Requirements

REQ-002, REQ-003, REQ-004, REQ-006.
