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

## Cluster deployment (2026-11-15)

**Environment:**
- Cluster: the 3-node amd64 Argo CD hub. It runs Talos v1.14.5 and Kubernetes v1.36.6 with containerd 2.3.7, and Cilium as the CNI.
- Namespace `herdrnetes-exp` with Pod Security `restricted` enforced.
- Storage: Longhorn `longhorn` StorageClass (3 replicas, ext4).
- Deployment: Argo CD Application `<cluster>-herdrnetes-exp`, generated by the existing `apps` ApplicationSet from the private GitOps repo. It runs with automated sync, prune and selfHeal.
- Image: `ghcr.io/jlaska/herdrnetes-herdr:exp002-h095-c311@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277` (358 MB compressed).

| Variant | Pushed digest |
| --- | --- |
| h095-c311 | `sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277` |
| h094-c311 | `sha256:13da2704ecf48431b13e1c1e3f0f25791863afdb541a7e1f765bdb86387073e8` |
| h080-c311 | `sha256:76128b1c4a6f52161d376f583eaa7de328914e46a9432961e8cb55043d6e0428` |
| h095-c325 | `sha256:c5a848ddd6defedb18bfebd8cbf27b71dd9cf791aff520e6d2a19ae4aa4a8d58` |

**First sync.** A signed GitOps commit was pushed, and the Application reached `Synced/Healthy`. From the Kubernetes events:

| Time | Event |
| --- | --- |
| t=0 s | StatefulSet created pod and claims |
| t+2 s | Both Longhorn PVCs provisioned (Immediate binding; two transient `FailedScheduling: unbound immediate PersistentVolumeClaims`) |
| t+12–13 s | Volumes attached |
| t+13–25 s | Image pulled (11.8 s) |
| t+25 s | Container started |
| t+26 s | Ready |

The SealedSecret unsealed into `herdr-claude-token`.

## A — baseline (run r1)

- **Process tree:** PID 1 is `tini`, which runs `herdr server` as PID 7 (uid 1000). The root filesystem is read-only (`touch /usr/local/bin/x` gives `Read-only file system`), and no ServiceAccount token is mounted.
- **Mounts:** `/home/herdr` and `/workspace` are separate Longhorn ext4 volumes. `/etc/herdr` is the ConfigMap, mounted read-only and loaded through `HERDR_CONFIG_PATH`. `/run/herdr` is tmpfs and `/tmp` is an emptyDir.
- **Server startup:** the server started headless with no client. On first start it logged `persist.restore outcome=missing`. `integration status` reported Claude v11 and Codex v10, both `current`.
- **Server environment:** names only (values not recorded) are the allowlist plus `CLAUDE_CODE_OAUTH_TOKEN`, passed by name from the Secret. No `KUBERNETES_*` variables or service links are present.
- **Layout:** `setup` created 2 workspaces with 5 panes. EXP-001 had 3 workspaces and 6 panes because its attached TUI client created an extra default workspace; a headless server creates none.
- **Claude Code 2.1.311 with `CLAUDE_CODE_OAUTH_TOKEN`:**
  - No login or onboarding screen appeared. The seeded `~/.claude.json` and the token were enough.
  - The folder-trust dialog still appeared for the new repository path and was answered once (FIND-012).
  - Herdr detected the agent about 2 s after launch. The codeword prompt finished, and `ask` recalled it (YES).
- **Claude state on the home PVC:** the transcript was written under `~/.claude/projects/-workspace-exp-r1-beta/`. `history.jsonl`, `sessions/`, `session-env/`, `backups/` and `policy-limits.json` were also written to the home PVC.
- **Detached operation:** with no client ever attached, `herdr status server` and `herdr agent list` kept working, and the agent reported `done`.

## B — graceful pod replacement: `kubectl delete pod herdr-0` (r1, default grace = 60 s)

The pod stayed on the same node; Longhorn detached and reattached both volumes.

| Event (UTC 2026-11-15) | Source | Time | Δ from delete |
| --- | --- | --- | --- |
| `kubectl delete` issued | controller | 22:37:38.2 | 0 |
| `server shutdown initiated reason=SIGTERM` | Herdr log | 22:37:38.358 | ~0.2 s |
| `session saved workspaces=2` | Herdr log | 22:37:38.414 | |
| each pane `ExitStatus { code: 1, signal: Hangup }` | Herdr log | | |
| `herdr exiting` | Herdr log | 22:37:38.537 | **SIGTERM→exit 179 ms** |
| replacement pod created | controller | 22:37:40 | ~2 s |
| `session restore evaluated outcome=ok workspaces=2` | Herdr log | 22:37:48.701 | |
| `herdr status server` answers | controller | | **11.0 s** |
| layout complete (2 workspaces, 5 panes) | controller (`api snapshot`) | | **11.3 s** |
| `agent changed pane=5 agent=Claude` (resume detected) | Herdr log | 22:37:50.573 | 1.9 s after restore |
| pod Ready | Kubernetes | 22:37:50 | |

**Restored state:**

- **Restored automatically (R):**
  - Workspaces, tabs, splits, the label and all pane cwds; the cwds matched the baseline exactly.
  - The Claude conversation: the pane relaunched as `claude --resume <id>`, the agent was detected, and the codeword was recalled (YES).
  - Git working trees, including modified and untracked files; they were unchanged.
  - Shell history: the `MARK` count went from 3 to 4. The added line is the `sleep` pane's command, which bash flushed on SIGHUP (FIND-002/003 behaviour, now on Longhorn).
- **Lost (L):**
  - Foreground `sleep 86400` and the background HTTP server.
  - The exported `EXP_VAR` (`ENVCHECK EXP_VAR=[]`).
  - The `--model haiku` launch flag (FIND-008).

**Conclusion:** the SIGTERM save takes milliseconds, so the 60 s grace period is not a constraint at this scale. Most of the 11 s is Kubernetes work: pod termination and creation plus Longhorn detach and attach. Herdr itself restored and resumed in under 2 s.

## C1 — SIGKILL of Herdr inside the container (container restart, same pod)

The harness ran `kill -KILL <herdr pid>` twice by mistake (22:38:21 and 22:38:43), once more than planned.

- **Termination:** `lastState.terminated` was `reason=Error exitCode=137`. The log has no shutdown or save lines; Herdr restored from the last debounced save (22:38:30 for the second kill).
- **Restart timing:** the container restarted in place, so volumes stayed attached.

| Kill | restartCount | Server answers | Layout restored | Notes |
| --- | --- | --- | --- | --- |
| 1st | 0 → 1 | 2.5 s | 2.7 s | |
| 2nd | 1 → 2 | 14.6 s | 14.8 s | Agent detected at 14.8 s. Kubelet's crash backoff (~10 s, doubling per restart up to 5 min) adds directly to recovery |

- **Restored and lost:** the same set as B, both times. The codeword was recalled (YES).
- **Conclusion:** a repeated in-container crash is slower to recover than a graceful pod replacement, because of the backoff.

## C2–C6 — crash, short grace, OOM and force delete (r1, 2026-11-15 23:18–23:21 UTC)

Each disruption ran once. The pod stayed on the same node throughout, and the image digest never changed. Δ times are
controller-measured from the moment of disruption.

| Run | Disruption | Herdr shutdown and save | Server answers | Layout restored | Agent resumed | Codeword |
| --- | --- | --- | --- | --- | --- | --- |
| C2 | `cd` (OSC 7) → 8 s → SIGKILL | none; last autosave 5 s after the `cd` | 1.6 s | 1.8 s | 1.8 s | YES |
| C3 | `pane split` → 2.7 s → SIGKILL | none; no save between split and kill | 12.2 s ¹ | 12.4 s | 12.4 s | YES |
| C4 | `kubectl delete --grace-period=1` | SIGTERM → saved → exit in 0.18 s | 4.0 s | 4.3 s | 4.3 s | YES |
| C5 | pane allocates past 4 GiB limit | none | 3.4 s | 3.6 s | 3.6 s | YES |
| C6 | `kubectl delete --grace-period=0 --force` | SIGTERM → saved → exit in 0.20 s | 1.5 s | 1.7 s | 1.7 s | YES |

¹ This was the 4th container restart in about 3 minutes, so kubelet's crash backoff was in effect (see C1).

- **C2 — OSC 7 makes a bare `cd` crash-safe.**
  - The image's bashrc emits `file://$PWD`.
  - The `cd` was saved 5 s later (debounce), and the cwd survived SIGKILL. The pane came back in
    `/workspace/exp/r1/beta`.
  - This confirms the FIND-004 mitigation in the image.
- **C3 — the 5 s debounce window behaves the same on Longhorn.**
  - A split made 2.7 s before SIGKILL was lost: 5 panes after restart, not 6.
  - Everything saved earlier was restored.
- **C4 — a 1 s grace period was enough.** The SIGTERM save took about 0.2 s.
- **C5 — OOM kills the whole container, not just the offending pane process.**
  - `lastState.terminated: reason=OOMKilled exitCode=137`, with no shutdown or save in Herdr's log.
  - Herdr restored from the last autosave (18 s old). Every pane and agent process ended, so one runaway pane
    process took down the whole Herdr pod.
  - This is consistent with Kubernetes ≥ 1.32 on cgroup v2 setting `memory.oom.group` for the container. [inference:
    which process the kernel selected was not checked]
- **C6 — force deletion still delivered SIGTERM, and Herdr saved cleanly.**
  - The API object was removed immediately, and the replacement pod was created **0.17 s after** the delete,
    **before the old Herdr process had exited** (exit at +0.25 s).
  - Both pods were on the same node, where a Longhorn RWO volume can be mounted by both at once. No Multi-Attach
    event occurred.
  - Here the old server exited before the new one started. Nothing guarantees that ordering, so a force delete can
    briefly run two Herdr writers on the same `session.json`. [inference, not reproduced]
- **Every C run:**
  - The git trees were unchanged.
  - `EXP_VAR` and the `sleep`/HTTP-server processes were lost.
  - Claude relaunched as `claude --resume <id>`.
  - Shell history kept its 4 `MARK` lines.

## D/E — Argo CD-driven image changes (r1)

Procedure: [`harness/gitops-step.sh`](harness/gitops-step.sh).
1. Back up the state.
2. Start a recovery watcher (`scenario.sh disrupt external`).
3. Edit the one `image:` line in the GitOps repo's StatefulSet.
4. Make an owner-signed commit (YubiKey) and push over HTTPS.
5. Wait for Argo CD (default polling, no manual refresh) to sync the commit. The StatefulSet controller then replaces
   the pod, and the watcher measures recovery.

No `kubectl` write was involved.

| Step | Change | Argo CD sync after push | Old pod SIGTERM → exit | New pod created → Ready | Layout | Claude resume | Codeword | Hooks after |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D1 | Claude 2.1.311 → **2.1.325** (Herdr 0.9.5 unchanged) | 11.0 s | clean save | ~10 s | R | R (`claude --resume <id>` under 2.1.325) | YES | claude v11 / codex v10 (unchanged) |
| E1 | Claude 2.1.325 → **2.1.311** (rollback) | **327 s** | 0.21 s (00:06:26.294 → .500) | 00:06:27 → 00:06:37 | R | R (2.1.325-written transcript resumed by 2.1.311) | YES | v11 / v10 |
| E2 | Herdr 0.9.5 → **0.9.4** (rollback; Claude unchanged) | 10 s | 0.22 s (00:25:48.464 → .686) | 00:25:49 → 00:26:10 (first pull of this image) | R | R | YES | claude **v10** / codex **v9** (reconciled down) |
| D2 | Herdr 0.9.4 → **0.9.5** (primary acceptance) | 11.2 s | 0.21 s (02:43:10.637 → .843) | 02:43:11.9 → 02:43:22.4 (10.5 s) | R (`restore … outcome="ok" workspaces=2`) | R | YES | v11 / v10 |
| E3 | Herdr 0.9.5 → **0.8.0** (hook v7, protocol 19) | **247 s** | 0.20 s (02:52:39.074 → .273) | 02:52:40 → 02:52:54 (first pull) | R (0.8.0 read the 0.9.5-written `version: 3` session) | R | YES on retry¹ | **v7 / v7** |
| D3 | Herdr 0.8.0 → **0.9.5** | 10.2 s | 0.21 s (12:25:36.614 → .828; shut down by 0.8.0) | 12:25:37 → 12:25:47 | R (`outcome=ok workspaces=2`) | R | YES | v11 / v10 |

¹ Under 0.8.0 the first `herdr agent prompt` returned `agent_prompt_stalled`. The harness retry was answered. The agent
then showed `idle` where 0.9.5 shows `done`.

`recovery.json` for the D/E steps is measured from when the watcher started, which is before the signing touch and
push. The comparable figure is pod created → Ready in the table above.

Every step lost the same things as scenario B, and kept the same things:
- **Lost:** pane processes and launch flags. The `sleep` pane came back as bash, and Claude came back as
  `claude --resume <id>` without `--model`.
- **Kept:** git trees and bash history (MARK 3 → 4). The pane cwd moved by the C2 `cd` stayed moved.

- **Argo CD latency.** Sync came between 11 s and 327 s after the push, consistent with periodic repository polling.
  D1 happened to land just before a poll. This latency dominates GitOps update time. A Git webhook would remove it.
- **Shutdown snapshot.** On a SIGTERM shutdown, Herdr 0.9.5 also wrote a layout snapshot
  (`persist.backup ok … session-snapshots/session-…json`) before `session saved`. It did not create
  `session-backups/`.
- **Agent version change in both directions.** A Claude Code change (2.1.311 ↔ 2.1.325) with Herdr fixed needed no
  hook change (the Claude hook is Herdr-versioned). In this single test it preserved conversation resume both ways.
  The pane screen showed no migration or what's-new notice. Full agent CLI compatibility remains #10.
- **Herdr version change in both directions, including across the 0.8 → 0.9 boundary.** Each version read the
  session file written by the other (schema `version: 3` in all three). Reconcile-on-start (strategy R) moved the
  hook scripts to the running binary's version both up and down: 0.9.4 v10/v9, 0.8.0 v7/v7, 0.9.5 v11/v10. Without
  reconcile, 0.8.0 reports the newer v11 hook as "current" (h-S), so this would go undetected.
- **Concurrent GitOps writers.** Renovate pushed 7 commits to the same branch between D3's prepare and apply. The
  signed commit was then rejected as a non-fast-forward after the touch. `gitops-step.sh apply` now fetches and
  fast-forwards before committing.

## F — ConfigMap change through GitOps (r1, 2026-11-16 12:36–13:07 UTC)

Procedure: [`harness/config-step.sh`](harness/config-step.sh).
1. Change `[experimental] pane_history` in the GitOps copy of `config.toml`, then make a signed commit and push.
2. Wait for Argo CD to sync, then poll the mounted `/etc/herdr/config.toml` in the pod every second.
3. Wait 30 s, then read Herdr's server log for any reaction.
4. Run `herdr config check` and `herdr server reload-config` once.

The ConfigMap has a fixed name (`disableNameSuffixHash`) and no reloader is installed.

| Step | Change | Argo CD sync after push | File visible in pod | Herdr log lines in the 30 s after the file changed | `reload-config` | Pod / server PID / restarts |
| --- | --- | --- | --- | --- | --- | --- |
| F1 | `pane_history` false → **true** | 11.2 s | +86.2 s after push (75.0 s after sync detected) | **0** | `{"status":"applied","diagnostics":[]}`, about 9 ms | same / same / 0 |
| F2 | true → **false** (revert) | 11.3 s | +11.4 s after push (Argo applied 13:06:48–49; kubelet swapped `..data` at 13:06:56) | **0** | `applied` | same / same / 0 |

- **No restart.** A ConfigMap-only change replaced neither the pod nor the Herdr process. Panes and agents kept running.
- **The kubelet updates the file all at once,** through the `..data` symlink swap (no `subPath`). The delay from Argo
  CD applying the change to the new file appearing ranged from about 7 s to about 75 s. That is consistent with the
  kubelet's periodic volume resync.
- **Herdr does not watch its config file.** No log line and no behaviour change appeared until
  `herdr server reload-config`, which applied the new file with no diagnostics. Not verified: whether `pane_history`
  itself takes effect live (only the reload status was checked).
- **When the config is used:** a ConfigMap change takes effect at the next explicit reload or the next pod start.
  Until then, the running server and the mounted file can disagree with no visible signal.

## G2 — saved workspace directory unavailable (r1, 2026-11-16 00:13–00:20 UTC)

**G2a — directory renamed while Herdr runs, then graceful replacement.** `mv beta beta.hidden`, then
`kubectl delete pod`.

- Running shells follow a renamed directory: their `/proc/<pid>/cwd` is now `…/beta.hidden`.
- Herdr's shutdown save reads the live cwds, so it **persisted the renamed path**. The panes were restored in
  `beta.hidden`.
- Claude relaunched as `claude --resume <id>` in the unfamiliar path and **blocked at the folder-trust dialog**
  (`agent_status: blocked`).
- Moving the directory back did not change the live panes. A further restart then restored `beta`, and the codeword
  was recalled (YES).
- **Conclusion:** renaming or moving a repository under a running Herdr is persisted silently. Claude's
  per-directory trust and transcript lookup then see a new path. **M**: recoverable after moving the directory back
  and restarting.

**G2b — saved directory missing at restore.** `mv beta beta.hidden && kill -KILL <herdr>` in one command, so no save
could record the rename.

- Restart log: `WARN preserving unavailable restored pane cwd=/workspace/exp/r1/beta`, once per affected pane (3),
  followed by `session restore evaluated outcome=ok`.
- Herdr **kept the saved cwd and did not fall back** to `$HOME` or `/`. Each affected pane got
  `restore_error: "Saved directory is unavailable. Restore the directory and restart this session."`
  - No PTY or shell was spawned: `pane read` and `process-info` return `pane_not_found`, though `pane list` still
    shows the panes.
  - No agent started (`agent list` was empty).
  - Panes with available cwds restored normally.
- `session.json` was **not rewritten**. The cwds and the Claude `agent_session` reference were preserved.
- After restoring the directory and replacing the pod, Claude resumed (`claude --resume <id>`) and the codeword was
  recalled (YES).
- **Conclusion:** if the workspace PVC or a repository is missing at start, Herdr starts and preserves those panes
  for later, rather than silently re-rooting them. **M**: restore the directory, then restart Herdr. A missing mount
  therefore does not corrupt state.

(Harness note: `probe` aborted on a pane that had no process. This is now fixed in `scenario.sh`.)

## G3/G4 — node relocation through GitOps (r1, 2026-11-16 13:15–13:19 UTC)

Procedure: `gitops-step.sh … node=<name>`. It adds a `nodeSelector` (`kubernetes.io/hostname`) to the StatefulSet pod
template with a signed commit; `node=-` removes it again. No node was cordoned or drained, so other workloads were not
affected. Every node had a Longhorn replica of both volumes (3 replicas).

**G3 — move to another node.**

| Event (UTC) | Source | Time | Δ |
| --- | --- | --- | --- |
| push | controller | 13:15:59 | 0 |
| Argo CD synced | Argo CD | 13:16:10 | 11.0 s |
| old pod deleted; Herdr SIGTERM save | Kubernetes / Herdr | 13:16:09 | |
| replacement pod created and scheduled on the new node | Kubernetes | 13:16:10 | |
| `FailedAttachVolume … already exclusively attached to one node, waiting on detach` (both volumes) | Kubernetes | 13:16:10 | |
| `AttachVolume.Attach succeeded` (both volumes) | Kubernetes | 13:16:27 | **17 s detach + attach** |
| image pulled (358 MB, not cached on that node) | Kubernetes | 13:16:28 → 33 | 5.5 s |
| container started → Ready | Kubernetes | 13:16:34 → 35 | |
| **replacement created → Ready** | | | **25 s** |

- Restore: `outcome=ok`. All pane cwds were identical, git trees were unchanged, and Claude relaunched as
  `claude --resume <id>`. The codeword was recalled (YES).
- **Cross-node RWO blocks a second writer.** Longhorn would not attach a volume to the new node until the old node
  had detached it. Compare C6: on the same node, the old and new pods overlapped.
- In the first probe after the move, the Claude pane's `agent_status` was `unknown`. It answered when prompted.

**G4 — remove the nodeSelector** (back to the baseline manifest). The pod was replaced again and the scheduler kept it
on the same node. Volumes were already attached there and the image was cached, so replacement created → Ready took
**4 s** (13:18:56 → 13:19:00). Argo CD synced in 10.4 s. Codeword YES.

**Not done:** a real node drain or cordon. That affects shared workloads and needs owner approval. G3 exercises the same
storage path (detach, cross-node attach, pull) without one.
