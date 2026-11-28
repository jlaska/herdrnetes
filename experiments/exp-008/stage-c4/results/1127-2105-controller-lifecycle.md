# EXP-008 C4 run `1127-2105`: Sandbox CR suspension after workload loss (agent-generated supplementary analysis; offline)

**Agent-generated analysis for owner review. It is not a finding and changes nothing in the run record.** The run record [`1127-2105.md`](1127-2105.md), its committed evidence and the accepted FIND-099 are unchanged. FIND-099 states that the suspend actor was "not identified in the evidence". This note gives the source-derived attribution and one locally retained log observation, so that the owner can decide whether to amend that wording. Issue [#39](https://github.com/jlaska/herdrnetes/issues/39).

## Labels and sources

| Label | Meaning |
|---|---|
| **O** | Committed evidence `evidence/1127-2105/` (`samples/cr-watch.jsonl`, `pods-watch.jsonl`, `events-watch.jsonl`, `sandbox-get-1hz.txt`, `timeline.log`) |
| **O-local** | The run's locally retained gateway container log (`$HX/run/1127-2105/raw/logs/c4a-gateway.log`, mode 0700). Not committed, like the FIND-097 supervisor logs |
| **S** | Upstream source at the pinned tags, read only (not built) |
| **I** | Inference |
| **U** | Unattributed |

Pinned upstream source:
- OpenShell `v0.1.9` = `ce58cf8e9b953281352d98a637e41616295b1318`. `DRV` is `crates/openshell-driver-kubernetes/src/driver.rs`; `GW` is `crates/openshell-server/src/compute/mod.rs`.
- agent-sandbox `v1.0.12` = `4863a629bd6ea0c53a70c1712c46058f4b46f81b`. `AS` is `controllers/sandbox_controller.go`.

**Evidence limits.**
- `cr-watch.jsonl` has no `managedFields`, `generation` or timestamps. The generation is visible only through each condition's `observedGeneration`.
- Events carry no `source` or `reportingController`.
- `pods-watch.jsonl` is ordered by resourceVersion only.
- No committed file names the writer of the CR spec.

## Sequence

| Time (UTC) | Observation | Label | Actor and basis |
|---|---|---|---|
| 02:05:59 | A Suspended/PodTerminated condition is reported at `observedGeneration` 1, then flips to NotSuspended at generation 2 | O | The driver creates the CR suspended on purpose and sets it Running after bootstrap: DRV:2667 "the CR is also created suspended so the controller…" (S). Expected; not a fault |
| 02:11:05.390 | M9 deletes workload pod `ba495713-…` with `--grace-period=1`. The agent container exits 137 | O | Harness |
| 02:11:06 | The gateway phase becomes `Error`. The CR's Ready reason is `PodTerminating` | O | `derive_phase` maps Ready=False with a non-transient reason to Error (GW, S) |
| 02:11:08.9 | `SandboxPodCreated`: replacement pod `c0964ee5-…` is created and stays Pending/SchedulingGated | O | The agent-sandbox controller recreates a missing pod while `operatingMode` is Running (AS, S). The pod template carries the driver's bootstrap scheduling gate, which only the driver removes for a generation it started, so the pod cannot run (DRV, S). This is the "fenced" replacement |
| 02:11:30.535 | Gateway log: `WARN openshell_driver_kubernetes::driver: sandbox-runtime workload generation changed; suspending stale boundary sandbox_id="31e536c4-…"` | **O-local** | The OpenShell driver's periodic reconcile, which runs every 30 s (`SANDBOX_RUNTIME_RECONCILE_INTERVAL`, DRV:614). It found that the pod holding the workload name no longer has the annotated workload UID (`sandbox_runtime_workload_generation_matches`, DRV:7038-7069, returns Unavailable). It then called `suspend_sandbox_runtime_after_dependency_failure` (DRV:5188-5195), which patches `spec.operatingMode: Suspended` (`replicas: 0` for v1alpha1; DRV:8829-8831) (S) |
| 02:11:30 | Replacement pod deleted while Pending. The CR moves to generation 3, Suspended False/PodTerminating, then True/PodTerminated. `SandboxSuspended` event at 02:11:30.598 | O | The agent-sandbox controller, reacting to the driver's spec change: it deletes the pod when Suspended (AS:1753) and writes the Suspended status and event (AS, S). The controller never assigns `Spec.OperatingMode` (no assignment in `controllers/`, S) |
| 02:11:35 | The supervisor container exits 1 ("boundary lost"). The gateway logs "supervisor session: stream closed by supervisor" | O; O-local | The supervisor ended its own session after losing its boundary (I). The cause of the 5 s delay is U |
| ~02:12:00 | The supervisor pod is deleted | O | The driver's suspend completion (`reconcile_sandbox_runtime_suspending`, DRV, S+I) |
| 02:11:06–02:13:25 | The gateway phase stays `Error` (110 samples at 1 Hz), then `Stopped` after the manual `sandbox stop` | O | **U.** From source, Suspended=True without Ready appears to map to Stopped. The persistence of `Error` is not explained |

## Conclusion

The suspension is attributed, with direct but local-only evidence, to a **documented OpenShell Kubernetes-driver action**: the 30 s runtime reconcile's stale-workload-generation suspend. The agent-sandbox controller only reacted. It deleted the gated replacement pod and reported the condition and event.

**What remains uncertain:**
- The committed evidence alone does not name the writer. The attribution rests on the locally retained gateway log line plus source (O-local + S).
- Why the gateway phase stayed `Error` instead of moving to `Stopped` once the CR was suspended (U).
- The 5 s supervisor-exit delay (U).

## Implications for future experiments (no changes proposed)

- **Automatic recovery.**
  - With this configuration, nothing restarts a lost workload.
  - The controller's recreated pod is gated and cannot run. Within one 30 s reconcile the driver suspends the sandbox as a stale boundary.
  - Any automatic-recovery design must go through the driver's own generation, as `sandbox start` does. Pod-level recreation, or `failedPodPolicy: Recreate`, would produce gated pods and the same suspend (S+I).
- **Timing.** Experiments that observe the post-loss state should expect a transition about 0–30 s after the loss, tied to the reconcile tick. In this run it came 25 s after the loss.
- **Deletion.**
  - The default PVC is owned by the Sandbox (`SetControllerReference`, AS:2246 and AS:2280) and was removed with the sandbox at cleanup (O, `timeline.log` 02:22:48).
  - State is retained only through suspend and `stop`/`start`, as in C4b, and not through deletion.
  - Deletion experiments should treat PVC loss as expected behaviour, not as residue.
