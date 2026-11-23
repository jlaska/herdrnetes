# EXP-006: minimum viable independent agent execution

Issue [#7](https://github.com/jlaska/herdrnetes/issues/7) · plan [06-isolated-execution.md](../../docs/experiments/06-isolated-execution.md) · REQ-009 · ADR-0001 unchanged

**Question.** Can a process run independently of Herdr, so that a Herdr pane can attach to it, drop it, reattach to
the *same* process, and do the same again after the Herdr server restarts? This is process and PTY continuity. It is
not conversation recovery: a pane re-running `claude --resume` (FIND-007) starts a new process.

**Mechanism (simplest known).** A tmux server owns the PTY. It runs on a dedicated socket, uses no user config, and
is started outside Herdr. A Herdr pane is only a client: `tmux -S <sock> -f /dev/null attach -t agent`. No custom
PTY manager, daemon or Herdr change is involved.

## Local result: PASS (stage 1 of 3)

Run: `experiments/exp-006/local/demo.sh [run-id]`. It takes about 15 s and exits 0 only if every test passes. It
uses a disposable Herdr 0.9.5 with its own `XDG_CONFIG_HOME`, socket and allowlisted `env -i` environment
(no `HERDR_*` and no `SSH_AUTH_SOCK`), and a tmux server under `/tmp/hx6/<run-id>`. The live Herdr and the default
tmux server are never addressed. Mutating `herdr` calls are refused unless the resolved socket is inside the run
directory.

The synthetic agent, [`counter.sh`](local/counter.sh), records its PID, its `/proc/<pid>/stat` start time and a
random nonce, then ticks about once a second to the terminal and to `counter.log`. It answers the input
`mark <word>` with `ACK <word> pid= start= nonce= n=`. An ACK typed through a Herdr pane, carrying the same
pid/start/nonce triple, proves the original process was reached.

| Test | Action | Result (run `v2`) |
|---|---|---|
| T1 attach | new pane runs `tmux attach`; `herdr pane send-text 'mark t1'` | PASS. ACK in the pane and in the log, n=1 |
| T2 disconnect | `herdr pane close` (abrupt; not a tmux detach) | PASS. 0 tmux clients; same process; n went 2→7 over 4 s with no client |
| T3 reconnect | new pane, attach, `mark t3` | PASS. Same pid/start/nonce, n=7 |
| T4a clean Herdr restart | attached pane, then `herdr server stop`, start, new pane, attach | PASS. Old server gone; n went 8→11 while Herdr was down; same identity |
| T4b forced Herdr restart | attached pane, then `kill -9` the Herdr server PID, start, new pane, attach | PASS. n went 12→15 while Herdr was down; same identity |

Identity in run `v2`: `pid=931953 start=28203948 nonce=73d029d5d1f74fd0` for all ACKs (t1, t3, t4a, t4b). The tmux
server had ppid 1 and its own session in every process snapshot. Herdr was never an ancestor of the counter.

Evidence:
- [`local/evidence/v2/`](local/evidence/v2/): the final script.
- [`local/evidence/v1/`](local/evidence/v1/): an independent verification run of the script before two
  `--version` calls were moved into the scrubbed environment. Results were identical.

Each run directory has the identity file, `counter.log`, pane reads, `ps` snapshots, versions with sha256 of the
binaries, and a cleanup record showing that every recorded PID was positively gone.

Environment: Fedora 44, Linux 7.3.4, Herdr 0.9.5 (Homebrew, sha256 `32f81aa0…affc66`), tmux 3.8, bash 5.3.9.

## Findings (owner review 2026-11-22: FIND-071/072 accepted as local findings; FIND-073 limited to the CLI-help survey; FIND-074 proposed)

- **FIND-071: A tmux-owned process outlives Herdr pane closure, clean server stop and server SIGKILL, and a new
  pane reattaches to the same process.** [observed, local] This contrasts with in-pane processes (FIND-002). The
  condition is that the tmux server is started outside Herdr's process tree and environment. → REQ-009.
- **FIND-072: Herdr does not restore an attachment.** [observed] After either restart style the restored pane is a
  plain new shell, with no `tmux attach` re-run and 0 tmux clients. Reattaching is one manual command in a new pane.
  After SIGKILL only one of the two existing panes was restored. This was not investigated; it is probably the
  save-debounce window (FIND-003).
- **FIND-073: No Herdr 0.9.5 feature reviewed decouples a pane process from its server.** [help text only, not
  tested] `herdr --remote`, `machine` and `session` attach clients to a Herdr server that still owns its PTYs.
  `herdr update --handoff` appears to pass PTY file descriptors to a new server on the same host (cf. FIND-009). It
  is disabled for Homebrew installs and was not exercised. Even if it works, it covers upgrades only, not crashes or
  pod replacement.
- **FIND-074: The FIND-071 result holds across two pods in Kubernetes.** [observed, Kubernetes, single synthetic run
  `s2a`, proposed] The process runs under tmux in its own exec pod and is reached over SSH through a forced
  `tmux attach`. It survived closing the Herdr pane and deleting and recreating the scratch Herdr pod, with no
  counter gaps and no exec-pod restart. A new pane in the new pod reattached to the same `pid`/start/nonce. The
  replacement Herdr started with no workspaces, so reattaching was again a manual command (consistent with FIND-072).
  → REQ-009. Evidence: [`k8s/evidence/s2a/`](k8s/evidence/s2a/).
- **FIND-075: The stage-3 real-agent slice deploys and reaches the API, but run `s3a` measured no continuity.**
  [observed, Kubernetes, single run `s3a`, proposed] Under PSA restricted, the pinned image started Claude Code
  2.1.323 in tmux on the selected model, with the API key delivered as a Secret file through `apiKeyHelper` under
  `--bare`, and showed no first-run dialog. The Cilium FQDN policy with `ndots:1` allowed `api.anthropic.com:443`
  and blocked other destinations. The first inference request failed with *"Credit balance is too low"*: the K00b
  models lookup checks that the key authenticates, not that it can spend. The runbook's `for shortcuts` readiness
  match does not appear in `dontAsk` mode. → REQ-009. Evidence: [`k8s/evidence/s3a/`](k8s/evidence/s3a/README.md).
- **FIND-076: A real Claude Code process and its conversation survive pane closure and Herdr pod replacement.**
  [observed, Kubernetes, single real-agent run `s3b` on Claude Haiku 5.5, proposed] With tmux owning the PTY in the exec
  pod, the same `pid`/start time and session ID persisted across a pane close and a scratch Herdr pod delete/recreate.
  The agent answered with the codeword from its first prompt after each reattachment, and kept editing and testing
  while the Herdr pod was absent and no client was attached. Limits: the work observed during absence lasted about 3 s.
  Work through a pane close while busy was not observed, because the task finished first. One run. This extends
  FIND-074 from a synthetic counter to a real agent. → REQ-009. Evidence: [`k8s/evidence/s3b/`](k8s/evidence/s3b/README.md).

## Limitations and open questions

- Stage 1 is local only. Stage 2 (Kubernetes over SSH) passed once with the synthetic counter. A real agent was tested once in stage 3 (run `s3b`, FIND-076).
- Herdr shows the attached session as an ordinary pane. It has no agent status or transcript integration. These are
  future enhancements and were not attempted.
- Reattach after a Herdr restart is manual. Automating it (pane command, shell rc, or Herdr's own agent-resume
  hook) is an open question, not a requirement here.
- Only the tmux server's lifetime was tested. A tmux server crash would still lose the process. Survival of the
  execution host or pod itself is out of scope.

## Stage 2: Kubernetes slice: PASS (run `s2a`, 2026-11-22; cleanup CLEAN)

The review package is [`k8s/RUNBOOK.md`](k8s/RUNBOOK.md), with [`k8s/manifests/`](k8s/manifests/), the execution image
[`exec-image/`](exec-image/), and a proposed build workflow kept as an inactive copy at
[`exec-image/proposed-workflow-exp006-exec-image.yml`](exec-image/proposed-workflow-exp006-exec-image.yml). The owner
installs it under `.github/workflows/`, because the agent token cannot write workflows.

The execution image is built and public:
`ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16`, from source
`35369c2`. It came from owner-dispatched [CI run 45033107115](https://github.com/jlaska/herdrnetes/actions/runs/45033107115),
in which the four docker-based SSH/PTY smoke tests passed. The manifests pass `kubeconform -strict` for 1.36.

**Result (owner-approved G1 run `s2a` at `39b1d5a`; owner accepted the results).** K00–K06 all PASS and cleanup was
**CLEAN**, with the K00 and K06 live baselines byte-identical. Identity was `pid=17 start=29585526 nonce=4d941f1d19cdad5d`
across `ACK k02` (n=41, first attach), `ACK k03` (n=146, after the pane closed) and `ACK k04` (n=197, after the Herdr
pod was deleted and recreated). The counter ran n=1→208 with no gaps, and the exec pod had 0 restarts. Two
deviations are recorded in [`k8s/evidence/s2a/`](k8s/evidence/s2a/README.md):
- The local 10 s wait in K03 hung, so the detached checks ran about 78 s after the pane closed.
- Commands ran in fresh shells through a helper library generated from the runbook setup. Its functions are verbatim,
  except that `attach` saves the pane ID to a file. The scratch Herdr pod uses the EXP-002 image unchanged. The image survey found no
existing pinned image with tmux and a non-root sshd, so the execution image is new.

The summary below is the original design.

- One scratch namespace `herdrnetes-exp006-<run-id>`, PSA restricted, with the labels used in EXP-005-RWX.
- Two plain Pods built from one image derived from the EXP-002 image digest, adding pinned `tmux` and
  `openssh-server`. Publishing it to GHCR needs owner approval.
  - `exp006-agent`: tmux plus the counter, and non-root `sshd` on port 2222.
  - `exp006-herdr`: the scratch Herdr, using emptyDir and no PVCs.
- Transport: SSH over a ClusterIP Service.
  - The client key is a throwaway, created per run, with a forced command limited to `tmux attach -t agent` and
    no forwarding.
  - The host key is pinned via known_hosts.
  - NetworkPolicy is default-deny with only Herdr→agent:2222 and DNS allowed.
- Placement: both pods are kept off the live Herdr node and on different nodes from each other.
- Limits: requests 50m CPU / 64Mi memory; limits 500m CPU and 256Mi (agent) or 512Mi (Herdr).
- Tests:
  - K00: read-only preflight and live-baseline capture.
  - K01: start the agent.
  - K02: attach from a scratch Herdr pane.
  - K03: drop the pane and reattach.
  - K04: delete and recreate the Herdr pod, then reattach from a new pane.
  - K05: identity and progress from `counter.log`.
  - K06: label-guarded namespace deletion, positive absence check, and recheck of the live baseline.
- Untouched: the live Herdr StatefulSet and its PVCs, Argo CD and Longhorn.

## Stage 3 (Kubernetes, real agent): run `s3b` PASS for process and conversation continuity (K03 work-while-detached INCONCLUSIVE); `s3a` INCONCLUSIVE (no API credit)

The real-agent test runs in Kubernetes, not locally. The package is [`k8s/stage3/RUNBOOK.md`](k8s/stage3/RUNBOOK.md)
with its manifests (including a Cilium FQDN egress allow for `api.anthropic.com:443` only) and the agent execution
image in [`exec-image-agent/`](exec-image-agent/) (Claude Code 2.1.323 under tmux, an inactive build workflow, and a
no-key, no-egress smoke test). The image was built from `b6e3c92` by owner-dispatched
[CI run 45083319378](https://github.com/jlaska/herdrnetes/actions/runs/45083319378), passed smoke tests A–E before the
push, and is pinned (anonymously pullable) as
`ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18`. Each run
used an owner-created temporary key in a dedicated workspace capped at $5, deleted after the run.

**Run `s3a` (owner-approved G1 at `83e3471`, 2026-11-23 UTC): INCONCLUSIVE.** K00, K00b and K01 passed. Claude Code
2.1.323 started on `claude-haiku-5-5` under PSA restricted with no dialog, and the FQDN egress probes behaved as
designed. The first inference request was rejected with *"Credit balance is too low"*, so the agent did no work and
K03/K04 were not run. Identity stayed `pid=25 start=31889030` throughout; spend $0.00 (owner saw no token spend for the key). K06 cleanup was CLEAN
(baselines byte-identical; the owner revoked the key and shredded the key file). Evidence: [`k8s/evidence/s3a/`](k8s/evidence/s3a/README.md). It was not a test of continuity.

**Run `s3b` (owner-approved retry at `f4197df`, 2026-11-23 UTC): PASS for process and conversation continuity; K03
work-while-detached INCONCLUSIVE; cleanup CLEAN, key deleted.** The runbook gained a billable K00b check and a
footer-independent K02 readiness check. One Claude Code process (`pid=25 start=32103078`, one session, one transcript,
no `--resume`, no exec-pod restart) survived a pane close and the deletion and recreation of the scratch Herdr pod. It
returned the P1-only codeword after both reattachments (Q1, Q2). It completed f07, f08 and `DONE-B` while the Herdr pod
was deleted and no tmux client was attached, about 3 s of work. Haiku finished P1 in 6.5 s, before the pane could be
closed, so work during the pane close itself was not observed. Final task count 8/12. Evidence:
[`k8s/evidence/s3b/`](k8s/evidence/s3b/README.md).

## Stage 3, local bwrap harness (historical preparation, kept, not developed further)

The harness below was the first plan for stage 3. It is superseded by the Kubernetes stage above and is kept as
historical preparation. The original text follows.

[`local/agent-demo.sh`](local/agent-demo.sh) reuses the stage-1 isolation (dedicated tmux socket, disposable Herdr
0.9.5, `env -i` allowlist). In place of the counter, it runs one Claude Code process (`--bare`, isolated
`HOME`/`CLAUDE_CONFIG_DIR`, fixed `--session-id`, never `--resume`) on a synthetic 12-function task in a throwaway
repository ([`local/agent-task/`](local/agent-task/)). It checks:
- that the agent's PID and `/proc` start time stay the same;
- task progress made while Herdr is detached or down, measured by the harness's own check runs and
  `progress.log`;
- conversation continuity, via a codeword that exists only in the first prompt, asked back after each reattach.

Procedure, PASS criteria and credential handling are in [`local/STAGE3.md`](local/STAGE3.md). Claude and every harness
read or execution of agent-written content run under bubblewrap ([`local/sandbox.sh`](local/sandbox.sh), tested without
a credential by `local/agent-task/sandbox-test.sh`; residual risks are in STAGE3.md). The harness and the synthetic task
are statically validated: shellcheck passes and the task self-test passes. Nothing has been run with a credential.
