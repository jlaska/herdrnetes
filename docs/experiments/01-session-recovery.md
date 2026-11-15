# EXP-001: Herdr session persistence and recovery

**Status:** Executed on a local host (2026-11-15). Layout, process, shell, Claude Code and Herdr version tests
complete; Codex runtime tests **blocked** (Codex not installed). Proposed for review; no ADR changes made.
Tracking issue: [#2](https://github.com/jlaska/herdrnetes/issues/2). Outstanding work is dispositioned in
[§8](#8-disposition-of-outstanding-work): EXP-002 ([#3](https://github.com/jlaska/herdrnetes/issues/3)), agent
follow-up ([#10](https://github.com/jlaska/herdrnetes/issues/10)), deferred
([#11](https://github.com/jlaska/herdrnetes/issues/11)).

Evidence types used below: **[observed]** = measured in an isolated test run, **[source]** = read from Herdr
v0.9.5 source (`herdrdev/herdr@2ecf19a`, tag `v0.9.5`), **[docs]** = Herdr v0.9.5 documentation, **[inference]** =
our reasoning, not yet tested. Per-run notes: [`experiments/exp-001/RESULTS.md`](../../experiments/exp-001/RESULTS.md).

## Hypotheses and outcome

| Hypothesis | Outcome |
| --- | --- |
| Herdr restores workspace, tab, pane and cwd structure after exit or crash. | **Confirmed**, with a crash window: changes newer than the last debounced save (≤5 s, or an unreported `cd`) are lost on SIGKILL. |
| Native agent conversation state remains recoverable after processes die. | **Confirmed for Claude Code** (automatic, also headless). Codex untested. |
| Application and agent version changes may introduce compatibility constraints. | **Partly confirmed**: persisted state round-tripped 0.9.4↔0.9.5 and 0.9.5→0.8.0→0.9.5; the client/server wire protocol is strict. |

## 1. Environment inventory

| Item | Value |
| --- | --- |
| Host OS | Fedora 44, Linux 7.2.13-200.fc44.x86_64 |
| Herdr (primary) | 0.9.5 (Homebrew bottle; `herdr` binary SHA-256 `32f81aa0797c6361d074263d22db478762ec9950c0315e32f9b4309359affc66`), wire protocol 22, endpoint generation 1 |
| Herdr (version tests) | 0.9.4 (`493304fbefb0ed0ea0455f373b47f48d24e8774bc7974f4c916ad2e937675b23`), 0.8.0 (`b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28`, protocol 19) — GitHub release asset `herdr-linux-x86_64`; upstream publishes no checksum file |
| Claude Code | 2.1.311, Herdr integration hook v11 (`~/.claude/hooks/herdr-agent-state.sh`, `SessionStart` hook in `~/.claude/settings.json`) |
| Codex | **Not installed** — runtime tests blocked |
| Pane shell | GNU bash 5.3.9 via wrapper `exp-shell` (`--noprofile --rcfile <run>/exp-bashrc -i`) |
| Controller | tmux 3.8 on a private socket (hosts a real TUI client, 200×50), outside Herdr; Python via `uv` |
| Test Herdr config | `onboarding=false`; `[update] version_check=false, manifest_check=false`; `[terminal] default_shell=<wrapper>, shell_mode="non_login"`; `[experimental] pane_history` per run |

**Isolation.** Every run used its own `XDG_CONFIG_HOME`/`XDG_STATE_HOME` under `/tmp/hx1/<run>`, with
`HERDR_SOCKET_PATH`, `HERDR_SESSION`, `HERDR_PANE_ID` and `HERDR_ENV` unset. The harness guards check the resolved
socket before any stop and identify servers by `/proc/<pid>/environ`. The operator's own Herdr server stayed up
throughout.

**Isolation boundary.** Herdr state and sockets, the pane shell (rc file, `HISTFILE`), the server environment
and the test git repositories (`GIT_CONFIG_GLOBAL=/dev/null`) were isolated. Claude Code was **not**: it
deliberately kept the operator's real `HOME` to reuse the existing login, integration hook and settings. Side
effects of the Claude runs (agent5, agent7, v80d, final and earlier attempts), all on the operator's machine and
none committed:

| Path | Effect |
| --- | --- |
| `~/.claude/projects/-tmp-hx1-*/` | Disposable test transcripts (codeword prompts only), one directory per test repo path |
| `~/.claude.json` | Folder-trust entries for `/tmp/hx1/<run>/repos/beta` (answered "Yes" by `agent-seed.sh`) |
| `~/.claude/history.jsonl` | Prompt-history lines for the test prompts |
| `~/.claude/backups/` | Claude's own rotating backups of `~/.claude.json`, which therefore also contain the trust entries |
| `~/.claude/settings.json`, `~/.claude/hooks/` | Read only (Herdr integration hook v11); not modified |

Tests also used the operator's Claude account and quota. A fully isolated agent `HOME` (with its own login) is
recommended for #10, which must change installed agent versions.

**Harness correction.** Early runs started Herdr with the controlling session's environment, so
`CLAUDE_CODE_*` variables (including `CLAUDE_CODE_CHILD_SESSION`) and `SSH_AUTH_SOCK` reached every pane. The
harness now starts every Herdr process with `env -i` and an allowlist, and aborts if leaked variables remain.
Claude results are taken from the clean re-runs (agent7, v80d); layout, process and shell results were not affected.

## 2. Persistence inventory

The default session lives in `$XDG_CONFIG_HOME/herdr/`; named sessions live in `…/herdr/sessions/<name>/` [source].

| Path | Contents | Persist? | Sensitivity |
| --- | --- | --- | --- |
| `$XDG_CONFIG_HOME/herdr/session.json` | Layout, labels, focus, pane cwd, agent session refs (`agent_session {source, agent, kind, value}`), schema `version: 3` [observed] | **Required** | Paths, agent session IDs |
| `…/session-snapshots/` | Up to 48 prior layouts, at most one per 15 min [docs/observed] | Recommended (manual recovery only) | As above |
| `…/session-backups/` | Copies of a `session.json` that failed to load (3 kept); not created in any of our runs [docs/observed] | Recommended | As above |
| `…/session-history.json` | Pane screen text, only when `[experimental] pane_history = true` [observed] | Optional | **High**: terminal output, secrets |
| `…/config.toml` | Herdr configuration [source] | Declarative (GitOps); `HERDR_CONFIG_PATH` can point elsewhere [source] | Low |
| `…/herdr.sock`, `herdr-client.sock`, `herdr-handoff-<pid>.sock` | Runtime sockets, recreated at start [observed] | No | — |
| `…/herdr.sock.agent` | Symlink to the server's `SSH_AUTH_SOCK` [observed] | No (runtime) | Points at an SSH agent |
| `…/herdr-server.log`, `herdr-client.log` | Logs incl. stop reasons and save events [observed] | Optional | Paths, process info |
| `…/plugins/`, `plugins.json`, `.plugins.lock` | Plugin registry [source] | Only if plugins are used | Low |
| `$XDG_STATE_HOME/herdr/agent-detection/`, `client-shell/`, `client/` | Manifest cache, client UI and endpoint preferences [source] | No (rebuildable) | Low |
| `~/.claude/projects/<encoded-cwd>/<id>.jsonl` | Claude conversation transcripts [general knowledge; resume observed] | **Required** for resume | **High** |
| `~/.claude.json`, `~/.claude/.credentials.json` | Claude account state, per-folder trust, credentials [general knowledge] | Required (credentials managed separately) | **Secret** |
| `~/.claude/settings.json`, `~/.claude/hooks/herdr-agent-state.sh` | Herdr integration hook [observed] | Required for agent resume | Low |
| `~/.codex/` (`sessions/`, `auth.json`, `config.toml`, `hooks.json`, `herdr-agent-state.sh`) | Codex state + Herdr integration [source; untested] | Required for Codex resume | **Secret** |
| `$HISTFILE` (e.g. `~/.bash_history`) | Shell history; flushed by SIGHUP on every server exit [observed] | Recommended | Commands may contain secrets |
| Repositories / worktrees | Files, uncommitted changes [observed unchanged] | **Required** (workspace PVC) | Project data |

## 3. Test procedures

Scripts are in [`experiments/exp-001/`](../../experiments/exp-001/): `lib.sh` (isolation and guards),
`scenario.sh` (driver), `agent-seed.sh` (Claude start and codeword seed) and `compare.py` (JSON helpers and
before/after diff, run with `uv run --script`).

```bash
S=experiments/exp-001/scenario.sh
bash $S init <run> [osc7=0|1|2] [pane_history=0|1]  # 1 = OSC 7 file://$PWD, 2 = file://$HOSTNAME$PWD
bash $S setup <run>          # Scenario A: 2 git repos (modified + untracked files), 3 workspaces, 4 tabs,
                             # 6 panes, a pane label, cd in a pane, exported var, foreground sleep, background server
bash $S agent <run> haiku    # claude --model haiku in beta/0:1/1, accept trust, seed codeword
bash $S restart <run> clean|term|kill|clean-noclient|kill-noclient [herdr-bin]
bash $S ask <run>            # ask the resumed agent for the codeword
bash $S cd-only|split-now <run>   # mutate without waiting for autosave
uv run --script experiments/exp-001/compare.py diff /tmp/hx1/<run>/evidence/baseline /tmp/hx1/<run>/evidence/after-<mode>
bash $S stop <run>
```

| Run | Procedure |
| --- | --- |
| b-clean | init 0 0 → setup → restart clean |
| c-term / c-kill | init 0 0 → setup → restart term / kill (SIGKILL after the autosave settled) |
| w-cd-noosc / w-cd-osc7 / w-cd-osc7e | init {0,2,1} 0 → setup → cd-only → sleep 8 → restart kill |
| w-cd-noosc-clean | init 0 0 → setup → cd-only → sleep 8 → restart clean |
| w-split-fast | init 0 0 → setup → split-now → restart kill (8 ms later) |
| h-hist | init 0 1 → setup → restart clean → restart kill |
| agent7 (clean env; agent5 earlier) | init 0 0 → setup → agent → restart clean → ask → restart kill-noclient → ask |
| v94 | init 0 0 → setup (0.9.4) → restart clean 0.9.5 → restart clean 0.9.4 |
| v80, v80d (clean env; v80b earlier) | setup (0.9.5) [+ agent] → restart clean 0.8.0 → ask → restart clean 0.9.5 → ask |

## 4. Recovery matrix

Legend: **R** fully restored automatically · **M** recoverable with manual action · **L** lost.

| State | Expected (docs/source) | Clean stop | SIGTERM | SIGKILL | Version change |
| --- | --- | --- | --- | --- | --- |
| Workspaces, tabs, splits, labels, focus | Restored from `session.json` | R | R | R if saved before kill; **L** for changes in the last ≤5 s (w-split-fast) | R (0.9.4↔0.9.5, 0.9.5→0.8.0→0.9.5) |
| Pane cwd | Live `/proc` cwd at save | R (shutdown reads live cwd) | R | R only if a save ran after the `cd`, which needs an empty/`localhost`-host OSC 7 or another layout change; otherwise **L** (old cwd) | R |
| Running shells, foreground and background processes | Not preserved | L | L | L (PTY hangup kills them; no survivors) | L |
| Exported environment, shell jobs, in-memory state | Not preserved | L | L | L | L |
| Shell history (`HISTFILE`, bash) | Not Herdr-owned | R (bash saves on SIGHUP) | R | R | R |
| Pane screen contents | Only with `pane_history` | L by default; R (display-only) with `pane_history` | as clean | R as of last save with `pane_history`; newer output L | Ignored if layout fingerprint mismatches [source] |
| Uncommitted and untracked repo files | Filesystem | R | R | R | R |
| Claude Code conversation | `claude --resume <id>` via integration | R (codeword recalled) | R [inference: same path as clean] | R, also headless with no client (codeword recalled) | R (0.9.5→0.8.0→0.9.5; see below) |
| Claude in-flight turn / running tool call | Not preserved | L | L | L | L |
| Claude launch flags (`--model`, permission flags) | Rebuilt argv `claude --resume <id>` [source] | **L** (argv lacks flags) | L | L | L |
| Codex conversation | `codex resume <id>` via integration v≥5 [docs/source] | Untested | Untested | Untested | Untested |
| Older layouts | `session-snapshots/` | M | M | M | M |

**Claude across Herdr versions (v80d, clean environment):** rolling back 0.9.5 → 0.8.0 and re-upgrading kept the
same `agent_session` reference in `session.json`. Both versions relaunched `claude --resume <id>` automatically,
and the agent recalled the codeword each time (**R**). Under 0.8.0, agent *status* tracking was degraded:
`herdr agent prompt --wait` returned `agent_prompt_stalled` while the agent answered, because the v11 hook reports
only session identity and 0.8.0 expects the older v7 state hook. The only `session.json` differences were
`sidebar_width`/`sidebar_section_split` values.

## 5. Findings

- **FIND-001 — Layout and cwd restore is reliable after any exit that follows a save.** [observed] Workspaces,
  tabs, split geometry, labels and cwds came back identically after clean stop, SIGTERM and SIGKILL (once
  saved), and across 0.9.4↔0.9.5 and 0.9.5→0.8.0→0.9.5. Restored panes are new shells in the saved directory.
  → REQ-003, REQ-006.
- **FIND-002 — The tested pane processes did not survive a Herdr server exit.** [observed] Clean stop and SIGTERM
  send SIGHUP to every pane. SIGKILL closes the PTY masters, which hangs up the shells. In every run the tested
  processes — interactive shells, a foreground job (`sleep`), a background job started with `&`
  (`python -m http.server`) and the Claude Code agent — were gone, along with exported variables; no process with a
  cwd under the run directory remained. A restored pane is a new shell, not a restored process. Scope: processes that
  deliberately detach from the terminal (`setsid`, `nohup`, daemons, `disown` with SIGHUP ignored) were **not**
  evaluated and may outlive Herdr [inference]. For the MVP, assume normal in-pane agents are interrupted by every
  pod replacement. → REQ-006, REQ-009.
- **FIND-003 — Persistence is event-driven with a 5 s debounce; SIGTERM equals graceful stop.** [source + observed]
  There is no periodic save. Layout mutations, agent reports and accepted OSC 7 cwd reports set a dirty flag, and a
  background writer saves 5 s later (`src/app/mod.rs:44`, `src/app/session.rs`). Writes are atomic (temp file,
  `fsync`, rename, directory `fsync`). SIGTERM and SIGINT log `server shutdown initiated reason=SIGTERM` and run the
  same final save as `herdr server stop`. SIGHUP is ignored. SIGKILL skips the final save, so changes within the
  debounce window are lost (w-split-fast). Scope: stop-to-exit took 0.2–0.9 s (controller `timeline.log`, including
  harness overhead) on local disk with idle panes and at most one idle agent. Shutdown time under durable network
  storage and busy agents was not measured, so this does not show that any particular Kubernetes grace period is
  sufficient (→ EXP-002). → REQ-006.
- **FIND-004 — A `cd` alone is persisted before a crash only if the shell emits OSC 7 with an empty or `localhost`
  host.** [observed + source] Herdr 0.9.5 rejects `file://<hostname>/…` (`src/pane/osc.rs:665-678`), the form many
  shell integrations emit. With no accepted OSC 7, nothing marks the session dirty after a `cd`, and SIGKILL restores
  the old directory (w-cd-noosc, w-cd-osc7). With `printf '\e]7;file://%s\a' "$PWD"`, the save ran 5.0 s after the
  `cd` and the cwd survived SIGKILL (w-cd-osc7e). → REQ-006.
- **FIND-005 — Session state, config, sockets and logs share `$XDG_CONFIG_HOME/herdr`.** [source + observed] This is
  not `$XDG_STATE_HOME`, which holds only rebuildable client and cache data. A writable config directory is
  therefore required. `HERDR_CONFIG_PATH` lets `config.toml` come from a read-only mount. → REQ-002, REQ-004.
- **FIND-006 — The Unix socket path must fit in 108 bytes.** [observed] With a long `XDG_CONFIG_HOME` the server
  failed to start (`local socket name length exceeds capacity of sun_path`); Herdr does not check this [source].
  Mount paths need to stay short, or `HERDR_SOCKET_PATH` must be set. → REQ-002.
- **FIND-007 — Claude Code conversations resume automatically, also on a headless server with no client.**
  [observed] After a clean restart and after SIGKILL plus a headless start, the pane relaunched
  `claude --resume <id>` in its saved cwd within about 1 s, and the agent recalled a codeword from before the
  restart. This contradicts the docs' "after a client attaches" and matches CHANGELOG 0.8.0 (#2064). Resume needs:
  the official hook installed in `~/.claude` (Herdr runs `python3` from the hook), the session ID stored in
  `session.json`, `claude` on the shell's `PATH`, a shell that starts, the same cwd, and Claude's own transcript
  store [source]. Resume is typed into a fresh shell, so rc files run first [source]. The hook is versioned with
  Herdr (FIND-009), so its install location and lifecycle matter in a pod (→ EXP-002). → REQ-003, REQ-006.
- **FIND-008 — Resume rebuilds the command line; original agent flags are lost.** [observed + source] The resumed
  argv was `claude --resume <id>` without `--model haiku`. The UI still showed a Haiku model (unverified whether
  Claude restored it). Flags such as permission modes must come from agent config files or wrappers, not the
  launch command line.
- **FIND-009 — Persisted state is compatible across tested versions; the live wire protocol is strict.** [observed +
  source] `session.json` is schema version 3 at every tag from v0.4.11 to v0.9.5. The 0.9.4 and 0.9.5 files were
  byte-identical after `jq -S`. 0.8.0 loaded and re-saved a 0.9.5 layout without changes. Snapshot structs ignore
  unknown fields, so an older binary drops newer fields on its next save (only `agent_resume`, for agents that
  self-report a resume command, is newer than 0.8.0) [source]. Client and server require equal protocol versions:
  a 0.8.0 CLI against a 0.9.5 server returned `protocol_mismatch: client protocol 19 is older than server protocol
  22`. The Claude integration hook is versioned with Herdr: with 0.9.5's v11 hook, a 0.8.0 server resumed the
  conversation but lost agent status transitions (`agent_prompt_stalled`). Live handoff (`herdr update --handoff`)
  passes PTY file descriptors between two processes on one host [source], so it cannot span a pod replacement
  [inference]. → REQ-002, REQ-006, REQ-009.
- **FIND-010 — Pane history is display-only, sensitive, and only as fresh as the last save.** [observed]
  `session-history.json` replayed screen text after clean and SIGKILL restarts. It is rewritten only with session
  saves, so output after the last save is lost on a crash, and it stores terminal output (secrets risk).
- **FIND-011 — The server's environment reaches every pane and agent; Herdr links its SSH agent.** [observed]
  Every variable visible to the server reached the panes, which is how the controller's `CLAUDE_CODE_*` variables
  leaked into early runs. Herdr adds `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`,
  `HERDR_WORKSPACE_ID` and `HERDR_BIN_PATH`, which the integration hooks use. When `SSH_AUTH_SOCK` is set,
  `herdr.sock.agent` is a symlink to it (here a gpg-agent SSH socket). This is relevant to agent-forwarded Git
  signing in EXP-004. → REQ-008.
- **FIND-012 — Default config makes outbound calls and expects interactivity.** [source + observed] Version and
  agent-manifest checks contact herdr.dev unless `[update] version_check=false, manifest_check=false`. First run shows
  onboarding unless `onboarding = false`. Claude Code's per-folder trust dialog defaults to "No, exit" and is stored
  in `~/.claude.json` [observed/general knowledge], so a new repository path needs a human decision once.

**Surprises:** headless resume works despite the docs (FIND-007); hostname-form OSC 7 is silently ignored
(FIND-004); SIGKILL did not leave orphans of the tested processes (FIND-002); the socket path limit (FIND-006).

**Unresolved questions** are listed with their disposition in [§8](#8-disposition-of-outstanding-work).

## 6. Architecture implications (proposals for review)

These are proposals; no accepted ADR is changed.

1. **Image (REQ-002).** Bake in `herdr`, `claude`, `codex`, `python3` (needed by integration hooks), `git` and the
   shell. Pin Herdr and every CLI that calls its socket to one version, because the protocol is strict (FIND-009).
   Ship a shell rc that emits OSC 7 as `file://$PWD` (FIND-004). Do not rely on `herdr update` in the pod.
2. **Volumes (REQ-004).** Use a home/state PVC for `$XDG_CONFIG_HOME/herdr` (minus `config.toml`), `~/.claude`,
   `~/.claude.json`, `~/.codex` and `HISTFILE`. Use the workspace PVC for repositories, mounted at a **stable
   absolute path** in every pod revision: Herdr restores literal cwds, and Claude keys transcripts by cwd
   (FIND-001, FIND-007). Keep socket paths under 108 bytes (FIND-006). Deliver `config.toml` as a read-only
   ConfigMap via `HERDR_CONFIG_PATH` (FIND-005). Inject credentials as Secrets rather than baking them in.
3. **Integrations (open decision for EXP-002).** `herdr integration install claude|codex` writes versioned hook
   files and settings into the agent home, and the hook must match the Herdr server version (FIND-007, FIND-009).
   Hooks baked into the image can be hidden by the persistent agent-home mount, and a missing or outdated hook
   silently disables resume or status tracking. Options to compare in EXP-002 — idempotent startup reconciliation,
   seeding a home at image build, or keeping hooks outside the mounted home — judged on preserving user settings
   and supporting Herdr rollback. Not implemented here.
4. **Lifecycle (REQ-006).** SIGTERM triggers a complete final save locally (FIND-003), but the time it needs in a
   pod is unmeasured. Do not assume the default `terminationGracePeriodSeconds` is sufficient; EXP-002 should
   measure shutdown duration with durable storage and active agents and record what is lost when grace expires
   (a SIGKILL falls back to the last debounced save). Every pod replacement still ends in-pane agent processes and
   in-flight turns (FIND-002). A listening socket or a Ready pod is not proof of recovery: verify restored layout
   (`herdr api snapshot`) and resumed agents (`herdr agent list`, a recall check) separately.
5. **GitOps upgrades and rollback.** Snapshot `session.json` (and `session-snapshots/`) before every image change.
   Rollback is safe across the tested range, but test a schema version bump explicitly (FIND-009). REQ-009 cannot be
   met by live handoff and needs the separated execution model already deferred in ADR-0001.
6. **Security.** Start Herdr with an explicit, minimal environment, because the server environment is inherited by
   every pane and agent (FIND-011). Keep pane history off (FIND-010), review the SSH-agent symlink (FIND-011), and
   disable herdr.dev checks (FIND-012).

Candidate requirement wording for review: REQ-006 could state "after a graceful stop, layout and cwd are restored
exactly; after a forced stop, state older than ~5 s is restored; agent conversations, not processes, are resumed".

## 7. Follow-up recommendations

- **EXP-002 ([#3](https://github.com/jlaska/herdrnetes/issues/3)):** Repeat B and C as Kubernetes pod deletion,
  rollout, drain and OOM/eviction, with shutdown timing and separate recovery verification. Verify the PVC layout
  above, the short socket path, `HERDR_CONFIG_PATH`, headless start as the pod entrypoint, agent resume without a
  client, and decide the hook lifecycle.
- **Agent follow-up ([#10](https://github.com/jlaska/herdrnetes/issues/10)):** Codex resume, and Claude/Codex CLI
  version upgrade and rollback against existing conversations.
- **EXP-004 ([#5](https://github.com/jlaska/herdrnetes/issues/5)):** SSH agent socket handling (FIND-011) for commit
  signing without a local YubiKey.
- **Deferred ([#11](https://github.com/jlaska/herdrnetes/issues/11)):** zsh, duplicate session refs, and optional
  upstream questions (headless-resume docs, hostname-form OSC 7).

## 8. Disposition of outstanding work

| Item | Source | Disposition |
| --- | --- | --- |
| Shutdown duration vs grace period with durable storage and busy agents | FIND-003 | EXP-002 [#3](https://github.com/jlaska/herdrnetes/issues/3) |
| Kubernetes exits: pod deletion, rollout, node drain, OOM kill/eviction | FIND-002, FIND-003 | EXP-002 [#3](https://github.com/jlaska/herdrnetes/issues/3) |
| Recovery verification separate from readiness | FIND-001, FIND-007 | EXP-002 [#3](https://github.com/jlaska/herdrnetes/issues/3) |
| Mount layout, stable paths, resume when the saved cwd is missing (PVC not mounted) | FIND-001, FIND-005, FIND-006 | EXP-002 [#3](https://github.com/jlaska/herdrnetes/issues/3) |
| Versioned hook lifecycle in the image vs the persistent agent home (decision + test) | FIND-007, FIND-009 | EXP-002 [#3](https://github.com/jlaska/herdrnetes/issues/3) |
| Codex resume end to end | FIND-007 | Follow-up [#10](https://github.com/jlaska/herdrnetes/issues/10) |
| Claude/Codex CLI upgrade and rollback against existing conversations | FIND-009 | Follow-up [#10](https://github.com/jlaska/herdrnetes/issues/10) |
| Processes that detach from the terminal (`setsid`, `nohup`, daemons) | FIND-002 | Not tracked; out of MVP scope, which assumes in-pane agents are interrupted |
| SSH agent socket for signing | FIND-011 | EXP-004 [#5](https://github.com/jlaska/herdrnetes/issues/5) |
| zsh history flush and OSC 7 form | FIND-004 | Deferred [#11](https://github.com/jlaska/herdrnetes/issues/11) |
| Two panes with the same Claude session ref (only the first resumes [source]) | FIND-007 | Deferred [#11](https://github.com/jlaska/herdrnetes/issues/11) |
| Upstream: headless-resume docs mismatch; hostname-form OSC 7 | FIND-004, FIND-007 | Deferred, optional [#11](https://github.com/jlaska/herdrnetes/issues/11) |

None of these changes the trusted single-instance MVP scope or any accepted ADR.
