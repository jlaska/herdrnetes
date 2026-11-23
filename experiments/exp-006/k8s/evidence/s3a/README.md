# EXP-006 stage 3, run `s3a` (G1, 2026-11-23 UTC): INCONCLUSIVE, stopped at K02 (API credit balance too low); cleanup CLEAN

The owner approved one G1 run of K00–K06 from [`../../stage3/RUNBOOK.md`](../../stage3/RUNBOOK.md) at PR #37 commit
`83e34712c97ad760d443a79510c041bcbe87c2ee`, with a temporary workspace-scoped API key. The agent executed it. The
continuity question was **not measured**: the first API request from Claude Code was rejected with *"Credit balance is
too low"*. The agent never ran a tool, so K03 and K04 (detach, Herdr pod replacement) did not run. The run is
INCONCLUSIVE, not FAIL: no continuity break was observed, and none could be tested.

- Exec image: `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18`,
  equal to the running container's `imageID`. Claude Code 2.1.323, model `claude-haiku-5-5`, effort `medium`.
- Herdr image: EXP-002, unchanged. Namespace `herdrnetes-exp006-s3a`. Nodes are replaced by roles: `node-L` hosts the
  live Herdr pod, `node-E` the exec pod, `node-H` the scratch Herdr pod.
- Credential: one owner-created API key scoped to a dedicated workspace with a monthly limit of $5 or less (owner
  confirmed). The workspace is named `herdrnetes-agent-test`, not `herdrnetes-exp006` as written in the authorization;
  the owner confirmed it is the dedicated, capped workspace for this run. Key file mode 0600, outside the repository;
  the key was never printed, put in argv or an environment variable, or committed.

## Result

| Step | Result | Observed |
|---|---|---|
| K00 preflight | PASS | `ctx_ok`, `live_ok`, `run_ok` passed at 00:21:38Z (owner inputs rechecked against the cluster). Baseline rc 0, no error lines. Namespace NotFound, no `exp-006` labelled namespaces, Cilium CNP CRD present, 3 nodes Ready, schedulable, untainted; `herdr-0` Running; Argo CD Synced/Healthy; no PV claimRef into the namespace. |
| K00b model check | PASS | `GET /v1/models/claude-haiku-5-5` returned `200` (00:21:54Z). This endpoint does not consume credit, so it did not detect the empty balance (see Findings). |
| K01 namespace, network, secrets, exec pod | PASS | Namespace (00:22:02Z), 3 NetworkPolicies, Service, CiliumNetworkPolicy, 3 Secrets created and labelled, no AlreadyExists. Exec pod created 00:22:46Z, Ready 00:22:59Z on `node-E` (not `node-L`), restartCount 0, `imageID` = pinned digest ([`k01-pod.txt`](k01-pod.txt)). Identity `pid=25 start=31889030 sid=0c2ad2da-8511-4600-86c0-48e6544e0ff3 model=claude-haiku-5-5 effort=medium claude_version=2.1.323 key_present=yes` ([`identity-k01.txt`](identity-k01.txt)); status `alive=yes passing=0 check_sha_ok=yes readme_sha_ok=yes resume_flag=no` ([`status-k01.txt`](status-k01.txt)). Probes ([`k01-probes.txt`](k01-probes.txt)): `allowed ok 443` to `api.anthropic.com`; `1.1.1.1:443` `TimeoutError`; `example.com` `gaierror -3`. PSA restricted enforce/audit/warn; exec pod non-root, no privilege escalation, read-only root, ALL capabilities dropped, RuntimeDefault seccomp, no SA token; `resolv.conf` `options ndots:1`. |
| K02 Herdr pod, attach, P1 | **STOP** (no progress in 300 s) | Herdr pod Ready 00:23:51–54Z on `node-H`. Pane `w1:p1` attached; the runbook's `wait-output --match 'for shortcuts'` timed out (deviation 1), but the pane showed the Claude Code prompt (`Haiku 5.5 with medium effort · API Usage Billing`) and the dialog `grep` printed nothing (rc 1, expected) ([`pane-k02-ready.txt`](pane-k02-ready.txt)). P1 sent at 00:25:23Z (`T0=1795393523`, pod clock). 60 samples 00:25:30–00:30:46Z: all `alive=yes pid=25 passing=0 progress_lines=0 tool_uses=0 tmux_clients=1 resume_flag=no progress_since=0` ([`status-k02.txt`](status-k02.txt)). Pane: `Credit balance too low · Add funds` ([`pane-k02-stall.txt`](pane-k02-stall.txt), codeword masked). Transcript: one `api-request` at 00:25:23.980Z, then an assistant API-error entry at 00:25:24.243Z, `Credit balance is too low`, `isApiErrorMessage=True` ([`transcript-projection.txt`](transcript-projection.txt)). |
| K03 pane close, reattach, Q1 | NOT RUN | stopped at K02 |
| K04 Herdr pod replacement, Q2 | NOT RUN | stopped at K02 |
| K05 evidence | partial | Final status at 00:31:11Z: same `pid=25 start=31889030 sid`, `alive=yes`, `jsonl_count=1`, `entries=13`, `tool_uses=0`, `passing=0`, hashes `yes`, `resume_flag=no` ([`status-final.txt`](status-final.txt)). Exec pod restartCount 0, `startedAt` 00:22:59Z, unchanged. |
| K06 cleanup | PASS: **CLEAN** (key revoked; see below) | One-line guard passed; namespace delete 00:31:18–00:31:29Z. Namespace NotFound; no PV claimRef into it (`jq -e` true); no `exp-006` labelled namespaces; `ctx_ok`/`live_ok` passed; K00 and K06 baselines byte-identical (`diff` rc 0, same sha256, which also equals run `s2a`'s baseline hash). Local SSH keys shredded; the codeword file shredded. |

**API key revocation: confirmed.** The owner reported at about 00:39Z that the key was deleted in the Console and the
local key file shredded; the agent saw the key file absent at 00:39:26Z. With the Kubernetes checks above, the run
is **CLEAN** per the runbook. The owner checked the Console afterwards and saw no token spend for the key.

Process identity in every observation: `pid=25 start=31889030 sid=0c2ad2da-8511-4600-86c0-48e6544e0ff3`.
Task progress: none (`passing=0`, `progress_lines=0`). API spend: **$0.00**: the only inference request was rejected
for insufficient credit, the K00b models lookup is not billed, and the owner saw no token spend for the key in the Console.

## Deviations from the runbook as written

1. **K02 readiness match.** `herdr pane wait-output --match 'for shortcuts'` timed out after 60 s (exit 1). Claude Code
   2.1.323 in `dontAsk` mode shows `don't ask on (shift+tab to cycle)` in the footer, not `? for shortcuts`
   (unverified assumption 8 in the runbook was wrong). The pane read and the dialog grep, the step's actual criteria,
   passed; the run continued. No source was changed during execution.
2. **K01 probe capture.** The `1.1.1.1` probe was run twice: the first capture kept only kubectl's exit line, so it was
   re-run (read-only) to record `TimeoutError`; `example.com` was likewise re-run to record the exception type. A
   read-only PSA/hardening/`resolv.conf` check was added.
3. **Fresh-shell helper library** ([`helper-lib.sh`](helper-lib.sh), local paths redacted), as in run `s2a`: the setup
   functions are extracted verbatim from the runbook at `83e3471`; inputs come from the owner's local file; `WORK` is
   a fixed local directory; `attach` saves the pane ID to a file. Because no shell persists, the codeword was kept in a
   mode 0600 local scratch file (never committed, shredded at K06) instead of only in the operator shell, and `T0` in
   a local vars file.
4. **Stop handling.** After the stop at K02, the transcript projection and final status from K05 were captured
   (read-only, codeword masked; the projection adds one field to the runbook version, `isApiErrorMessage`), then K06 ran. K03 and K04 were not attempted.
5. **Workspace name** (see above): `herdrnetes-agent-test`, owner-confirmed.

## What this run did show (prerequisites for the next attempt)

- The pinned image runs under PSA restricted with the reviewed hardening; Claude Code starts in tmux under tini,
  independent of SSH, and stays alive with a stable identity for 8 minutes.
- Credential delivery works: the Secret file plus `apiKeyHelper` under `--bare` authenticated (billing error, not an
  authentication error), with `API Usage Billing` shown; no login, onboarding or trust dialog appeared (the
  `.claude.json` pre-seed works for 2.1.323).
- `EXP006_MODEL` overrode the image default: the TUI showed `Haiku 5.5 with medium effort`.
- The Cilium FQDN policy with `ndots:1` lets the exec pod reach `api.anthropic.com:443` and blocks other IPs and
  names. The agent's API request went out and got an answer.
- Not shown: anything about continuity of a working agent across pane close or Herdr pod replacement.

## Files

`identity-k01.txt`, `k01-pod.txt`, `status-k01.txt`, `k01-probes.txt`, `pane-k02-ready.txt`, `status-k02.txt`
(final K02 status; the 60 poll lines were identical apart from the time), `pane-k02-stall.txt`,
`transcript-projection.txt` (timestamp, entry type, tool names, first 200 characters of assistant text; codeword
masked), `status-final.txt`, `helper-lib.sh`. The baselines, the owner inputs and the raw pane captures stay local.
