# EXP-002 run log

Observed results, recorded as each run completed. Raw evidence (pane screens, `session.json`, Herdr logs, state
backups) stays outside the repository, because it can contain conversation text and session IDs. Only redacted
summaries are recorded here. Cluster, node and GitOps-repository names are withheld (public repository).

## s1 — local podman smoke test, image `h095-c311` (2026-11-15)

Image: `ghcr.io/jlaska/herdrnetes-herdr:exp002-h095-c311`, local image ID
`d07706580a36a53f4e848353cfa8f407f1ce59f4f42f4afa8feda51b2477503f` (846 MB, not yet pushed). Contents recorded in
[`evidence/images/h095-c311.manifest.txt`](evidence/images/h095-c311.manifest.txt): Herdr 0.9.5 (release binary,
SHA-256 `14d9e8bc…59929d`), Claude Code 2.1.311, Codex CLI 0.169.0, and Debian trixie packages.

Constraints mirrored the planned pod: uid/gid 1000 (`--userns=keep-id`), `--read-only` root filesystem,
`--cap-drop=ALL`, `no-new-privileges`, tmpfs `/tmp` and `/run/herdr`, and host directories as `/home/herdr` and
`/workspace`. Procedure: [`image/smoke.sh`](image/smoke.sh).

- **Headless start:** `herdr server` answered `herdr status server` (`private_protocol: 22`) with no client attached.
  The entrypoint took about 0.1 s before `exec herdr server`.
- **Sockets:** `herdr.sock` and `herdr-client.sock` live in `/home/herdr/.config/herdr/`, which is the home volume,
  next to `session.json` and `herdr-server.log` (consistent with FIND-005).
- **Hooks (strategy R):** `herdr integration install claude|codex` ran on the empty persistent home after the
  entrypoint created `~/.claude` and `~/.codex`. `integration status` then reported `claude: current (v11)` and
  `codex: current (v10)`. `settings.json` contains only Herdr's `SessionStart` entry, which runs
  `bash '/home/herdr/.claude/hooks/herdr-agent-state.sh' session`, so the hook needs `bash` as well as `python3`.
  Codex `config.toml` kept the seeded `check_for_update_on_startup = false` and gained `[features] hooks = true`.
- **Environment:** pane processes saw only the allowlist plus Herdr's own variables (`HERDR_ENV`, `HERDR_PANE_ID`,
  `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_BIN_PATH`, `TERM_PROGRAM*`, `COLORTERM`, and
  `fish_handle_reflow`). No container-runtime variables (`HOSTNAME`, `KUBERNETES_*`) reached them (FIND-011).
- **SIGTERM:** `podman stop` sent SIGTERM through `tini` to Herdr. The log showed `server shutdown initiated
  reason=SIGTERM`, then `session saved … workspaces=1`, then `herdr exiting`, with exit code 0. That took 0.21 s
  controller-measured, or 72 ms from the SIGTERM log line to exit (one idle workspace, local disk).
- **Not covered:** restore after restart (covered by the cluster scenarios) and Claude login/onboarding (no
  credentials in this test).

## h-R / h-S — local hook lifecycle across image changes on one persistent home (2026-11-15)

Procedure: [`image/hooks-test.sh`](image/hooks-test.sh). It runs successive image variants against a single home
directory, which is equivalent to GitOps image changes that keep the `home` PVC. The constraints are the same as s1.
Before the first hop, a user-owned Claude `SessionStart` hook (`echo user-hook`) and a `permissions.allow` entry were
seeded into `~/.claude/settings.json`. Each hop recorded `herdr integration status`, the hook headers,
`settings.json`, Codex `hooks.json`/`config.toml` and the restored layout (2 workspaces, 3 panes, a label, a split).
No agent ran, because no credentials were available, so this tests file and layout lifecycle only, not agent resume.

Local image IDs: `h095-c311` `d0770658…`, `h094-c311` `4b0afa2d…`, `h080-c311` `39bbb037…`, `h095-c325` `804e0e5c…`
(838–919 MB, not pushed).

**Strategy R (reconcile on every start)**, hops 0.9.5 → 0.8.0 → 0.9.5 → 0.9.4 → 0.9.5:

| Hop | Herdr | Claude hook | Codex hook | Codex `hooks.json` events | Claude `settings.json` |
| --- | --- | --- | --- | --- | --- |
| 1 | 0.9.5 | v11 | v10 | SessionStart | user hook + permissions kept; Herdr entry added (matcher `^(startup\|resume\|clear\|compact\|fork)$`) |
| 2 | 0.8.0 | v7 | v7 | SessionStart | user entries kept; Herdr entry rewritten (matcher `*`), no duplicate |
| 3 | 0.9.5 | v11 | v10 | SessionStart | **byte-identical to hop 1** |
| 4 | 0.9.4 | v10 | v9 | SessionStart, UserPromptSubmit, Stop, Interrupt | user entries kept |
| 5 | 0.9.5 | v11 | v10 | SessionStart (0.9.4's turn hooks **removed**) | identical to hop 1 |

- In every hop the installed hook matched the running binary, and `integration status` said `current`.
- User hooks and settings survived every upgrade and rollback. Herdr's install only replaced its own entries,
  including the deprecated Codex turn hooks that 0.9.4 had added.
- Layout and labels were restored on every hop. 0.9.4 ↔ 0.9.5 `session.json` files were identical (`jq -S`).
  0.8.0 renumbered pane IDs and wrote `sidebar_width`/`sidebar_section_split` values, which 0.9.5 reset to `null`,
  consistent with FIND-009. No `session-backups/` were created and no restore or protocol errors were logged.

**Strategy S (no reconciliation after the first start)**, hops 0.9.5 → 0.8.0 → 0.9.5:

- The persisted v11/v10 hooks stayed in place under 0.8.0, whose own hooks are v7.
- **0.8.0's `herdr integration status` reported `claude: current (v11)`.** The older binary does not flag a newer,
  mismatched hook. So `integration status` cannot detect a stale hook after a rollback, and a startup guard based on
  it would pass. EXP-001 (v80d) showed what this combination does at runtime: conversation resume worked, but agent
  status tracking degraded (`agent_prompt_stalled`).
