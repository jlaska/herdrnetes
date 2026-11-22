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

## Findings (owner review 2026-11-22: FIND-071/072 accepted as local findings; FIND-073 limited to the CLI-help survey)

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

## Limitations and open questions

- Local only; no Kubernetes, SSH transport or real agent yet (stages 2 and 3 below are **NOT TESTED**).
- Herdr shows the attached session as an ordinary pane. It has no agent status or transcript integration. These are
  future enhancements and were not attempted.
- Reattach after a Herdr restart is manual. Automating it (pane command, shell rc, or Herdr's own agent-resume
  hook) is an open question, not a requirement here.
- Only the tmux server's lifetime was tested. A tmux server crash would still lose the process. Survival of the
  execution host or pod itself is out of scope.

## Stage 2: Kubernetes slice (image built; G1 package ready for review, NOT TESTED)

The review package is [`k8s/RUNBOOK.md`](k8s/RUNBOOK.md), with [`k8s/manifests/`](k8s/manifests/), the execution image
[`exec-image/`](exec-image/), and a proposed build workflow kept as an inactive copy at
[`exec-image/proposed-workflow-exp006-exec-image.yml`](exec-image/proposed-workflow-exp006-exec-image.yml). The owner
installs it under `.github/workflows/`, because the agent token cannot write workflows.

The execution image is built and public:
`ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16`, from source
`35369c2`. It came from owner-dispatched [CI run 45033107115](https://github.com/jlaska/herdrnetes/actions/runs/45033107115),
in which the four docker-based SSH/PTY smoke tests passed. Nothing has been applied to Kubernetes. The manifests pass
`kubeconform -strict` for 1.36. The scratch Herdr pod uses the EXP-002 image unchanged. The image survey found no
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

## Stage 3: real agent (NOT TESTED)

Once stage 2 passes, run Claude Code or Pi in the tmux session, with credentials approved separately. Check that its
PID survives Herdr's absence, and that a task keeps progressing while detached.
