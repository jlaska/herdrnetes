# EXP-003: Remote access and mobile clients

**Status:** Executed 2026-11-16 (run `r1`): discovery, desktop client tests, and an Ovis sidecar deployed with owner
approval and tested in a browser and mobile emulation. **Not run:** a physical phone (needs the owner and private
network reach) and an Ovis image change or rollback (it would replace the Herdr pod; FIND-029). **Not tested, future
deployment work:** the native `herdr --remote <target>` workflow against the Kubernetes server, which is the owner's
intended desktop experience. It needs an SSH-capable private path that does not yet exist
([#25](https://github.com/jlaska/herdrnetes/issues/25)). Remote attachment was demonstrated only through the tested
`kubectl exec` paths, which remain test and diagnostic mechanisms. Proposed for review; no ADR changes made.
Tracking issue: [#4](https://github.com/jlaska/herdrnetes/issues/4). Builds on
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
  EXP-002 server** without review. It also needs an SSH endpoint, which the pod does not have. Preventing these
  branches is a prerequisite of the native-client deployment work in
  [#25](https://github.com/jlaska/herdrnetes/issues/25).
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
| B | Local `herdr client` ← local Unix socket ← `kubectl exec -i … herdr remote-client-bridge` | None | None observed. The bridge never stops a server and checks status before each connection. `remote-client-bridge` itself would start a server if none were listening, so a check-then-use race remains (FIND-027) | **Works** as a tested path (FIND-031) |
| C | `herdr --remote` via an `ssh` shim that calls `kubectl exec` | None | Install/stop prompts (FIND-026) | Not tested; rejected as a test shortcut |
| D | Native `herdr --remote` over a private SSH path (Tailscale SSH, SSH gateway, sidecar or TCP ingress) | Depends on design; owner approval | Same prompts (FIND-026) | **Not tested:** the target desktop UX, tracked as deployment work ([#25](https://github.com/jlaska/herdrnetes/issues/25)) |
| E | Ovis sidecar in Herdr pod, reached via `kubectl port-forward` | Pod restart (done once with approval), new image, new Secret | Ovis has an "Update herdr" API (must be unused) | **Works** (FIND-035–037) |
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
  No second server was started in these runs, and on detach neither path left a process in the pod. This is genuine attachment to
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
| Browser refresh (Ovis) | Fully preserved (cookie) | Fully preserved | UI back in 0.76 s |
| Port-forward lost 35 s (Ovis) | Fully restored after tunnel restart (manual) | Fully preserved | UI reconnects 1–3 s after tunnel |
| Ovis container restart ×3 | Recoverable: port-forward exits, restart it; cookie valid | Fully preserved, including the w3:p1 agent | ~2 s; 24 s under kubelet backoff |
| Ovis image change or rollback | Not run | Herdr pod would be replaced (FIND-029) | — |
| Planned pod replacement to add Ovis | — | Layout, cwds and the Claude conversation restored; processes replaced (ADR-0001) | sync +166 s after push (polling); Ready 35 s after old pod stopped |

## 5. Ovis browser and mobile results (Milestone 4)

**Owner decisions (2026-11-16, [#4](https://github.com/jlaska/herdrnetes/issues/4)):** prototype Ovis as a container in
the Herdr pod, and accept it for the MVP as an experiment **exception** to REQ-005's separate-pod intent, recording the
upgrade coupling as a limitation. This approval is not an ADR and does not accept a permanent architecture.

**Deployment:** image `ghcr.io/jlaska/herdrnetes-ovis:exp003-o054-h095@sha256:8e31cc27ca866dc47f9cb0f519abce844db8a75974c5d147b91fdbcff46ef0db`,
built from the EXP-002 Herdr digest. Ovis v0.5.4 assets are SHA-256 pinned and the release signature is verified.
Build, overlay and token sealing are in [`experiments/exp-003/`](../../experiments/exp-003/)
([`README-ovis.md`](../../experiments/exp-003/README-ovis.md)). Config: home and workspace read-only, private
`HOME`/state emptyDirs, no Claude credential, `HOST=127.0.0.1`, `OVIS_TOKEN` from an owner-sealed SealedSecret,
telemetry and auto-update off. Rollout was one owner-signed GitOps commit. Before it: a state backup and an identity
capture. After it: the restore check in §4. Per-test details:
[`RESULTS-ovis.md`](../../experiments/exp-003/RESULTS-ovis.md). Clients were Playwright Chromium at 1280×800 and
iPhone 13 / Pixel 7 emulation, over `kubectl port-forward` only. Prompt and approval tests used a disposable Claude Code
2.1.311 agent in `exp003-r1`; the EXP-002 agent received no input.

**Server continuity:** identity was captured after every phase, and the lead agent captured it again independently.
Herdr server PID 7, its start time, the pod UID, Herdr restart count 0, and every pane shell and agent process were
unchanged through three Ovis container restarts and every tunnel outage.

- **FIND-035 — Ovis in the Herdr pod gives working browser and mobile access to the real server.** [observed]
  - Ovis listed the server's real 3 workspaces, 7 panes and 2 agents (matching `herdr api snapshot`).
  - It rendered Claude conversations: the disposable agent's, and the restored EXP-002 conversation, read-only, from
    transcripts on the read-only home via `CLAUDE_CONFIG_DIR`.
  - A prompt sent from Ovis got a reply, verified with `herdr pane read`.
  - It surfaced a Claude permission request as an approval card. The card was answered from the mobile view and the
    file was created.
  - Terminal input and output worked.
  - A desktop and a mobile browser on one pane saw each other's input and output.
  - Mobile layout: a drawer, one pane at a time, a key bar (Esc, Tab, ^C, Ctrl, arrows and symbols). It is usable in
    emulation; a real phone and soft keyboard are untested.
  - The approval only appeared after switching the agent out of the image's default auto-permission mode (FIND-038).
  (REQ-007)
- **FIND-036 — Ovis process lifecycle is independent of Herdr; its upgrade lifecycle is not.** [observed]
  - Restarting the Ovis container took about 2 s, or 24 s under kubelet backoff, and never touched Herdr or an agent.
  - `kubectl port-forward` exits when the container restarts and must be restarted by hand. The browser then
    reconnects by itself.
  - During a 35 s tunnel outage the UI showed "Reconnecting…" and recovered within 1–3 s of the tunnel returning.
  - It also showed a misleading "herdr unavailable" banner for 6–9 s after recovery. Text typed while disconnected, and
    once just after recovery, was **not delivered**: it stays a draft, and Ovis never presses Enter on its own. Users
    must confirm that input landed.
  - An Ovis image change still replaces the Herdr pod (FIND-029); this was not run. Ovis must be rebuilt in lockstep
    with every Herdr image, because its `herdr terminal attach` uses the exact-match private protocol (FIND-024).
  (REQ-005, REQ-007)
- **FIND-037 — With `OVIS_TOKEN` set, loopback is not trusted. The browser cookie *is* the token.** [source, observed]
  This corrects FIND-030's loopback caveat. `decideAccess` (`server/access.ts:278` at `b9d0798`) checks the token before
  the loopback grant. Requests without the token, or with a wrong one, got 401 on `/api/session` and `/ws`, from
  127.0.0.1 and from the pod IP. `/api/health` is open and shows versions and auth state only. The sign-in sets an
  HttpOnly, SameSite=Strict `ovis_token` cookie containing the **raw token**, valid for about a year
  (`server/auth.ts:142-143`). Consequences:
  - There are no per-browser sessions.
  - Revocation means rotating the token, which signs out every browser. That needs a re-seal, a signed commit and an
    Ovis container restart, but not a Herdr restart.
  - A lost phone or browser profile is a lost token.
  - Paired-device credentials are a separate credential, stored in `devices.json` in Ovis's state emptyDir. They
    survive an Ovis container restart and a token rotation, and are lost only when the pod is replaced. Pairing was not
    tested. (Corrected: an earlier draft said a container restart revokes pairings.)
  Two `/proc/net` snapshots showed no non-loopback connections; this is point-in-time evidence, not a capture.
  (REQ-007)
- **FIND-038 — Agents in this image start in Claude Code's auto-permission mode, so no approvals reach any client.**
  [observed] The disposable agent raised no permission prompts until it was cycled to manual mode (shift+tab). Remote
  approval from a phone is only meaningful if the agent's permission mode asks for approval. That mode is set by
  configuration, not by the access path, so it belongs in the agent configuration baseline. Unrelated, but seen in
  passing: Claude warns that cross-session messaging is off, because `/tmp` in the pod is mode 2777 with no sticky bit.

### Browser and mobile functionality matrix (Ovis 0.5.4, Herdr 0.9.5)

| Capability | Desktop browser | Mobile emulation | Physical phone |
| --- | --- | --- | --- |
| Token sign-in, cookie survives refresh | Works | Works | Untested |
| Real workspaces, panes and agents | Works | Works | Untested |
| Claude chat rendering, including restored history | Works | Works | Untested |
| Send prompt | Works | Works | Untested |
| Approval card | Works (manual-permission agent) | Works, answered here | Untested |
| Terminal view and input, special keys | Works | Works (key bar; synthetic keys) | Soft keyboard untested |
| Two browsers on one pane | Shared input and output | Shared | Untested |
| Reconnect after tunnel or Ovis loss | Automatic once the tunnel is back; drafts not sent | Same | Untested |

## 6. Security and network analysis

| Concern | Desktop path B | Ovis path E |
| --- | --- | --- |
| Identity and authorization | Kubernetes user + RBAC `pods/exec` on `herdr-0` | RBAC `pods/portforward`, then a shared static `OVIS_TOKEN` |
| What a holder controls | **Full trusted Herdr operator:** every pane and agent (FIND-025), plus any command in the Herdr container | **Full trusted Herdr operator, same as B.** Terminal input to every pane means any shell command as uid 1000 in the Herdr container. Also read access to the transcripts. |
| Network exposure | None beyond the Kubernetes API | None: loopback listener, `kubectl port-forward`, NetworkPolicy unchanged |
| Transport security | Kubernetes API TLS | Kubernetes API TLS to the pod; plain HTTP on workstation loopback |
| Credential lifetime and revocation | The kube credential's | Token stored in browser cookie for about a year; revoke by rotation (FIND-037) |
| Concurrent users | One operator; shared focus and input (FIND-033) | Same; shared input |
| Claude and agent credential exposure | **Exposed.** `kubectl exec` runs in the Herdr container, whose environment holds `CLAUDE_CODE_OAUTH_TOKEN` | **Exposed through the panes.** Ovis does not inherit the credential, but a token holder can type commands into a pane to print its environment, read agent files and home-volume secrets, or act as the agent |
| Residual risks | Undocumented bridge interface | "Update herdr" API with no off switch, contained only by read-only rootfs and no `curl`; a token holder could enable the relay; single-maintainer, fast-moving project; Ovis image must track Herdr |

**Security boundary.** An Ovis token is not a viewing credential. Holding it gives effectively the same privilege as
a trusted Herdr operator with `pods/exec`, including access to any secret a pane can read. The read-only mounts, the
separate container environment and the absence of `CLAUDE_CODE_OAUTH_TOKEN` from Ovis limit what the Ovis *process*
holds. They are **not an authorization boundary** against a user with full PTY control. Protect, rotate and revoke the
token, and any paired device, as an operator credential.

**Recommendation for MVP review (a proposal, not a decision):**
- **Desktop, tested:** paths A and B work and are gated by RBAC on `pods/exec`. They are suitable for tests, diagnosis
  and operator fallback, but are not the intended everyday workflow. The intended workflow is native
  `herdr --remote <target>` with no user-visible `kubectl`. It is **not tested** and is a deployment follow-up
  ([#25](https://github.com/jlaska/herdrnetes/issues/25)): it needs an SSH-capable private path (plain HTTP ingress
  cannot carry it) and a resolution of FIND-026.
- **Browser and mobile:** the Ovis sidecar on loopback behind `kubectl port-forward`, with an owner-sealed token.
- **No public ingress or relay.** No SSH endpoint exists until #25 has an owner-approved design.
- **Phone reach:** needs a private route to the Kubernetes API, or to a host that holds the port-forward. That network
  choice (VPN or Tailscale) is the owner's and is the next approval gate. If Ovis is ever exposed beyond loopback, it
  needs TLS and per-device pairing in place of the shared token.

**Token exposure, urgent operator action:** during browser automation, a Playwright error message echoed the Ovis
token into an agent transcript. It was never written to a file or the repo. It was treated as **exposed** and
rotated on 2026-11-16, by the owner-run procedure in
[`README-ovis.md`](../../experiments/exp-003/README-ovis.md#token-rotation-owner-run). The procedure restarts only the
Ovis container, never the Herdr pod. Afterwards the old token got 401 and the new one 200. Before the container
restart, the running Ovis still accepted only the old token, which confirms that updating a Secret does not change a
running environment. The Herdr identity diff was unchanged
([#22](https://github.com/jlaska/herdrnetes/issues/22)). Later scripts redact exceptions.

## 7. Traceability

| Requirement | Findings | Status |
| --- | --- | --- |
| REQ-001 One unified Herdr server | FIND-031, 033, 035 | **Met:** every client attached to the one server |
| REQ-005 Optional services in independent pods | FIND-028, 029, 036 | **Partly met.** REQ-005's intent (separate pods) is unchanged. A separate pod is impossible with Herdr 0.9.5 and Ovis 0.5.4. The Ovis sidecar is an owner-approved **experiment exception**, not an accepted architecture or ADR. Its process lifecycle is independent; its upgrades replace the Herdr pod |
| REQ-007 Remote client and mobile browser access | FIND-023–027, 031–038 | **Partly met.** Remote attachment to the one server works through the tested `kubectl` paths A and B, and browser plus mobile emulation works through Ovis. **Not tested:** native `herdr --remote` without user-visible `kubectl` ([#25](https://github.com/jlaska/herdrnetes/issues/25)), a physical phone, and private remote reach |
| REQ-002 Pinned images | FIND-024, 034, 036 | Clients upgrade independently within endpoint generation 1; Ovis must be rebuilt with Herdr |

## 8. Follow-ups

| Topic | Findings | Issue |
| --- | --- | --- |
| Native `herdr --remote` over a private SSH path (deployment) | FIND-023–027 | [#25](https://github.com/jlaska/herdrnetes/issues/25) |
| Physical phone over an owner-approved private network path | FIND-035, 037 | [#20](https://github.com/jlaska/herdrnetes/issues/20) |
| Transport for browser services in separate pods (REQ-005) | FIND-028, 029, 036 | [#21](https://github.com/jlaska/herdrnetes/issues/21) |
| Ovis hardening (token rotated 2026-11-16) (update API, relay, lockstep builds) | FIND-030, 036, 037 | [#22](https://github.com/jlaska/herdrnetes/issues/22) |
| Agent permission-mode baseline, `/tmp` sticky bit | FIND-038 | [#23](https://github.com/jlaska/herdrnetes/issues/23) |
| Multi-client focus hazard, stall tolerance, harness pane identity | FIND-032, 033 | [#24](https://github.com/jlaska/herdrnetes/issues/24) |
