# EXP-001 run log

Observed results recorded as each run completed (2026-11-15, Fedora 44, Herdr 0.9.5
Homebrew unless stated). Raw evidence stayed in the disposable run directories
(`/tmp/hx1/<run>/evidence`) and is not committed because pane screens and Herdr logs
can contain private paths and agent conversation text. Claude session IDs are redacted.

## b-clean — Scenario B, clean stop (`herdr server stop`), osc7=0, pane_history=0

- Layout: 3 workspaces / 4 tabs / 6 panes, split geometry, workspace + tab + pane labels: **restored**.
- Cwd of every pane, including `cd sub` done inside a pane: **restored**.
- Foreground `sleep 86400` and background `python -m http.server`: **lost**; no survivors after stop.
- Panes come back as fresh shells (new PIDs). Screens empty (pane_history off).
- Exported variable `EXP_VAR`: **lost** (`ENVCHECK EXP_VAR=[]`).
- Bash `HISTFILE`: commands typed before stop **were written** (0 → 4 MARK lines) — bash saves history on SIGHUP, which Herdr sends to every pane at stop.
- Git working tree (modified + untracked files): unchanged (filesystem, not Herdr).
- Log: `server shutdown initiated reason=server.stop request from pid …`, final `session saved`, each pane `ExitStatus { code: 1, signal: Hangup }`; restart logs `session restore evaluated outcome=ok workspaces=3`.
- One `session-snapshots/` copy created at the first save.

## h-hist — pane_history=true, clean stop then SIGKILL

- `session-history.json` written beside `session.json` (1408 bytes; contains terminal output).
- After clean restart: previous screen text **replayed** on the 4 panes that had output.
- After SIGKILL (7 s after restart): screens replayed again, but `session.json` and `session-history.json`
  mtimes were still those of the earlier clean stop — history is only written when a session save fires,
  so output produced after the last save is lost on a crash.
- Replay is display only: `sleep 86400` pane came back as a fresh bash prompt under the replayed text.
- `EXP_VAR` lost in both cases.

## c-term — Scenario C, SIGTERM to the server (osc7=0)

- Log: `server shutdown initiated reason=SIGTERM` → `session saved workspaces=3` → every pane `signal: Hangup` → `herdr exiting`.
  SIGTERM is handled exactly like `herdr server stop`.
- Restored/lost set identical to b-clean (layout, labels, cwds restored; processes, screens, `EXP_VAR` lost; bash history written).
- No `session-backups/` (only created after a failed load).

## c-kill — Scenario C, SIGKILL after the 5 s autosave settled (osc7=0)

- Log: **no** shutdown or final save; last `session saved` was the debounced save ≈2.6 s before the kill.
- Restored/lost set identical to b-clean, because the last debounced save already contained the final layout.
- Pane processes still died: closing the PTY master on server death hangs up each shell, and no
  process with a cwd inside the run survived (`survivors-kill.txt` empty). Bash history was still flushed (4/4) via the hangup.
- Herdr's own `pane child exited` lines are absent (the server was already dead).

## v94 — Scenario D, Herdr 0.9.4 → 0.9.5 → 0.9.4 (clean stop between each hop)

Binaries (GitHub release `herdr-linux-x86_64`, no upstream checksum file published; local SHA-256):
0.9.4 `493304fb…675b23`, 0.8.0 `b872ea7e…acd28`, Homebrew 0.9.5 `32f81aa0…affc66`.

- Upgrade and rollback: layout, labels, cwds **restored** on every hop; processes lost as in b-clean.
- `session.json` written by 0.9.4 and by 0.9.5 is **identical** (`jq -S` diff empty). No `session-backups/`,
  no protocol errors (both protocol 22, endpoint generation 1).

## v80 — Scenario D, Herdr 0.9.5 → 0.8.0 → 0.9.5 (layout only; agent seeding failed, see below)

- Layout, labels, cwds **restored** on rollback to 0.8.0 and on re-upgrade to 0.9.5.
- `session.json` re-saved by 0.8.0 is identical to the 0.9.5 file (no fields dropped *for this layout*;
  this layout had no `agent_resume` field, the only field 0.8.0 lacks per source review).
- Client/server protocol is strict: the 0.8.0 CLI against a 0.9.5 server returns
  `protocol_mismatch: client protocol 19 is older than server protocol 22`. Every CLI/API caller
  (hooks, health probes, scripts) must match the running server's protocol.
- Claude seeding failed: Claude Code's folder-trust dialog highlighted **"No, exit"** by default, so
  the harness's Enter did not trust the folder. Agent portion of this hop re-run as `v80b`.

## w-* — Scenario C, what SIGKILL loses relative to the debounced autosave

| run | action before restart | restart | result after restart | last `session saved` before restart |
| --- | --- | --- | --- | --- |
| w-cd-noosc | `cd ../../beta` in alpha/build (no OSC 7), wait 8 s | SIGKILL | **old cwd** (`alpha/sub`) — cd lost | 14.2 s before kill; none after the cd |
| w-cd-osc7 | same, shell emits OSC 7 `file://$HOSTNAME$PWD` every prompt, wait 8 s | SIGKILL | **old cwd** — cd lost | 14.6 s before kill; none after the cd |
| w-cd-osc7e | same, OSC 7 with **empty host** `file://$PWD`, wait 8 s | SIGKILL | **new cwd** (`beta`) restored | 5.0 s after the cd, 3 s before kill |
| w-split-fast | `pane split` in beta, kill 8 ms later | SIGKILL | **split lost** (2 panes, not 3) | 6.2 s before kill |
| w-cd-noosc-clean | `cd` (no OSC 7), wait 8 s | clean stop | **new cwd** (`beta`) restored | final save during shutdown |

- A cwd-only change schedules a save only when the shell emits OSC 7 with an empty or `localhost`
  host. Herdr 0.9.5 rejects any other host (`src/pane/osc.rs:665-678`), so the common
  `file://$HOSTNAME$PWD` form never marks the session dirty. Without an accepted OSC 7, a `cd` is
  captured only by the next structural save or by graceful shutdown (which reads live `/proc/<pid>/cwd`).
- Structural changes are lost if the server dies within the 5 s debounce window.

## agent5 — Claude Code 2.1.311 (Herdr integration v11), clean restart then SIGKILL + headless restart

Setup: `claude --model haiku` started in pane beta/0:1/1, folder trust accepted, prompt seeded the
codeword `HERDR-ZEBRA-42`. (agent, agent2–agent4 were harness failures on Claude's folder-trust
dialog, whose default highlighted option is "No, exit"; no resume data from those runs.)

- `session.json` stored only `agent_session {source: "herdr:claude", agent: "claude", kind: "id", value: <id>}`
  for the pane; no `launch_argv`, no `agent_resume`.
- **Clean restart (client attached):** pane relaunched automatically as `claude --resume <id>` in
  `repos/beta`; Herdr detected it as `claude` / `idle`; asked for the codeword → answered `HERDR-ZEBRA-42`.
  Conversation **fully restored**; the original process and any in-flight turn were not.
- **SIGKILL, then headless server with no client ever attached:** the same `claude --resume <id>`
  started ≈1 s after server start (log `agent changed … agent=Some(Claude)`), and it again recalled the codeword.
  Headless resume works (matches CHANGELOG 0.8.0 #2064; the docs page implies a client is needed).
- Original launch flag `--model haiku` is **not** in the resume argv. The Claude status bar still showed a
  Haiku model after resume — possibly restored by Claude from its own session state; not verified.

## Harness contamination found after v80b — controller environment leaked into test servers

Runs up to and including v80b started Herdr with the controlling Claude Code session's environment
(`CLAUDECODE`, `CLAUDE_CODE_*` including a session-messaging token and `CLAUDE_CODE_CHILD_SESSION`, plus
`SSH_AUTH_SOCK`). Panes, and therefore the test Claude processes, inherited them. Under 0.8.0 in v80b the
resumed Claude printed "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker".

- Impact: Claude results from agent5 and v80b are treated as **provisional**. Layout, process, shell
  and Herdr-version results do not depend on these variables.
- Fix: `lib.sh` now starts every Herdr process with `env -i` and an allowlist (`HOME USER LOGNAME PATH LANG
  TERM SHELL XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_STATE_HOME`). `scenario.sh` records the server's variable
  names in `evidence/server-env-keys.txt` and aborts if any `CLAUDE*`, `HERDR_*` or `SSH_AUTH_SOCK` remains.
- Claude tests re-run with the clean environment as agent6 and v80c.
- Architecture note: pod entrypoints should likewise start Herdr with an explicit environment, because every
  variable visible to the server reaches every pane and agent.

## v80b (provisional, contaminated environment; superseded by v80d) — Claude across 0.9.5 → 0.8.0 → 0.9.5

- 0.8.0 restored the Claude pane as `claude --resume <id>` and the codeword was recalled; same after re-upgrade.
- The session ID was identical in all three `session.json` copies; no paths were lost. 0.8.0 wrote
  `sidebar_width`/`sidebar_section_split` values that 0.9.5 rewrites as `null`.
- Under 0.8.0, `herdr agent prompt --wait` returned `agent_prompt_stalled` (no observed state change), consistent
  with the v11 hook reporting only session identity, while 0.8.0 expects the older v7 state-reporting hook.

## agent7 — clean environment re-run of agent5 (confirms FIND-007/008)

- Server env names: `HOME LANG LOGNAME PATH SHELL TERM USER XDG_* ` plus `HERDR_STARTUP_CWD` (set by the
  Herdr client when it auto-spawns the server; absent when started headless). No `CLAUDE*`, no `SSH_AUTH_SOCK`.
- Pane / Claude process env names added by Herdr: `HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID
  HERDR_WORKSPACE_ID HERDR_BIN_PATH TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM`.
- No "Transcript saving is off" notice at any point.
- Clean restart: `claude --resume <id>` relaunched automatically; codeword recalled.
- SIGKILL + headless start, no client: `claude --resume <id>` relaunched (agent detected ≈1 s after start); codeword recalled.
- `--model haiku` again absent from the resume argv. agent5 conclusions stand.

## v80d — clean environment re-run of v80b (Claude across 0.9.5 → 0.8.0 → 0.9.5)

- Rollback to 0.8.0: Claude pane relaunched automatically as `claude --resume <id>`; `agent list` reported
  `claude` / `idle`; codeword recalled. No transcript-saving notice.
- Under 0.8.0, `herdr agent prompt --wait` still returned `agent_prompt_stalled` although the agent answered —
  status tracking is degraded with the v11 hook on a 0.8.0 server; conversation resume is not.
- Re-upgrade to 0.9.5: relaunched again, codeword recalled, `agent prompt` worked normally.
- The `agent_session` value at `workspaces[2].tabs[0].panes["6"]` was identical in all three `session.json` copies.
  The only differences were `sidebar_width`/`sidebar_section_split` (written as `26`/`0.5` by 0.8.0 and `null` by 0.9.5).
  No `session-backups/`; no parse or protocol errors in the log.
