# EXP-006 stage 3: real Claude Code under tmux, driven through Herdr (NOT RUN)

Status: **superseded by the Kubernetes stage 3 (k8s/stage3/); historical.** **NOT RUN.** The harness and task were written and validated statically
(`bash -n`, `shellcheck`, `py_compile`, `agent-task/selftest.sh`), and the bwrap sandbox was tested without any
credential by `agent-task/sandbox-test.sh` (see below). No real agent session has run.
Nothing here is observed evidence about Herdr. Stages 1 and 2 used a synthetic counter;
stage 3 asks the same question of a real agent (REQ/EXP/FIND links: EXP-006).

Hypothesis under test: a real Claude Code session owned by a dedicated tmux
server keeps its process and conversation, and keeps doing work, while Herdr
panes (`tmux attach` clients) are closed and while a disposable Herdr server is
cleanly stopped or SIGKILLed and restarted.

## Sandbox (bwrap)

The permission rules are application-level only: `Edit(./kata.py)` plus `Bash(python3 check.py)` lets the agent run
arbitrary Python as the owner's Unix user, through its own Bash tool and through the harness's `check.py` runs. So
`claude` and **every harness operation that reads or executes agent-written content** run under bubblewrap
([`sandbox.sh`](sandbox.sh), sourced by `agent-demo.sh` and `agent-task/sandbox-test.sh`; bwrap 0.12.0, unprivileged,
no root, no container). There is no code path that starts claude without it. The host never opens, hashes, runs git
on or greps a file under `$REPO`, `$AHOME` or `$ROOT/agent-xdg`.

Flags (`sbx_args`, built from the run's paths; `sbx-args.txt` in the evidence has the exact list):
`--unshare-all --unshare-user --share-net --disable-userns --die-with-parent --hostname exp006`, the mounts below,
`--proc /proc --dev /dev --tmpfs /tmp --perms 0555 --dir $ROOT`, `--clearenv` plus the `--setenv` list below. The agent
launch adds `--ro-bind-data 9 /run/exp006/key`; both launches end with `--remount-ro / --chdir $REPO`. No
`--new-session` (the TUI needs its controlling terminal; `dev.tty.legacy_tiocsti` must be 0, checked at start).

| Path (same inside as outside unless noted) | Mode | Why |
|---|---|---|
| `/usr`; `/bin /sbin /lib /lib64` as symlinks into it | ro | binaries and libs (claude's only libs are in /lib64) |
| `/etc/ld.so.cache`, `hosts`, `nsswitch.conf`, `resolv.conf` (resolved target), `/etc/pki`, `/etc/ssl` | ro | loader, name resolution, TLS roots |
| `/etc/passwd`, `/etc/group` (generated, one `agent` entry, home = `$AHOME`) | ro | uid lookup |
| `$REPO` (task repo), `$AHOME` (HOME, `.claude`, transcripts), `$ROOT/agent-xdg` | **rw** | the only writable binds |
| `$ROOT/settings.json` | ro | claude `--settings` |
| claude binary, as `/opt/exp006/claude` | ro | the agent |
| `/tmp` | tmpfs | ephemeral; gone with the sandbox; `$ROOT` inside is an empty 0555 directory over the mounts |
| `/proc`, `/dev` | new | sandbox pid namespace, minimal devices |
| `/run/exp006/key` (agent launch only) | ro | the key, see below |

Not mounted: `/home`, `/run` (except the single resolv.conf file above and the key file below), `/var`, `/sys`, `/opt` (except the binary), `/srv`, `/mnt`, `/media`, and from `$ROOT`
the tmux socket, Herdr state and socket, results, timeline, panes and key directory. Namespaces: mnt, pid, user,
uts, ipc, cgroup are new; **net is shared**. Verified at SETUP: mnt/pid/user/uts/ipc differ from the harness's (cgroup was checked by hand on 2026-11-22),
net is the same, `NSpid` has two levels.

Environment (`--clearenv`): `HOME=$AHOME USER LOGNAME PATH=/usr/bin:/bin LANG=C.UTF-8 TERM=xterm-256color
SHELL=/usr/bin/bash TMPDIR=/tmp XDG_{CONFIG,STATE,CACHE,DATA}_HOME` and `XDG_RUNTIME_DIR` under `$ROOT/agent-xdg`,
`CLAUDE_CONFIG_DIR`, `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PYTHONDONTWRITEBYTECODE=1
DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
(bwrap also sets `PWD`). bwrap itself is started under `env -i PATH=...`, so `/proc/1/environ` inside holds only `PATH`.

Key handling: the agent launcher opens fd 9 on `EXP006_KEY_FILE` and bwrap copies it to `/run/exp006/key` with
`--ro-bind-data`; the key's host path is on no bwrap command line and its directory is never mounted. The path does remain an argument of the host-side launcher and of the tmux server's `new-session` argv, readable only by same-uid host processes. The sandbox cannot see them, since its `/proc` is its own pid namespace. `settings.json`
has `apiKeyHelper: cat /run/exp006/key`. Harness check runs (`sbx_run`) get no key. The key is readable by the agent
(it needs it); its exposure is bounded by the dedicated workspace's spend limit and revoking it after the run.

Inside vs outside: **inside** run claude, the agent's Bash tool, and every harness read or execution of agent content
(`sbx_run`, 20 s cap, no inherited fds, stdin `/dev/null`, no key): `python3 check.py --nolog`, sha256 of `check.py` and
`README.md`, `progress.log`, `kata.py`, `git diff` (`core.fsmonitor`, `core.hooksPath`, `diff.external` and textconv
disabled), transcript listing and reading, the codeword grep, and a final `chmod -R u+rwX` before `rm -rf $ROOT`.
**Outside** (host): tmux, Herdr, `jq` on bytes the sandbox printed, the pristine `git init` of the template before any
agent exists, and evidence copying from the harness's own files (`$REPO`, `$AHOME`, `agent-xdg` are pruned from the find).
Process identity is the executable's device:inode (not `readlink exe`): outer bwrap (`pane_pid`), the pid-namespace
init and claude are recorded, tracked and verified gone; cleanup is `tmux kill-server`, pane SIGHUP, outer bwrap exits,
`--die-with-parent` kills the namespace.

`agent-task/sandbox-test.sh` (credential-free: fake key, canary and sibling files generated per run; claude only as
`--version` and once as a no-network, no-key TUI smoke test with `--unshare-net`) exercises these exact functions on
both the harness path and the agent-launch path. It checks absent host paths, failed unix connects (including a live
tmux socket), the key mount, write denial, hostile symlinks and `progress.log`, `/proc`, inherited fds, descendants,
git hooks, namespaces, fail-closed behaviour and `selftest.sh`. Its output is a test result about the sandbox only.

### Residual risks

- **Shared network namespace** (the API needs it): loopback services (including the `127.0.0.53` resolver stub),
  host abstract unix sockets (about 20 on the dev host: X11, dbus-broker, systemd buses; names in the local test log
  only), and LAN/internet egress are reachable by the agent and by any code it runs. It can reach host network
  services. Not mitigated here.
- The experiment API key is readable by the agent and by code it runs.
- Kernel and user-namespace attack surface; no seccomp filter; bwrap is a convenience boundary, not a hardened one.
- Terminal output is rendered by the host tmux and Herdr; escape-sequence handling there is outside the sandbox.
- The wall-clock cap and `--die-with-parent` rely on the host staying up; a killed harness can leave the sandbox until tmux dies.
- The key file's host path is visible to same-uid host processes in the launcher and tmux argv. The key's content is not.
- `sandbox.sh` honours a `BWRAP` override, which only `sandbox-test.sh` uses (for the fail-closed test). `agent-demo.sh` pins `/usr/bin/bwrap`.

## Inputs

- `EXP006_KEY_FILE`: path to a file holding an API key; regular, non-empty,
  owned by you, mode 0600 or 0400, outside this git repo and outside the run
  root, path chars `[A-Za-z0-9_./-]`. The script never reads it, except for the
  final leak scan (`grep -rqF -f`, output discarded); the launcher passes it on
  fd 9 and claude reads `/run/exp006/key` through `apiKeyHelper`. Nothing under
  the key's directory is mounted and `settings.json` holds the in-sandbox path only.
- Optional: `EXP006_MODEL` (default `claude-sonnet-5-5`), `EXP006_EFFORT`
  (`medium`), `EXP006_CLAUDE_VERSION` (`2.1.323 (Claude Code)`, must equal
  `--version` run under `env -i`), `EXP006_MAX_SECONDS` (`1500`, wall-clock cap),
  `CLAUDE_BIN` (default: `readlink -f` of `command -v claude` under `env -i`,
  which bypasses the interactive `claude` shell function), `HERDR_BIN`.
- Run: `EXP006_KEY_FILE=<path> experiments/exp-006/local/agent-demo.sh [run-id]`

## What it does

Root `/tmp/hx6a/<run-id>` (refuses reuse). Agent HOME, `CLAUDE_CONFIG_DIR`
and XDG dirs are all under it (TMPDIR is the sandbox's tmpfs `/tmp`); the task repo is a copy of
`agent-task/repo/` (`git init`, one commit, no signing, global/system git config
disabled). Before anything starts, `sbx_preflight` (bwrap with `--disable-userns`, `legacy_tiocsti` 0) and a probe
`sbx_run /usr/bin/true` must pass. tmux starts the launcher, which execs `bwrap ... /opt/exp006/claude --bare --settings ...
--strict-mcp-config --tools Read,Edit,Bash --model M --effort E --session-id SID`,
a fresh uuid; never `--resume`/`--continue`. Permissions (`dontAsk`, path-scoped,
`./` = project dir, `//` = absolute): allow `Read(./kata.py)`, `Read(./README.md)`,
`Read(./check.py)`, `Edit(./kata.py)`, `Bash(python3 check.py)`; deny `Edit(./check.py)`,
`Edit(./progress.log)`, `Edit(./README.md)`, `Edit(./.git/**)`, `Read(./.git/**)`,
`Read(//home/**)` and `Read(//<key file dir>/**)`. That the rules match this way is
an unverified assumption. The harness also records sha256 of `check.py` and
`README.md` at setup and re-checks them (plus the `progress.log` line format) on
every harness count and at A5 (hashed inside the sandbox); any mismatch is written to `files-bad.txt` and turns
every later PASS row into FAIL. A disposable Herdr is started as in demo.sh.

Task: `agent-task/repo/kata.py` has stubs `f01`..`f12`. `check.py` (run by the
agent) prints `TOTAL k/12` and appends `<epoch> check k/12 passing=...` to
`progress.log`, so progress is measured independently of what the agent says.
The harness measures the count itself with `check.py --nolog` through `sbx_run`
(sandbox, no key, 20 s cap); a timeout counts as 0 and is noted in timeline.log. `check.py` survives a `kata.py` that
raises, calls `sys.exit` or hangs at import (2 s alarm) and always logs.

Prompts (single line, ASCII; exact text in `agent-demo.sh` and `versions.txt`):
P1 gives a random 12-hex codeword, asks for f01-f04 and `DONE-A <codeword>`;
PB asks f05-f08 and `DONE-B`; PC asks f09-f12 and `DONE-C`; Qk asks the agent
to repeat the codeword (not in the question) and its last passing count.

## PASS criteria (overall PASS only if every row passes)

- **SETUP**: claude is the unique descendant of the tmux pane pid (the outer bwrap) whose exe
  device:inode equals `CLAUDE_BIN`'s, with a single bwrap init child; the sandbox namespaces are as
  designed (see Sandbox); environ has `HOME` and `CLAUDE_CONFIG_DIR`, and no `ANTHROPIC_*`,
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
  process (HOME=agent HOME, exe inode = `CLAUDE_BIN`) at every snapshot; the cmdline never
  had `--resume`/`--continue`; codeword not in the repo files. Final count and
  token usage are informational. A **WATCHDOG** FAIL row is added if the cap fired.

## Evidence

`local/evidence/agent-<run-id>/` (refused if it already exists; sanitized: `$HOME` to
`~`, user, host). Files collected: results.tsv, timeline.log, versions.txt (claude
version/sha256, herdr, tmux, model, effort, SID, codeword, prompts, task template
hashes), setup-lineage.txt, env-keys-agent.txt (names only), server-env-keys-*.txt
(tmux and Herdr server env names only), snaps/, panes/ (tmux captures, Herdr pane
reads), restored-*.txt, cleanup.txt, progress.log, final-check.txt, kata-final.py,
kata.diff, settings-evidence.json (in-sandbox key path only), sbx-args.txt (exact bwrap arguments),
transcript-files.txt,
transcript-summary.jsonl, usage.txt (token sums; no prices), files-bad.txt (only if an
integrity check failed) and herdr-server-tail-fail.txt (only if a row failed).
Environ values are never copied.

## Cleanup and credential handling

On exit: kill the tmux server via its socket (this takes the pane, outer bwrap, the namespace init and claude down), stop
the disposable Herdr, signal only recorded pids (tmux, outer bwrap, init, claude, Herdr) with matching starttime,
verify gone, sweep `/proc` for
`XDG_CONFIG_HOME=$ROOT/config` or `HOME=<agent HOME>` (a stray is a failure).
Then collect evidence, scan it for the key (`grep -rqF -f key`, and `sk-ant-...`);
on a hit the evidence directory is deleted and the run fails. Finally
`chmod -R u+rwX` of the three agent trees inside the sandbox, then `rm -rf $ROOT` (only if it matches
`^/tmp/hx6a/[A-Za-z0-9-]+$`), taking the task repo, agent HOME and transcripts with it. The key file is yours to delete.
Do not commit anything from `evidence/` before reviewing it.

## Limitations

The disposable Herdr and tmux processes get the real `HOME` and `XDG_RUNTIME_DIR`
(everything else scrubbed), exactly as in stage 1; this was accepted in stage 1. They are outside the sandbox.
Only the agent has its own HOME/XDG tree. See Residual risks above for what the sandbox does not cover.

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
- tmux execs the launcher argv directly (no shell), so `pane_pid` becomes the outer bwrap, and claude does not
  spawn helper processes with its own exe and `HOME=$AHOME`.
- Inside bwrap claude's TUI, `--bare`, `apiKeyHelper` (`cat /run/exp006/key`) and its Bash/Read/Edit tools work with this
  mount set (only `--version` and a no-key, no-network TUI start were observed, by `sandbox-test.sh`).
- The pane's PTY works as claude's controlling terminal under `--unshare-pid --dev /dev` (the smoke test showed the TUI draws).
