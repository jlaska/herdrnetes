# EXP-006 stage 3: real Claude Code under tmux, driven through Herdr (NOT RUN)

Status: **NOT RUN.** The harness and task were written and only statically
validated (`bash -n`, `shellcheck`, `py_compile`, `agent-task/selftest.sh`).
Nothing here is observed evidence. Stages 1 and 2 used a synthetic counter;
stage 3 asks the same question of a real agent (REQ/EXP/FIND links: EXP-006).

Hypothesis under test: a real Claude Code session owned by a dedicated tmux
server keeps its process and conversation, and keeps doing work, while Herdr
panes (`tmux attach` clients) are closed and while a disposable Herdr server is
cleanly stopped or SIGKILLed and restarted.

## Pre-execution review (2026-11-22): execution BLOCKED pending an OS boundary

The permission rules are application-level only, and they are not an OS boundary. `Edit(./kata.py)` plus
`Bash(python3 check.py)` lets the agent write arbitrary Python into `kata.py` and have `check.py` run it, both
through the agent's own Bash tool and through the harness's `agent_check`. That code runs as the owner's Unix user.
`env -i` removes variables, but not access by path. On this host the same user can reach:
- `/run/user/<uid>/gnupg/`: the gpg-agent sockets, its SSH socket, and the scdaemon socket (the YubiKey);
- `~/.ssh`, `~/.gnupg`, `~/.config/gh` and `~/.claude`;
- the API key file, which is mode 0600 but owned by the same user;
- the live Herdr's socket.

Required correction before any credentialed run: launch the agent inside an OS sandbox (for example `bwrap`).
- `$ROOT` is the only writable bind.
- The binary is read-only, and `/usr` and `/etc` are read-only as needed.
- `/home`, `/run/user` and the tmux and Herdr sockets are not visible.
- The network stays available for the API.

The API key cannot be hidden from the agent's own process, which needs it. Its exposure is bounded instead by the
dedicated workspace's spend limit and by revoking the key after the run.

## Inputs

- `EXP006_KEY_FILE`: path to a file holding an API key; regular, non-empty,
  owned by you, mode 0600 or 0400, outside this git repo and outside the run
  root, path chars `[A-Za-z0-9_./-]`. The script never reads it, except for the
  final leak scan (`grep -rqF -f`, output discarded); claude reads it through
  `apiKeyHelper` (`cat <path>`). `settings.json` holds the path only.
- Optional: `EXP006_MODEL` (default `claude-sonnet-5-5`), `EXP006_EFFORT`
  (`medium`), `EXP006_CLAUDE_VERSION` (`2.1.323 (Claude Code)`, must equal
  `--version` run under `env -i`), `EXP006_MAX_SECONDS` (`1500`, wall-clock cap),
  `CLAUDE_BIN` (default: `readlink -f` of `command -v claude` under `env -i`,
  which bypasses the interactive `claude` shell function), `HERDR_BIN`.
- Run: `EXP006_KEY_FILE=<path> experiments/exp-006/local/agent-demo.sh [run-id]`

## What it does

Root `/tmp/hx6a/<run-id>` (refuses reuse). Agent HOME, `CLAUDE_CONFIG_DIR`,
TMPDIR and XDG dirs are all under it; the task repo is a copy of
`agent-task/repo/` (`git init`, one commit, no signing, global/system git config
disabled). tmux starts claude directly (`env -i ... claude --bare --settings ...
--strict-mcp-config --tools Read,Edit,Bash --model M --effort E --session-id SID`,
a fresh uuid; never `--resume`/`--continue`). Permissions (`dontAsk`, path-scoped,
`./` = project dir, `//` = absolute): allow `Read(./kata.py)`, `Read(./README.md)`,
`Read(./check.py)`, `Edit(./kata.py)`, `Bash(python3 check.py)`; deny `Edit(./check.py)`,
`Edit(./progress.log)`, `Edit(./README.md)`, `Edit(./.git/**)`, `Read(./.git/**)`,
`Read(//home/**)` and `Read(//<key file dir>/**)`. That the rules match this way is
an unverified assumption. The harness also records sha256 of `check.py` and
`README.md` at setup and re-checks them (plus the `progress.log` line format) on
every harness count and at A5; any mismatch is written to `files-bad.txt` and turns
every later PASS row into FAIL. A disposable Herdr is started as in demo.sh.

Task: `agent-task/repo/kata.py` has stubs `f01`..`f12`. `check.py` (run by the
agent) prints `TOTAL k/12` and appends `<epoch> check k/12 passing=...` to
`progress.log`, so progress is measured independently of what the agent says.
The harness measures the count itself with `check.py --nolog`, under `timeout 20`
and `env -i` (HOME=agent HOME, minimal PATH, TMPDIR under the run root); a timeout
counts as 0 and is noted in timeline.log. `check.py` survives a `kata.py` that
raises, calls `sys.exit` or hangs at import (2 s alarm) and always logs.

Prompts (single line, ASCII; exact text in `agent-demo.sh` and `versions.txt`):
P1 gives a random 12-hex codeword, asks for f01-f04 and `DONE-A <codeword>`;
PB asks f05-f08 and `DONE-B`; PC asks f09-f12 and `DONE-C`; Qk asks the agent
to repeat the codeword (not in the question) and its last passing count.

## PASS criteria (overall PASS only if every row passes)

- **SETUP**: claude pid is the tmux pane pid or its single claude child; `/proc/PID/exe`
  is `CLAUDE_BIN`; environ has `HOME` and `CLAUDE_CONFIG_DIR`, and no `ANTHROPIC_*`,
  `HERDR_*`, `SSH_AUTH_SOCK`, `GNUPGHOME`, `TMUX`, `GPG_*`, `CLAUDECODE`,
  `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION*` or any other `CLAUDE*` name
  (stricter reading of the spec); the TUI prompt appears within 60 s with no
  login/trust/onboarding text. Otherwise stop before sending anything.
- **A1-attach**: P1 typed in a Herdr pane; a new `progress.log` line appears (240 s).
- **A2-disconnect**: close the pane, clients 0 within 10 s. With no client: same
  pid/start, one transcript, a `progress.log` line and a tool_use transcript entry
  newer than T_CLOSE (taken after clients=0), and the harness-measured passing
  count rose. Distinguishes progress from mere survival.
- **A3-reconnect**: new pane, Q1; `Q1 CODEWORD=<codeword>` in an assistant
  transcript entry and in the visible pane; same pid/start. `DONE=` vs measured
  count is informational.
- **A4a-clean-restart / A4b-forced-restart**: PB / PC typed, first new progress
  line, then `herdr server stop` / `kill -9` of the verified server pid. Old
  server gone, clients 0, agent unchanged, count up and a newer progress line
  while Herdr is down (300 s); restart Herdr, record what it restored, new pane,
  Q2 / Q3 answered with the codeword. `DONE-B`/`DONE-C` seen is informational.
- **A5-final**: same pid/start as SETUP; `check.py`/`README.md` hashes unchanged and
  `progress.log` well-formed; one session jsonl; exactly one claude
  process (HOME=agent HOME, exe=CLAUDE_BIN) at every snapshot; the cmdline never
  had `--resume`/`--continue`; codeword not in the repo files. Final count and
  token usage are informational. A **WATCHDOG** FAIL row is added if the cap fired.

## Evidence

`local/evidence/agent-<run-id>/` (refused if it already exists; sanitized: `$HOME` to
`~`, user, host). Files collected: results.tsv, timeline.log, versions.txt (claude
version/sha256, herdr, tmux, model, effort, SID, codeword, prompts, task template
hashes), setup-lineage.txt, env-keys-agent.txt (names only), server-env-keys-*.txt
(tmux and Herdr server env names only), snaps/, panes/ (tmux captures, Herdr pane
reads), restored-*.txt, cleanup.txt, progress.log, final-check.txt, kata-final.py,
kata.diff, settings-evidence.json (key path replaced), transcript-files.txt,
transcript-summary.jsonl, usage.txt (token sums; no prices), files-bad.txt (only if an
integrity check failed) and herdr-server-tail-fail.txt (only if a row failed).
Environ values are never copied.

## Cleanup and credential handling

On exit: kill the tmux server via its socket, stop the disposable Herdr, signal
only recorded pids with matching starttime, verify gone, sweep `/proc` for
`XDG_CONFIG_HOME=$ROOT/config` or `HOME=<agent HOME>` (a stray is a failure).
Then collect evidence, scan it for the key (`grep -rqF -f key`, and `sk-ant-...`);
on a hit the evidence directory is deleted and the run fails. Finally
`rm -rf $ROOT` (only if it matches `^/tmp/hx6a/[A-Za-z0-9-]+$`), taking the task
repo, agent HOME and transcripts with it. The key file is yours to delete.
Do not commit anything from `evidence/` before reviewing it.

## Limitations

The disposable Herdr and tmux processes get the real `HOME` and `XDG_RUNTIME_DIR`
(everything else scrubbed), exactly as in stage 1; this was accepted in stage 1.
Only the agent has its own HOME/XDG tree.

## Untested assumptions (verify on the first run)

- Pre-seeded `.claude.json` keys (`hasCompletedOnboarding`, `theme`,
  `projects.<repo>.hasTrustDialogAccepted`) skip every first-run dialog; the file
  is written to both `$AHOME` and `$CLAUDE_CONFIG_DIR`. The harness detects a blocking dialog but cannot click through it.
- Transcript path is `$CLAUDE_CONFIG_DIR/projects/<dir>/<SID>.jsonl` with ISO
  `timestamp`, `message.content[]` (`text`/`tool_use`) and `message.usage`.
- `dontAsk` plus the scoped allow/deny rules behave as described above (rule syntax,
  `./` and `//` anchoring, deny precedence) and `python3 check.py` runs without prompting.
- `--bare` honours `apiKeyHelper` from `--settings`; no auto-update/telemetry
  settings keys are used, only env vars.
- Herdr `send-text` followed by `send-keys Enter` submits a prompt in the Claude
  TUI (no paste-detection swallowing Enter); `PROMPT_RX` and `DIALOG_RX` match the real screens.
- The pane pid is claude itself (tmux execs argv directly) and no helper
  process has the same exe and HOME.
