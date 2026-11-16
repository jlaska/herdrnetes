# EXP-003 Ovis sidecar (candidate, unreviewed, not deployed)

Access path E of [`docs/experiments/03-remote-access.md`](../../docs/experiments/03-remote-access.md): Ovis v0.5.4
(commit `b9d079808f0b0565fa9c380237d92f81d1164e0d`) as a second container in the Herdr pod. Status: **proposal**; locally
validated only (`image/smoke.sh`, evidence in `evidence/ovis-local/`). Nothing was pushed or applied to a cluster.

| Path | Purpose |
| --- | --- |
| `image/Containerfile`, `image/build.sh` | `FROM` the EXP-002 image by digest; adds `/opt/ovis` from the release; build-time SHA-256 pins plus Ed25519 check of `ovis-server.json` against the key pinned in Ovis source |
| `image/ovis-entrypoint.sh` | Fails closed: refuses to start without a token of 24+ characters, a non-loopback `HOST`, or `OVIS_TELEMETRY` other than 0 |
| `image/smoke.sh` | podman pod validation (Herdr + Ovis, read-only home/workspace, no network variant, restart isolation) |
| `deploy/` | kustomize overlay on `../exp-002/deploy/base`; `deploy/diff-vs-base.sh` proves only the container and two emptyDirs are added |
| `harness/seal-ovis-token.sh` | Owner-run: random token, SealedSecret `herdr-ovis-token`, plaintext to a 0600 file outside the repo |
| `evidence/` | image manifest/id, kustomize diff, smoke evidence |

## Behaviour that matters (observed in v0.5.4, local)

- **With `OVIS_TOKEN` set, loopback is not trusted.** `server/access.ts decideAccess`: a matching token or paired
  device is accepted; otherwise `if (input.tokenConfigured) return token_required` precedes the `loopback && !forwarded`
  "local" grant. Verified: `/api/session` and `/ws` return 401 from 127.0.0.1 and the pod IP without the token.
  `GET /api/health` is open and reveals only versions and the auth requirement. **Without a token**, loopback and (for a
  non-loopback bind) any source get full control: the entrypoint therefore refuses an empty token. Any process in the
  pod that can read the token (Ovis's own `/proc/<pid>/environ`, same uid) or the Secret can authenticate; agent panes
  run as uid 1000 in a different container (separate PID namespace) and do not see the Ovis environment.
- **Read-only home needs `HOME` elsewhere.** Ovis hard-codes `$HOME/.config/herdr-web-ui/bridges` (`server/bridge.ts`
  `bridgeRegistry`) and exits on EROFS at startup. `herdr terminal attach` writes `$HOME/.config/herdr/herdr-client.log`,
  and the PTY host starts commands in `$HOME`. Hence `HOME=/var/lib/ovis` (emptyDir), with `CLAUDE_CONFIG_DIR` and
  `CODEX_HOME` pointing at the read-only home so transcripts are still read. Connecting to the Herdr socket on the
  read-only mount works. **Claude transcript reading was not exercised** (no Claude in the local test).
- **No relay by default**: relay phase `off`; it is a Settings action, and the token holder could turn it on
  (`/api/relay`). There is no environment knob that forbids it; egress NetworkPolicy would. Telemetry stays off via
  `OVIS_TELEMETRY=0`/`DO_NOT_TRACK=1` (the saved `enabled:true` in `telemetry.json` is the preference, overridden by env).
- **`ovis-server serve` has no supervisor**: no GitHub update check and `/api/updates/install` answers 409
  `updates_unmanaged`.
- **"Update herdr" cannot be disabled by a knob.** `POST /api/herdr/update` (token + `X-Herdr-Update: 1` + same origin)
  runs `$OVIS_HERDR_BIN update --handoff`. Containment here is incidental: read-only rootfs, `/usr/local/bin` not owned by
  uid 1000, and the image has no `curl` (herdr's update shells out to it; locally it failed with `curl failed: No such
  file or directory`, server pid unchanged). Do not rely on this across Herdr versions; a future Herdr could update
  differently. Ovis's own `herdr update` call also passes `HERDR_SOCKET_PATH`, so it targets this pod's server.
- Ovis can create/close workspaces and type into panes through the Herdr socket regardless of the read-only mounts;
  read-only mounts limit file writes, not terminal power.
