# EXP-003 Milestone 3 desktop client results (run r1, 2026-11-16 UTC)

Sanitized: no hostnames, session ids, conversation text. Raw evidence: `~/.local/share/exp003/r1/`.

## Environment
- Server: pod herdr-0 (uid 7e91a13b-..., restart 0), Herdr 0.9.5, server PID 7 started 13:18:58Z (unchanged throughout).
- Local clients: herdr 0.9.5 (PATH), 0.9.4, 0.8.0 (EXP-002 variants). Driven in a dedicated `tmux -L exp003 -f /dev/null` server with its prefix disabled (so Herdr's ctrl+b prefix reaches Herdr; a tmux prefix clash is the likely cause of the earlier "ctrl-b q did not detach").
- Window sizes: path A 200x50, path B 100x30.
- Herdr keys (default, docs v0.9.5): prefix ctrl+b; `q` detach; `w` workspace navigation (Up/Down, Enter); `h/j/k/l` pane focus; `[` copy mode.

## Commands
- `scenario.sh setup r1`; `scenario.sh identity r1 <label>`; `scenario.sh identity-diff r1 baseline <label>`
- Path A: `kubectl --context $CTX -n herdrnetes-exp exec -it herdr-0 -c herdr -- herdr` (in tmux)
- Path B: `bridge.py $XDG_RUNTIME_DIR/hb3.sock` + `client.sh <sock>` (`HERDR_BIN=` for skew)

## Results
| Test | Observation | Client continuity | Server/pane continuity | identity-diff |
| --- | --- | --- | --- | --- |
| T1 setup | exp003-r1 created 17:08:59Z; panes w3:p1 (sleep 86400, pid 14002) and w3:p2 (ticker; shell 13990) | n/a | n/a | baseline |
| T2 path A | TUI showed alpha, beta, exp003-r1 (focus initially alpha). prefix+w, Down x2, Enter selected exp003-r1; prefix+l focused ticker pane (confirmed via `pane list`). Ticker updated live. ctrl+l echoed as `^L` (a loop was running). ctrl-c, `echo input-ok`, loop restarted; shell PID 13990 unchanged. | n/a | Fully restored | UNCHANGED |
| T2 detach | prefix+q at 17:10:36.6Z; kubectl exited and prompt returned within 2.5 s; no kubectl process and no `herdr` client left in pod. | Fully restored (reattach by rerun) | Fully restored | UNCHANGED |
| T2 reattach | 17:10:53Z, reattached to same state; workspace exp003-r1 still focused; clean detach again | Fully restored | Fully restored | UNCHANGED |
| T3 attach | 0.9.5 via bridge shows same 3 workspaces; scrollbar present | | | |
| T3a clean detach | prefix+q 17:11:22.6Z; bridge "client closed", child exit 0 within 2.5 s | Recoverable (rerun client.sh) | Fully restored | UNCHANGED |
| T3b SIGKILL client | 17:11:48.69Z; bridge cleaned kubectl child in 8 ms (exit 0), no leftover processes; tmux pane left in a garbled terminal state (alt-screen/raw mode not restored) | Recoverable (rerun; `reset` advisable) | Fully restored | UNCHANGED |
| T3c SIGKILL kubectl child | 17:12:10.31Z; client exited by ~17:12:13 with message below; no auto reattach; no orphan bridge in pod. Manual reattach command to screen up: about 0.5 s. | Recoverable (manual, command printed) | Fully restored | UNCHANGED |
| T3d SIGSTOP kubectl 60 s | 17:12:27.55Z to 17:13:27.57Z. Display froze with no stall indicator. After SIGCONT, kubectl exited immediately with an i/o timeout and the client printed the same lost-connection message. Not tested: stalls shorter than 60 s (threshold unknown). | Recoverable (manual) | Fully restored | UNCHANGED |
| T4 concurrency | A (174x49 area) and B (74x29 area) attached together. See below. | | Fully restored | UNCHANGED |
| T5 0.9.4 | Attached normally, no message, same workspaces; detach OK (bridge child exit 1, kubectl "exit code 1", benign) | Fully restored | | UNCHANGED |
| T5 0.8.0 | Rejected in 0.3 s at 17:16:35Z, bridge child exit 0. No install/replace attempt; pod binary `/usr/local/bin/herdr` mtime Nov 15 and `herdr --version` still 0.9.5; no log line on server | Lost for that client (unsupported); no change to server | Fully restored | UNCHANGED |
| T6 idle | 0.9.5 client attached 17:16:55Z, checked 17:27:23Z (628 s): still live, ticker updating, no kubectl stream timeout | Fully restored | Fully restored | UNCHANGED |

### T4 detail
- Workspace selection is per client view. B switching to alpha did not move A (A still showed exp003-r1 even after a keypress), although the server's focused workspace id changed to w1. Pane focus within a workspace is shared (B `prefix h` moved focus; A `prefix l` moved it back).
- Danger observed: server focus (w1) and A's displayed workspace (w3) disagreed. Typing into a client in that state might reach the server-focused pane. Input tests were only done after both clients showed exp003-r1 and `api snapshot` confirmed focus w3:p2.
- Input: `echo from-A` typed in A and `echo from-B` typed in B both appeared in both clients, in order.
- Size: the pane/layout size follows the client that most recently performed a focus/copy-mode action, not typing (A: 174x49, pane viewport rows 47; B: 74x29, viewport rows 27). On detach of A, layout returned to B's size. Without any client attached the layout reverts to 120x40.
- Scrollback: copy mode (prefix+[, PageUp) works in both; scroll offset is server-side and shared (A scrolling also scrolled B's view). History depth reached 71 lines at time of test (`pane_history = false` in config).
- Detaching A left B live.

## Verbatim client messages (redacted)
- 0.9.5 on kubectl kill / stall:
  `herdr: lost connection to remote Herdr: connection was lost`
  `If the remote server survived the SSH or network drop, its panes may still be running.`
  `Run \`<repo>/experiments/exp-003/harness/client.sh <sock>\` to reattach`
- 0.8.0: `herdr: lost connection to remote Herdr: server closed connection` (followed by the same hint)
- kubectl after SIGCONT: `error: error reading from error stream: next reader: read tcp <ip>:<port>-><apiserver>:6443: i/o timeout`

## identity-diff
All labels (pre-setup, t2-attached, t2-detached, t2-final, t3a-after..t3d-after, t4-attached, t4-after, t5-094-after, t5-080-after, t6-idle, final) vs baseline: server PID 7 / start ticks and all pre-existing pane shell PIDs UNCHANGED; only counts differ from pre-setup.

## Unverified / caveats
- Stall threshold between 0 and 60 s not measured; Herdr-side keepalive behavior unknown.
- Path A on terminals with a real tmux prefix clash was not retested.
- Which client owns size after typing-only activity was inferred from snapshots at coarse timing.
- Bridge child exit code 1 after some clean detaches (0.9.4, and 0.9.5 in T4/T6) vs 0 (first 0.9.5 detach) unexplained.
