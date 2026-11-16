# EXP-003 Milestone 4: Ovis sidecar tests (run r1, 2026-11-16 UTC)

Sanitized: no token, hostnames, session ids or conversation text beyond the prompts below. Raw evidence (screenshots,
session JSON, `/proc/net` snapshots, Playwright scripts' output) is in `~/.local/share/exp003/r1/ovis/`, outside the repo.
Status of every claim: **observed** unless marked. Relates to FIND-028..030 and access path E in
[`docs/experiments/03-remote-access.md`](../../docs/experiments/03-remote-access.md); README-ovis.md describes the candidate.

## Environment
- Pod `herdr-0` (uid `a3542452-...`), containers `herdr` (image digest `sha256:c5a235ae...e8d277`, Herdr 0.9.5, server PID 7)
  and `ovis` (digest `sha256:8e31cc27...ef0db`, Ovis 0.5.4 on 127.0.0.1:7317, token-gated, `OVIS_TELEMETRY=0`).
  Pod age at start about 2 min; `herdr` restartCount 0 throughout; pod uid unchanged.
- Agents: EXP-002 Claude (w2:p2, untouched, no input sent) and disposable Claude Code 2.1.311 `--model haiku` in `w3:p1`
  (`/workspace/exp003/r1`, started 18:55Z, trust dialog answered "Yes, I trust this folder"). `herdr agent list` showed it.
- Client: Playwright (Python) with Chrome Headless Shell 159.0.8154.6; desktop 1280x800, mobile emulation iPhone 13
  (390x664 CSS px, touch) and Pixel 7 (screenshots only). Real soft keyboards and real touch devices were **not** used.
- Access: `kubectl --context $CTX -n herdrnetes-exp port-forward pod/herdr-0 7317:7317` (localhost only). The token was read
  from `~/.local/share/exp003/ovis-token` inside scripts; sign-in used the login form (`Have an access token instead?`),
  which sets an HttpOnly `ovis_token` cookie, so later tests ran on the cookie, not on a header. M1 used a Bearer header.
- Identity: `scenario.sh identity r1 <label>` / `identity-diff r1 post-ovis <label>` before/after each phase
  (labels `ovis-t0`, `ovis-m3a`, `ovis-m4`, `ovis-m9`, `ovis-m10`, `ovis-m11`).

## Commands (token never shown)
- `uv run --with playwright playwright install chromium`; each test is a PEP 723 script run with `uv run --script`.
- API checks: `GET /api/session`, `GET /api/health`, `GET ws://127.0.0.1:7317/ws` with no header, `Authorization: Bearer <43 x "x">`,
  and `Authorization: Bearer <token>`.
- Agent: `herdr pane run w3:p1 "cd /workspace/exp003/r1 && claude --model haiku"`; trust dialog: `pane send-keys down`, `enter`.
  Permission mode was cycled with `pane send-keys w3:p1 shift+tab` (see M5).
- Ovis restart: `kubectl exec herdr-0 -c ovis -- kill -TERM 1`. Network: `kubectl exec herdr-0 -c ovis -- cat /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6`
  plus `readlink /proc/*/fd/*` for socket inodes.

## Results
Continuity classes: Fully restored / Recoverable / Lost. "Server" = Herdr server, panes and agents.

| Test | Time (UTC) | Observation | Client continuity | Server continuity | identity-diff vs post-ovis |
| --- | --- | --- | --- | --- | --- |
| M1 Auth | 18:54:28 | `/api/session` and `/ws`: no token 401, wrong token 401, valid token 200 / WS open. `/api/health` is open: Herdr version/protocol, `auth.required`, web_ui boot id; with a valid token it adds Ovis version 0.5.4, `relay.phase: off`, `security.bind_scope: loopback`, `pairing_gate: open`, `role: drive`. No secret in it. | n/a | n/a | ovis-t0 unchanged |
| M2 Visibility | 18:54 | `/api/session` snapshot vs `herdr api snapshot`: 3 workspaces, 4 tabs, 7 panes, 2 agents in both; labels alpha, beta, exp003-r1; agents w2:p2 and w3:p1. Real data, not demo. | n/a | n/a | n/a |
| M3 Chat render | 18:55-18:58 | New w3:p1 agent: Chat view renders (empty state, then conversation). EXP-002 agent (w2:p2, resumed session): Chat view rendered its last turns (question and answer) from the transcript; nothing sent. So read-only transcript access via `CLAUDE_CONFIG_DIR` works. Chat mode is per pane and the toggle applies to the focused pane, so a click on the target pane is needed first. | n/a | n/a | ovis-m3a: only expected additions (w3:p1 agent) |
| M4 Prompt | 18:57:02 send | "Reply with exactly the word PONG." sent from the Chat composer (Enter). Ovis showed "Working..." then the reply `PONG` (conversation title auto-set to "PONG reply test"). `herdr pane read w3:p1`: `> Reply with exactly the word PONG.` / `PONG` / `done 6:57 PM`. | Fully restored | Fully restored | ovis-m4 same |
| M5 Approval | prompt 18:59:22, approved 19:02:10 | Claude defaulted to "auto mode"; auto mode surfaces no prompt, so I cycled to "manual mode" (shift+tab x6 through manual/accept edits/plan/auto). Ovis then showed a "Needs you" card ("Bash command / Do you want to proceed?") with the command and options 1 Yes (this time only), 2 Yes always allow, 3 Yes and switch to auto, 4 No. Sidebar and status bar showed "1 waiting for you". The prompt stayed pending 2m48s with no browser open. Approved with option 1 from the mobile emulation. `/workspace/exp003/r1/ovis-approval.txt` exists, content `ok`. The w3:p1 Claude is left in manual mode. | Fully restored | Fully restored | same |
| M6 Terminal | 19:02:35 | Terminal view of w3:p2: typed `echo ovis-term-ok`, output shown; `herdr pane read w3:p2` shows the same. | Fully restored | Fully restored | same |
| M7 Reload | 19:03:09 | Same context reload: no login page, UI back in 0.76 s, selected workspace, Chat mode (stored per browser) and terminal history all restored; terminal accepted input after reload (`echo after-reload` in pane). Cookie: `ovis_token`, HttpOnly, SameSite=Strict, not Secure (plain http), expires about 1 year. Chat/terminal mode does **not** carry to a new browser context. | Fully restored | Fully restored | same |
| M8 Two browsers | 19:02:35 | Desktop and mobile contexts on w3:p2: output from either appears in both within 2 s; input from mobile appeared on desktop and the pane, and vice versa. Selection/mode are per browser. Unlike the Herdr clients of FIND-033 I did not test conflicting sizes. | Fully restored | Fully restored | same |
| M10 Port-forward loss | 19:04:13 and 19:05:19 | Killed the port-forward with a page open. After about 5 s: "Reconnecting to Ovis..." badges on every pane and the status bar, for the full 35 s outage. On restart, the page reconnected within about 1-3 s with no login. A red "Failed to fetch / herdr unavailable" banner (misleading: Ovis, not Herdr, was unreachable) stayed up for about 6-9 s after the link returned, then cleared. Text typed while down was held in a draft chip ("An Enter or line break was left out: Send never presses Enter") and was **not** delivered, and an echo typed about 3 s after recovery, while the banner was still shown, also did not reach the pane (run 1; run 2, typed after the banner cleared, worked). Panes, agents and Ovis unaffected. | Fully restored (reconnect), typed-while-down input Lost | Fully restored | ovis-m10 same |
| M11 Ovis restart | 19:10:34, 19:13:28, 19:15:12 | Three `kill -TERM 1` restarts. Run 1: container restarted, `Ovis listening` log at 19:10:36.7, about 2 s after the kill. Run 3: restartCount increment at +24.4 s because kubelet crash-loop backoff grew after back-to-back restarts. `kubectl port-forward` **exits** when the container restarts ("lost connection to pod", within 1.5 s), so the tunnel must be restarted by hand; health was 200 0.6 s after that. Browser: the `ovis_token` cookie still worked (no re-login, fresh page also had no login), page showed Reconnecting then Connected 3 s after the tunnel returned, terminal input worked afterwards, Chat history intact. `HOME=/var/lib/ovis` is an emptyDir so Ovis state (settings, any pairings) survives container restarts but not pod replacement; **pairing was not tested**. | Recoverable (tunnel restart is manual; browser auto-recovers) | Fully restored | ovis-m11: server PID 7 / start ticks, pod uid, herdr container restartCount 0, w2:p2 claude and w3:p1 claude (PID 704, start ticks unchanged) all unchanged |
| M12 Egress | 19:10:11, 19:16:11 | `/proc/net/tcp{,6}` in the pod netns: one LISTEN 127.0.0.1:7317 (fd owned by the Ovis process, pid 7 in the ovis container) and TIME_WAIT loopback pairs on 7317 (the port-forward and browsers). UDP and raw tables empty. No ESTABLISHED socket and no non-loopback address at either snapshot. Ovis logs contain only `client.connection_trace`, `websocket.failed` events, and the startup banner. Caveats: two point-in-time snapshots cannot see short-lived connections; the herdr and ovis containers share a netns, so attribution here rests on the listener's fd owner and the absence of any remote endpoint. | n/a | n/a | n/a |

Not run: Ovis image change / rollback (replaces the pod, FIND-029); relay, app.ovis.sh pairing, subscription usage, voice,
"Update herdr" (never invoked); local device pairing; real phone, real soft keyboard.

## Functionality matrix

| Function | Desktop 1280x800 | Mobile (iPhone 13 emulation) |
| --- | --- | --- |
| Sign in with token, cookie persists | Works | Works (a "Add to Home Screen for alerts" banner is shown; dismissible) |
| Workspace list / agent list | Persistent sidebar, tabs, split panes | Slide-out drawer; one pane at a time; Agents group collapsed, "1 need you" shown in red |
| Chat render and prompt | Works, per-pane toggle | Works; toggle is a header button |
| Approval card | Works, "1 waiting for you" badge | Works, options 1-4 tappable, first-run approval done here; long commands truncate with an ellipsis |
| Terminal | Works | Works; bottom key bar: keyboard, paste, input-line, Esc, Tab, ^C, Ctrl, plus a "More keys" row with `\|`, `~`, `/`, `-` and arrows (Pixel 7 emulation) |
| Concurrent browsers | Yes | Yes |
| Reload / reconnect | Yes | Reconnect logic is shared |
| Usability notes | Terminal and Chat for a given pane share one toggle; focus is by click on the pane header | Usable; the chat composer, approval card and key bar fit; only synthetic key events were tested, so soft-keyboard behaviour (viewport resize, autocorrect, IME) is **unverified** |

## Findings (proposed for review; none accepted)
- **FIND-035 (proposed)** Ovis 0.5.4 behind a token and `kubectl port-forward` provides a working remote terminal, chat, prompt and approval UI against
  the real Herdr server, without any change to Herdr or agent processes (identity unchanged through every test).
- **FIND-036 (proposed)** Approvals surface only when the agent is not in auto mode. Defaults matter: a new Claude in this image starts in auto mode.
- **FIND-037 (proposed)** `kubectl port-forward` is the weak link: it dies with an Ovis container restart and gives no auto-reconnect; the Ovis UI
  recovers by itself once the tunnel is back, but input typed while disconnected is held as an unsent draft.
- **FIND-038 (proposed)** The Ovis restart is cheap (about 2 s, then backoff up to tens of seconds) and does not affect agents or sessions; the
  cookie stays valid because the token is unchanged.
- Side observation: Claude Code prints "Cross-session messaging is off" because `/tmp` in the pod is mode 2777 (no sticky bit); unrelated to Ovis.

## Security notes
- The Ovis token was exposed once in this agent session's own tool output (a Playwright error log echoed a `fill()` value). It was not committed or saved
  to any file. Treat it as **exposed** and rotate it promptly, using the owner-run checklist in
  [`README-ovis.md`](README-ovis.md#token-rotation-owner-run); tracked in #22. All later scripts redact exceptions.
- A token holder has full trusted-operator control of every pane, including commands that can read in-pane
  credentials. See the README-ovis security boundary section.
- Screenshots in the private evidence directory include conversation text and workspace names; keep them out of the repo.
