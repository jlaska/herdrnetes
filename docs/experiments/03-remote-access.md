# EXP-003: Remote access and mobile clients

**Status:** In progress. Milestone 1 (discovery) and Milestone 3 (desktop client tests, run `r1`) are complete.
Ovis/mobile work (Milestone 4) awaits an owner decision. Proposed for review; no ADR
changes made. Tracking issue: [#4](https://github.com/jlaska/herdrnetes/issues/4). Builds on
[EXP-002](02-kubernetes-deployment.md) (FIND-013–022).

Determine whether desktop SSH/Herdr clients and mobile tools such as Ovis can attach to one persistent unified Herdr
server, with secure authentication and useful pane/session behavior. Keep optional integration services in
independently updated pods. Test reconnect and detach behavior; distinguish client failures from server or agent
failures.

Evidence types: **[observed]** = measured here (against the cluster unless marked *locally*), **[source]** = read in
upstream code at the pinned tag, **[docs]** = upstream documentation, **[inference]** = our reasoning, not yet tested.
Raw evidence stays private. Cluster, node and GitOps-repository names are withheld.

**Requirements:** REQ-001, REQ-005, REQ-007.

## 1. Baseline (the server every test must leave running)

Recorded 2026-11-16 by read-only `kubectl get`/`exec` and verified independently. Every client and service test below
re-checks these identities before and after.

| Item | Value |
| --- | --- |
| Workload | EXP-002 StatefulSet `herdr`, pod `herdr-0`, namespace `herdrnetes-exp`, restart count 0 |
| Pod UID | `7e91a13b-13d7-433b-a713-a5703e6a3fcc` |
| Image | `ghcr.io/jlaska/herdrnetes-herdr:exp002-h095-c311@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277` (Herdr 0.9.5, Claude Code 2.1.311, Codex 0.169.0) |
| Server process | PID 7 `/usr/local/bin/herdr server` (child of `tini`), started 13:18:58Z |
| Sessions | 2 workspaces, 3 tabs, 5 panes, 1 Claude agent (PID 85, state `done`) |
| Sockets | `/home/herdr/.config/herdr/herdr.sock` (API) and `herdr-client.sock` (UI client), both `0600`, uid 1000 |
| `herdr status server --json` | `endpoint_protocol_generation: 1`, `protocol: 22`, `detached_server_daemon: false`, `restart_needed: false`, capabilities `surface_interest`, `health_check`, `live_handoff` |
| Network | Only NetworkPolicy `deny-ingress` (all ingress denied). Headless Service with no ports. No ServiceAccount token |
| Image tools | `ssh` client, `python3`, `bash`, `herdr`. **No** `sshd`, `socat`, `nc`, `curl`, `node`, `tmux`, `ttyd` |

## 2. Discovery findings (Milestone 1)

Sources: Herdr `v0.9.5` (commit `2ecf19a`), Ovis `v0.5.4` (commit `b9d0798`). Herdr facts were checked locally with an
isolated 0.9.5 server; none of the Ovis behavior has been run yet.

- **FIND-023 — A Herdr UI client needs only a byte stream to `herdr-client.sock`; Herdr 0.9.5 ships the bridge.**
  [source, observed locally] The wire format is a length-prefixed bincode stream. `herdr remote-client-bridge` (hidden
  subcommand, `src/remote/host.rs`) copies stdio to the local client socket. `herdr client` (hidden, `src/main.rs`)
  connects to `HERDR_CLIENT_SOCKET_PATH` and never starts a server. `herdr --remote` is just these two joined by
  `ssh -T target "exec herdr remote-client-bridge"`. So `kubectl exec -i herdr-0 -- herdr remote-client-bridge` should
  stand in for SSH **without any change to the pod, image or NetworkPolicy**. Caveat: both subcommands and the
  `HERDR_REMOTE_*` variables are undocumented internals and may change between releases. (REQ-007)
- **FIND-024 — Client compatibility is negotiated by endpoint generation, not by Herdr version.** [source]
  The UI handshake (`endpoint.hello.v1`/`welcome.v1`) only requires generation 1 and a shared codec. A mismatch makes
  the *client* exit with "update this machine"; it never changes the server. The private protocol (22) is matched
  exactly, and only for direct-terminal attach and live handoff. Implication: clients of other versions may attach,
  which Milestone 3 must test, and client upgrades are decoupled from the pinned server. (REQ-002, REQ-007)
- **FIND-025 — Socket permissions are Herdr's only access control.** [source, observed] There is no token or user
  identity. Anyone who can run a process as uid 1000 in the pod, which includes holding RBAC `pods/exec` on it, has
  full keystroke control of every pane and agent. Every remote path is therefore exactly as secure as the transport
  that carries it to the socket. (REQ-007)
- **FIND-026 — `herdr --remote` / saved machines can install Herdr and offer to stop the remote server; there is no
  switch to disable this.** [source] It probes the target over `ssh`, offers to download into `~/.local/bin/herdr`
  when no binary is found, and asks "stop and update?" (default No) when it judges that the server needs a restart. A
  stop kills every pane. Non-interactive and background reconnects never install or replace. The remote binary path
  cannot be overridden. Our server reports `restart_needed: false`, but whether the client-side restart policy agrees
  for a server that is not a session leader (`detached_server_daemon: false`) is unverified. **Not used against the
  EXP-002 server** without review. It also needs an SSH endpoint, which the pod does not have.
- **FIND-027 — Bare `herdr` inside the pod attaches to the running server.** [source, observed locally] It checks
  whether the client socket is listening and attaches if it is. It starts a new server only when nothing is listening
  there. The container environment sets `XDG_CONFIG_HOME`, so `kubectl exec` resolves the same socket. Residual risk:
  running it while the server is down, for example mid-restart, would start a second, unsupervised server in the
  container.
- **FIND-028 — Ovis v0.5.4 cannot run in a separate pod from Herdr.** [source, inference] Ovis drives Herdr over the
  API Unix socket (JSON RPC) and runs `herdr terminal attach` as a subprocess, so it needs the socket and a matching
  `herdr` binary. It renders chat by reading Claude transcripts from `~/.claude/projects` on disk. It has no TCP
  transport to Herdr. Its only remote mode SSHes to a host and installs its bridge bundle there, which would need
  `sshd` plus a download in our pod. A socket on a shared RWO PVC is not a cross-pod transport. The feasible
  topologies are a second container in the Herdr pod or a second process in the Herdr container. (REQ-005, REQ-007)
- **FIND-029 — Running Ovis in the Herdr pod conflicts with independent upgrades.** [inference from Kubernetes
  semantics] An Ovis container can restart alone, but changing its image in the StatefulSet template replaces the whole
  pod. That stops every Herdr pane and agent (ADR-0001 accepts this only for Herdr upgrades). Under REQ-005, Ovis would
  have an independent process lifecycle but not an independent upgrade lifecycle. (REQ-005)
- **FIND-030 — Ovis's default configuration is unsafe for this environment.** [source]
  - Connections from loopback need no authentication. A `kubectl port-forward` arrives as loopback, and so does every
    agent shell in the pod.
  - Telemetry is on by default (`OVIS_TELEMETRY`).
  - It checks GitHub for updates and has an in-app button that runs `herdr update`.
  - An opt-in usage panel sends the Claude OAuth token to Anthropic's usage API.

  Required settings: an `OVIS_TOKEN` from a Secret (the token is readable by any process allowed to read it),
  `OVIS_TELEMETRY=0`, `DO_NOT_TRACK=1`, `OVIS_AUTO_UPDATE=0`, the relay left off, and no `CLAUDE_CODE_OAUTH_TOKEN` in
  its environment. Ovis does not need the Claude credential. Single maintainer, rapid release cadence (v0.5.4 dated
  2026-11-15).

## 3. Candidate access paths

| # | Path | Pod/network change | Server-replacement risk | Status |
| --- | --- | --- | --- | --- |
| A | `kubectl exec -it herdr-0 -- herdr` (TUI runs in the pod) | None | None while server is up (FIND-027) | **Works** (FIND-031) |
| B | Local `herdr client` ← local Unix socket ← `kubectl exec -i … herdr remote-client-bridge` | None | None; bridge refuses an incompatible server, never stops one | **Works**, preferred desktop path (FIND-031) |
| C | `herdr --remote` via an `ssh` shim that calls `kubectl exec` | None | Install/stop prompts (FIND-026) | Rejected for the shared server |
| D | `sshd` sidecar + native `herdr --remote` / saved machines | Pod restart, new SSH identity, ingress rule | Same prompts | Needs owner approval; deferred |
| E | Ovis sidecar in Herdr pod, reached via `kubectl port-forward` | Pod restart, new image, new Secret | Ovis has an "Update herdr" button (must be unused) | Needs owner approval (FIND-028–030) |
| F | Ovis on the workstation over B-style bridges to both sockets | None | Same as B | Terminal only; no chat (transcripts are not local). Optional |
| G | Web terminal (ttyd-like) running path A | Pod restart or exec'd process | None | Fallback if Ovis is rejected |

**Authentication model under consideration for the MVP:** Kubernetes RBAC on `pods/exec` (and `pods/portforward` for a
browser service) is the only gate, and it is already narrower than any network exposure. It reuses the owner's existing
kube credential, adds no ingress, and needs no NetworkPolicy change. Remote access from outside the workstation
(mobile) would then depend on reaching the Kubernetes API privately (VPN/Tailscale), which requires owner approval.

## 4. Desktop client results (Milestone 3)

Run `r1`, 2026-11-16 17:08–17:28Z. Harness: [`experiments/exp-003/`](../../experiments/exp-003/). Per-test table,
commands and verbatim client messages: [`RESULTS.md`](../../experiments/exp-003/RESULTS.md). Tests used one disposable
workspace (`exp003-r1`) with `sleep` and ticker sentinel panes. The pre-existing panes and the Claude agent received no
input. Clients: Herdr 0.9.5 (workstation), 0.9.4 and 0.8.0 (binaries from the EXP-002 image variants), driven in a
private tmux server with its prefix disabled.

**Server continuity:** `identity-diff` was run against the baseline after every step, 17 captures in all. The lead
agent also ran an independent capture afterwards. Every capture showed the same pod UID, restart count 0, server PID 7
with an unchanged start time (`13:18:58Z`), the same shell PID in every pre-existing pane, and the same Claude process
and session hash.

- **FIND-031 — A workstation Herdr client attaches to the existing Kubernetes server with no pod, image or network
  change.** [observed] Both path A (`kubectl exec -it … herdr`) and path B (local `herdr client` through
  `kubectl exec -i … herdr remote-client-bridge`) showed the server's real workspaces (the two EXP-002 workspaces plus
  `exp003-r1`). Input reached the sentinel pane without changing that pane's shell PID, and the ticker output was live.
  No second server was started, and on detach neither path left a process in the pod. This is genuine attachment to
  the one authoritative server, not a separate session. The transport and the authentication are both
  `kubectl exec`, so Kubernetes RBAC is the only gate. (REQ-001, REQ-007)
- **FIND-032 — Losing a client never affected the server or its panes; reconnecting is manual and fast.** [observed]
  Server and panes were **fully preserved** after each of these:
  - clean detach (prefix `q`);
  - SIGKILL of the local client;
  - SIGKILL of the `kubectl` transport, which simulates an SSH or network drop;
  - a 60 s transport stall (SIGSTOP), after which `kubectl` failed with an i/o timeout;
  - 628 s attached and idle, during which the client stayed live with no stream timeout.

  The client is **Recoverable**: after a lost transport it exits, prints `lost connection to remote Herdr` and the
  reattach command, and does not reconnect automatically. Rerunning that command took about 0.5 s. A frozen display
  gives no stall indicator. A killed client leaves the local terminal needing `reset`. The stall tolerance below 60 s
  was not measured. (REQ-007)
- **FIND-033 — Clients see separate workspaces but share pane focus, input, size and scroll, so concurrent clients
  are for one operator, not for collaboration.** [observed]
  - Each client keeps its own selected workspace, but the server keeps one focused workspace and pane. After client B
    switched to another workspace, the server's focus moved there while client A still displayed `exp003-r1`.
    Keystrokes typed in A in that state might go to a pane A is not showing. That was not tested; input was sent only
    after the snapshot confirmed focus. **Hazard.**
  - Text typed in either client appeared in both, in order. There is no input ownership.
  - The layout takes the size of whichever client most recently focused or scrolled, not the one that typed. When
    one client detaches, the survivor's size applies.
  - The copy-mode scroll offset is held on the server and shared between clients.

  For agents this means: don't attach a phone and a desktop client to drive different panes at the same time, and
  don't treat several attached people as isolated users. (REQ-007)
- **FIND-034 — Client version skew degrades on the client side only.** [observed] A 0.9.4 client attached normally
  to the 0.9.5 server. A 0.8.0 client, which predates the endpoint handshake (protocol 19, no endpoint generation), was
  rejected within 0.3 s with `server closed connection`. Nothing was installed or replaced. The pod binary's version and
  mtime were unchanged, and the server logged nothing. This confirms FIND-024: workstation clients can be upgraded
  independently, within endpoint generation 1. (REQ-002, REQ-007)

Practical notes: Herdr's default prefix `ctrl+b` collides with tmux, so inside tmux either remap one of them or send
the prefix twice. The bridge's `kubectl` child sometimes exited with status 1 after a clean detach, with no effect on
the client or the server; the cause is unknown.

### Lifecycle matrix (client and server continuity)

| Event | Client | Server and pane processes | Measured |
| --- | --- | --- | --- |
| Clean detach | Recoverable (rerun) | Fully preserved | detach under 2.5 s |
| Client SIGKILL | Recoverable (rerun, `reset`) | Fully preserved | bridge cleaned up in 8 ms |
| Transport killed (SSH/network drop) | Recoverable (printed command) | Fully preserved | reattach about 0.5 s |
| Transport stalled 60 s | Recoverable after the timeout | Fully preserved | not measured below 60 s |
| Idle 10 min | Fully preserved | Fully preserved | 628 s |
| Second client attached and detached | Survivor unaffected | Fully preserved | — |
| Older client (0.9.4) | Works | Fully preserved | — |
| Pre-endpoint client (0.8.0) | Lost (unsupported) | Fully preserved | rejected in 0.3 s |
| Browser refresh, Ovis restart, Ovis image change | Pending Milestone 4 | — | — |
