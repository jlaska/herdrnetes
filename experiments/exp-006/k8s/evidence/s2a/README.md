# EXP-006 stage 2, run `s2a` (G1, 2026-11-22): PASS, cleanup CLEAN

The owner approved one G1 run of K00–K06 from [`../../RUNBOOK.md`](../../RUNBOOK.md) at PR #37 commit
`39b1d5a3d35571091554caee69ca06f456273247`. The agent executed it against the owner-selected cluster. The owner
supplied the five identity inputs (`CTX`, `EXPECT_SERVER`, `EXPECT_KUBE_SYSTEM_UID`, `EXPECT_HERDR_UID`, `ARGO_APP`)
in a local file. They are not recorded here.

- Exec image: `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16`,
  the same as the running container's `imageID`.
- Herdr image: `ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277`
  (EXP-002, unchanged).
- Namespace `herdrnetes-exp006-s2a`. Node names are replaced by roles. `node-L` hosts the live Herdr pod, `node-E` the
  exec pod, and `node-H` both scratch Herdr pods.

## Result

| Step | Result | Observed (all from [`session-log.md`](session-log.md) unless noted) |
|---|---|---|
| K00 preflight | PASS | `ctx_ok` and `live_ok` printed `CTX_OK` and `LIVE_OK`. The baseline captured with rc 0. Namespace NotFound, no `exp-006` labelled namespaces, 3 nodes with no `unschedulable` or taints, and no PV claimRef into the namespace. |
| K01 namespace, policies, secrets, exec pod | PASS | 1 Namespace, 3 NetworkPolicies, 1 Service and 2 Secrets were created, with no AlreadyExists. Exec pod created at 17:59:01Z and Ready by 17:59:04Z on `node-E` with restartCount 0. Identity in [`identity.txt`](identity.txt). `/proc/17/stat` field 22 is `29585526`, equal to `start`. The tmux server (PID 16) has ppid 1 (tini) ([`ps-k01.txt`](ps-k01.txt)). |
| K02 Herdr pod, first attach | PASS | Herdr pod created at 17:59:26Z and Ready by 17:59:29Z on `node-H`. A pane ran the SSH attach. `mark k02` returned `ACK k02 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=41`, seen both in the pane ([`pane-k02.txt`](pane-k02.txt)) and in [`counter.log`](counter.log). One tmux client. |
| K03 pane close, reattach | PASS, with a timing deviation (below) | Pane closed at 17:59:58Z, after n=55 at 17:59:57Z. At 18:01:16Z: no tmux clients listed, same identity, n=134. A new pane returned `ACK k03 … n=146` at 18:01:28Z ([`pane-k03.txt`](pane-k03.txt)). |
| K04 Herdr pod replacement | PASS | `delete pod exp006-herdr` ran from 18:01:36Z to 18:01:38Z, after which the pod was NotFound. Two samples while it was absent: n=161–162 (18:01:42–43Z), with no tmux clients listed, and n=166–167 (18:01:47–48Z), same identity. Recreated at 18:01:55Z and Ready by 18:01:57Z on `node-H` with a new pod UID. `workspace list` showed none. A new pane returned `ACK k04 … n=197` at 18:02:19Z ([`pane-k04.txt`](pane-k04.txt)), with one tmux client. |
| K05 identity and continuity | PASS | Three ACKs carry a single `pid/start/nonce` triple. `COUNT` runs from n=1 (17:59:04Z) to n=208 with `gaps=0`, covering K02–K04 ([`counter.log`](counter.log)). Exec pod UID, `startedAt` 17:59:03Z and restartCount 0 are unchanged since K01. `/proc` start re-read: `29585526`. |
| K06 cleanup | PASS: **CLEAN** | The one-line guard (`ctx_ok && run_ok && ns_ok`) passed. The namespace delete ran from 18:02:37Z to 18:02:49Z. Namespace NotFound, no PV claimRef into it, no `exp-006` labelled namespaces. The K00 and K06 baselines are byte-identical ([`baseline-check.txt`](baseline-check.txt): same sha256, `cmp` identical, computed locally during sanitization after the run; the logged K06 `diff` had rc 0). Local keys were shredded, and a scan of the local evidence found no key text. |

Identity in every observation: `pid=17 start=29585526 nonce=4d941f1d19cdad5d`.

## Deviations from the runbook as written

1. **K03 wait.** The 10 s wait was a local `read -t 1 </dev/zero` loop followed by `timeout 11 tail -f /dev/null`. It
   hung. At the tool's 60 s limit the command was moved to the background, and the agent then stopped it with the
   harness's task-stop control. The cause was not investigated. The command's `bash -c` part, which held the cluster
   checks, produced no output: the task's output file, which is local and not committed, held only `[killed]`. This
   is noted in `session-log.md`. The continuity checks
   were issued separately at 18:01:16Z, about **78 s** after the pane closed at 17:59:58Z, not 10 s. The client count was
   therefore checked once, at about 78 s.
2. **Fresh-shell helper library.** The runbook assumes one interactive bash, but each agent command runs in a new
   shell. The agent generated [`helper-lib.sh`](helper-lib.sh) from the setup block at `39b1d5a` (local paths
   sanitized), and every command sourced it.
   - The runbook's two `export` lines were replaced by sourcing the owner's inputs file. `set -o pipefail` was added.
   - `WORK` is a fixed local directory instead of `mktemp -d`. It was created once and the manifests were rendered once,
     with the runbook's sed loop. This is the first section of `session-log.md`.
   - The `baseline`, `ctx_ok`, `live_ok`, `run_ok`, `ns_ok`, `M`, `MN`, `X` and `H` definitions, and K02's `ATTACH`,
     `newpane` and `mark`, are verbatim.
   - `attach` additionally saves the pane ID to `$WORK/pane`, and `P` is reloaded from that file. This is needed
     because `P` does not survive between shells.
3. **Command grouping and additions.** Kubernetes writes were issued one per invocation, and each result was checked
   before the next. Some invocations grouped several read-only or local commands: the two `ssh-keygen` lines, the
   two `printf` lines, each `mark` with its read-back and client checks (K02, K03 and K04), and the K05 checks. Read-only additions not in the runbook:
   - `date -u` timestamps;
   - extra jsonpath fields (`startedAt`, `imageID`);
   - `H workspace list` in K04;
   - `wc -l`, a `sort -u` of the ACK triples, the first `COUNT` line and a `/proc` re-read in K05;
   - a labelled-namespace check, and the guards before the K06 baseline.

   The exact commands are in [`session-log.md`](session-log.md).

## Not shown by this run

- It was one run. Herdr state did not persist (emptyDir), and reattaching was a manual pane command each time. A pod
  replacement is not a Herdr upgrade.
- The NetworkPolicies were not tested negatively: no blocked-path probe was run. The forced command and the
  rejection of an unauthorized key were tested only in CI (docker), not in the cluster.
- Only the last 40 visible lines of each pane were retained, so the absence of an SSH prompt is not documented
  beyond those lines. Each attach reached tmux without manual input.

## Files

`session-log.md` (the setup render step and every K00–K06 command with its output, sanitized; the K00 baseline output is summarized),
`counter.log`, `identity.txt`, `ps-k01.txt`, `pane-k02.txt`, `pane-k03.txt`, `pane-k04.txt`, `baseline-check.txt`,
`helper-lib.sh`. The withheld baseline files and the owner inputs stay local and are not committed.
