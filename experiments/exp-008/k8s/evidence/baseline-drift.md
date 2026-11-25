# Stage B baseline drift between runs (redacted summary)

Agent-generated for owner review, 2026-11-24 (UTC dates below). Source: the harness `inventory()` output (`stageb.sh`), written to `inv/b0-pre/` at the `pre` step of **each** run, and kept local. Only the fields that differ between runs are reproduced here. Argo application names are redacted to `argo-app-*`. No Secret data was read at any point (`openshell-objects.txt` lists Secret names and UIDs only).

**Why this file exists.** The run-3 cleanup diff (`1124-2222/inv/diff-*.txt`) compares the post-run inventory with **run 3's own pre-run inventory**, captured at 2026-11-25T03:21:37Z after both prerequisite fixes. It does not compare against the original B0 read-only inventory in proposal revision 4, section 2.4 (about 2026-11-24T21:20Z). The two baselines differ, as shown below.

## Baselines

| Snapshot | When (UTC) | Form |
|---|---|---|
| **B0** (proposal rev 4, section 2.4) | 2026-11-24 ~21:20 | Ad hoc read-only commands (rev 4 section 5.1). Raw output local. Not directly diffable with the harness form |
| `0000-0000` pre (harness preflight) | 2026-11-24 22:02:42 | Harness form. The run stopped at `pre` (CLI registration missing: owner login not yet done). No mutation |
| `1124-2120` pre (attempt 1) | 2026-11-25 02:20:41 | Harness form. **Identical to `0000-0000` pre in every file** |
| `1124-2135` pre (attempt 2) | 2026-11-25 02:35:30 | Harness form |
| `1124-2222` pre (run 3) | 2026-11-25 03:21:37 | Harness form. The baseline for the run-3 cleanup diff |

## Fields that changed between attempt 1 and run 3

| Field | `0000-0000` and attempt 1 | Attempt 2 | Run 3 (cleanup baseline) |
|---|---|---|---|
| Gateway image digest | `gateway@sha256:1fd9e1e8…dfe5` | same | same |
| Controller image digest | `agent-sandbox-controller@sha256:b0ee91a4…4103` | same | same |
| Gateway StatefulSet UID | `438d42ed…` | same | same |
| Gateway StatefulSet `generation` | 9 | **10** | 10 (post-run: 12, from B2's two scale operations) |
| `openshell-config` ConfigMap UID | `0c337a91…` | same | same |
| `openshell-config` `resourceVersion` | 74314240 | **86252872** | **86271836** |
| `openshell-certgen` ServiceAccount / Role / RoleBinding UIDs | `fcc8dc2e…` / `397cc011…` / `377b648a…` | same | **recreated**: `5a698587…` / `104e5e0c…` / `1b1bc17b…` |
| `argo-app-openshell` | Synced / Healthy at GitOps `a604ce9`; last operation 2026-11-18 | **OutOfSync / Progressing** at `a604ce9` | Synced / Healthy at GitOps `1978dc1`; last operation started 2026-11-25T02:47:30Z |
| `argo-app-agent-sandbox` | Synced / Healthy at `a604ce9`; last operation 2026-11-24T21:11Z | same | Synced / Healthy at `1978dc1`; last operation unchanged (21:11Z) |
| GitOps `main` | `a604ce9` | `a604ce9` | `1978dc1` |
| Gateway pod | Up since 2026-11-19 07:25 (per B0) | Replaced: the run-3 gateway log begins 2026-11-25T02:33:48Z | Same pod as attempt 2 until B2 |
| Talos node configuration (ptrace) | Not captured by any inventory | Not captured | Not captured. The owner reports patching the nodes between attempts 2 and 3 |

All other inventory files (CRD, controller objects and ClusterRole, ClusterRoleBinding, webhooks, namespaces, PVCs, Cilium policies, Sandbox CRs) are identical across the four harness snapshots.

## Reading (inference, not observed)

- Between attempt 1 and attempt 2 the gateway StatefulSet's pod template and its ConfigMap changed while GitOps `main` stayed at `a604ce9` and the OpenShell app read OutOfSync. That fits a live change made ahead of the GitOps commit (the owner's `grpc_endpoint` correction). The record does not show how the change was applied.
- The 02:47:30Z sync of `1978dc1` changed the ConfigMap's `resourceVersion` again and re-created the certgen hook objects, but did not change the StatefulSet `generation`. The run-3 gateway process was therefore started (02:33:48Z) before that sync. Whether the ConfigMap's content changed at 02:47 is not recorded.
- The node ptrace change sits outside every inventory, so no diff can show that the nodes match their pre-experiment state.

## Consequence for the cleanup claim

- **Supported:** after run 3, the installation matched **run 3's pre-run baseline**, except for StatefulSet `generation` 10 → 12. That difference is outside the allowed differences in rev 4 section 6 step 7 (gateway pod UID and age, events). It is an expected side effect of B2's `scale` operations.
- **Not supported:** that the installation matches the original **B0** configuration. Both prerequisite fixes remain in place (by design), and they are part of the tested configuration.
