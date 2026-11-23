# EXP-006 stage 3, run `s3b` (G1 retry, 2026-11-23 UTC): PASS for process and conversation continuity; work-while-detached at K03 INCONCLUSIVE; cleanup CLEAN

The owner approved one retry after `s3a` ([`../s3a/`](../s3a/README.md)) stopped on missing API credit. Runbook:
[`../../stage3/RUNBOOK.md`](../../stage3/RUNBOOK.md) at `f4197df7bc940a330ee9a2421fc5ec705c1568c3` (the reviewed
`83e3471` package plus the two owner-requested corrections: a billable K00b check and footer-independent K02
readiness). `RUN_ID=s3b`, namespace `herdrnetes-exp006-s3b`.

- Exec image `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18`
  (= running `imageID`); Claude Code 2.1.323, `claude-haiku-5-5`, effort `medium`. Herdr image EXP-002, unchanged.
- Nodes as roles: `node-L` live Herdr, `node-E` exec pod, `node-H` both scratch Herdr pods.
- Credential: a new temporary key in the owner's dedicated workspace `herdrnetes-agent-test` ($5 cap, $5 credit bought
  by the owner); file mode 0600 outside the repository; never printed, in argv, in an environment variable or committed.

## Result

| Step | Result | Observed |
|---|---|---|
| K00 preflight | PASS | Guards passed 00:57:49Z (owner inputs rechecked). Baseline rc 0, no errors, sha256 prefix `f177d785` (same as `s2a`/`s3a`). Namespace NotFound, no `exp-006` namespaces, CNP CRD present, 3 nodes Ready/schedulable/untainted, `herdr-0` Running, Argo CD Synced/Healthy, no PV claimRef. |
| K00b | PASS | 00:58:05Z: models lookup `200`; minimal Messages request (`max_tokens` 1, thinking off) `200`. Bodies not kept. |
| K01 | PASS | 10 objects created (the Herdr pod at K02 is the 11th), no AlreadyExists. Exec pod created 00:58:38Z, Ready 00:58:39Z on `node-E`, restartCount 0, pinned `imageID` ([`k01-pod.txt`](k01-pod.txt)). Identity `pid=25 start=32103078 sid=c4a9da96-c0b3-4113-a8cb-ac17f3674607 model=claude-haiku-5-5 effort=medium claude_version=2.1.323 key_present=yes` ([`identity-k01.txt`](identity-k01.txt)); status `alive=yes passing=0` hashes `yes`, `resume_flag=no` ([`status-k01.txt`](status-k01.txt)). Probes ([`k01-probes.txt`](k01-probes.txt)): `allowed ok 443`; `1.1.1.1:443` `TimeoutError`; `example.com` exit 1. PSA restricted; reviewed hardening; `ndots:1`. |
| K02 | PASS | Herdr pod Ready 00:59:07–10Z on `node-H`. Readiness (new): banner matched, dialog grep empty (rc 1), 2 rule lines, pane shows `Haiku 5.5 with medium effort · API Usage Billing` and the empty input box ([`pane-k02-ready.txt`](pane-k02-ready.txt)). P1 with codeword sent 00:59:35Z (`T0=1795395575`, pod clock). First progress 00:59:41Z ([`status-k02.txt`](status-k02.txt)). |
| K03 pane close, reattach, Q1 | Continuity **PASS**; work while detached **INCONCLUSIVE** | The agent finished f01–f04 and said `DONE-A <CODE>` at 00:59:42Z, 6.5 s after P1, before the gated close could run (pre-close check `said=yes`). The pane was closed at 01:00:07Z anyway (`N0=4`); `tmux_clients=0` immediately; 11 s later the same `pid/start/sid`, `alive=yes`, `progress_since=0` (idle, task done) ([`status-k03-detached.txt`](status-k03-detached.txt)). New pane `w2:p1` at 01:00:25Z; Q1 answered 01:00:32Z: `Q1 CODEWORD=<CODE> DONE=4` (`said=yes`) ([`pane-k03.txt`](pane-k03.txt), [`status-k03-after.txt`](status-k03-after.txt)). |
| K04 Herdr pod replacement, Q2 | **PASS** | `DONE-B` not yet said; PB sent 01:00:51Z (`T_PB=1795395651`). First PB progress (f05, 5/12) at 01:00:52.9Z; `T_DEL=1795395653`; `delete pod exp006-herdr --wait=true` 01:00:53–54Z; then `get pod` NotFound. Samples while absent: 01:00:54Z `passing=6 progress_since=1 tmux_clients=0`; 01:01:31Z `passing=8 progress_since=3 tmux_clients=0` ([`status-k04-absent.txt`](status-k04-absent.txt)); same `pid=25`, `alive=yes`. Recreated 01:01:42Z, Ready 01:01:44Z on `node-H` with a new pod UID; `workspace list` empty. New pane at 01:01:51Z; Q2 answered 01:01:58Z: `Q2 CODEWORD=<CODE> DONE=8` ([`pane-k04.txt`](pane-k04.txt), [`status-k04-after.txt`](status-k04-after.txt)). |
| K05 | PASS | 01:02:14Z ([`status-final.txt`](status-final.txt)): `pid=25 start=32103078` (= `live_start`), same `sid`, `jsonl_count=1`, `entries=113`, `tool_uses=34`, `passing=8`, `check_sha_ok=yes`, `readme_sha_ok=yes`, `progress_lines=8`, `progress_bad=0`, `resume_flag=no`, `DONE-B` said at 01:00:57.0Z. Identity file byte-identical to K01. Exec pod UID unchanged, restartCount 0, `startedAt` 00:58:39Z. [`progress.log`](progress.log), [`transcript-projection.txt`](transcript-projection.txt) (codeword masked). |
| K06 | PASS: **CLEAN** | Guarded delete 01:02:36–47Z. Namespace NotFound; no PV claimRef (`jq -e` true); no `exp-006` namespaces; `ctx_ok`/`live_ok` passed; K00/K06 baselines byte-identical (`diff` rc 0). Local SSH keys and the codeword file shredded. The owner deleted the API key in the Console. The local key file was first overwritten (`shred` without `-u`: checked to no longer start with `sk-ant-`, 4096 bytes); the owner later confirmed the key revoked and the file removed. |

### Work during the Herdr pod's absence (from the agent's own `progress.log`, pod clock)

| Time (Z) | Event |
|---|---|
| 01:00:51 | PB sent from the pane in the first scratch Herdr pod |
| 01:00:52.9 | `check 5/12` (f05) |
| 01:00:53 | `T_DEL`; pod delete starts |
| 01:00:54.3 | `check 6/12` (f06), as the delete returned |
| 01:00:54 | delete returned; `get pod` NotFound; sample: `tmux_clients=0` |
| 01:00:55.5 | `check 7/12` (f07) |
| 01:00:56.8 | `check 8/12` (f08) |
| 01:00:57.0 | assistant `DONE-B` |
| 01:01:42–44 | replacement Herdr pod created and Ready |

f07, f08 and `DONE-B` happened after the pod was confirmed NotFound and with no tmux client attached (the local and pod
clocks are both NTP-synchronised; the ordering margin is 1.5–3 s). The agent completed PB about 4 s after it was
sent, so the work observed during absence lasted about 3 s, not minutes.

Process identity in every observation K01–K05: `pid=25 start=32103078 sid=c4a9da96-c0b3-4113-a8cb-ac17f3674607`.
Conversation memory: the codeword, present only in P1, was returned after both reattachments (Q1 from a new pane in the
same Herdr pod after a pane close; Q2 from a pane in a replacement Herdr pod). Final task count: 8/12 (PC was not sent;
the runbook does not require it).

**API spend:** when the owner checked the Console after the run, usage for the key showed **zero reported tokens**.
Inference did occur (K00b's Messages request returned `200`; the transcript has 113 entries and 34 tool uses), so the
zero is a reporting observation (cause not investigated: for example reporting delay or attribution), not evidence that
the run was free. Estimate: well under $0.10 (Haiku 5.5 at $0.10/$0.50 per MTok input/output, cache reads 0.1x; about
40 model turns plus the 1-token K00b request). The transcript's per-request usage was not extracted before the
namespace was deleted.

## Deviations from the runbook

1. **K03 gate and order.** The K02 progress wait, the K02 status capture and the first K03 lines (`--said DONE-A`
   check, `N0`, `T_CLOSE`, close) were issued in one invocation to reduce latency; the close was gated on `said=no`
   and unchanged `pid`/`start`. The gate failed (`said=yes`), so nothing was closed in that invocation. Following the
   owner's instruction for this case (report work-during-disconnection as INCONCLUSIVE; do not prolong the run), the
   pane was then closed with the agent idle, the 300 s detached-progress loop was **not** run (an idle agent that has
   finished cannot progress; this is not a stall), and Q1 was asked.
2. **K04 timing.** PB send, the progress wait, the delete and the first absent sample were issued in one invocation,
   and the progress wait polled every 1 s instead of 5 s, so the delete would land while the agent was still working.
   The steps and their order are the runbook's.
3. **Fresh-shell helper library** ([`helper-lib.sh`](helper-lib.sh), paths redacted), as in `s2a`/`s3a`: setup
   functions verbatim from the runbook at `f4197df`; `RUN_ID=s3b` set there (the runbook's example line says `s3a`);
   the codeword kept in a 0600 local file (shredded); `T0`, `N0`, `T_CLOSE`, `T_PB`, `T_DEL` in a local vars file.
4. Read-only additions: `date -u` stamps, `--brief` echoes, a PSA/hardening/`resolv.conf` check at K01, the exec and
   Herdr pod UIDs/nodes (UIDs withheld here), `--said DONE-B` in the final status.

## Not shown by this run

- Work continuing through a **pane close** while the agent is busy: Haiku finished P1 in 6.5 s. K04 showed work with
  zero tmux clients during Herdr pod absence, which includes the loss of the SSH client, but only for about 3 s.
- Long-running work across Herdr churn; a Herdr upgrade (this was a pod replacement; state was emptyDir and the
  replacement started with no workspaces, so reattaching was a manual pane command, as in FIND-072/074).
- One run only.

## Files

`identity-k01.txt`, `k01-pod.txt`, `status-k01.txt`, `k01-probes.txt`, `pane-k02-ready.txt`, `status-k02.txt`,
`status-k03-detached.txt`, `pane-k03.txt`, `status-k03-after.txt`, `status-k04-absent.txt`, `pane-k04.txt`,
`status-k04-after.txt`, `status-final.txt`, `progress.log`, `transcript-projection.txt`, `helper-lib.sh`. The
baselines, owner inputs and raw captures stay local.
