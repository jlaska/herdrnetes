# EXP-003 Ovis sidecar (experiment deployment, non-production)

Access path E of [`docs/experiments/03-remote-access.md`](../../docs/experiments/03-remote-access.md): Ovis v0.5.4
(commit `b9d079808f0b0565fa9c380237d92f81d1164e0d`) as a second container in the Herdr pod.

**Status:**
- **Local validation:** done with `image/smoke.sh`; evidence in `evidence/ovis-local/`.
- **Image:** pushed to `ghcr.io/jlaska/herdrnetes-ovis:exp003-o054-h095@sha256:8e31cc27ca866dc47f9cb0f519abce844db8a75974c5d147b91fdbcff46ef0db`.
- **Experiment cluster:** deployed 2026-11-16 to `herdrnetes-exp` with the owner's approval, by one owner-signed commit
  to the private GitOps repository. Results: [`RESULTS-ovis.md`](RESULTS-ovis.md).
- **Two copies of the manifests.** `deploy/` in this repository is a static reference: a kustomize overlay on the
  EXP-002 base, used to review and diff the change (`deploy/diff-vs-base.sh`). The **live** configuration is a separate
  copy in the private GitOps repository. It carries the same patch, the digest-pinned image and the owner-sealed
  `herdr-ovis-token`. Changes reach the cluster only through that repository. Applying `deploy/` directly is not part of
  the procedure.
- **Approval scope.** The deployment is a non-production experiment. The owner's approval covered this prototype only.
  It does not accept a permanent architecture, and no ADR records it. REQ-005 still intends optional services to run
  in separate pods. That is impossible with Herdr 0.9.5 and Ovis 0.5.4 (FIND-028), so the sidecar is an owner-approved
  experiment **exception**, and its upgrades replace the Herdr pod (FIND-029, FIND-036). Follow-ups:
  [#21](https://github.com/jlaska/herdrnetes/issues/21) (separate-pod transport) and
  [#22](https://github.com/jlaska/herdrnetes/issues/22) (hardening).
- **Token rotated 2026-11-16.** The first token appeared in an agent transcript and was rotated using the procedure in
  [Token rotation](#token-rotation-owner-run). Afterwards the old token got 401 and the new one 200. The Herdr identity
  diff was unchanged ([#22](https://github.com/jlaska/herdrnetes/issues/22)).

| Path | Purpose |
| --- | --- |
| `image/Containerfile`, `image/build.sh` | `FROM` the EXP-002 image by digest; adds `/opt/ovis` from the release; build-time SHA-256 pins plus Ed25519 check of `ovis-server.json` against the key pinned in Ovis source |
| `image/ovis-entrypoint.sh` | Fails closed: refuses to start without a token of 24+ characters, a non-loopback `HOST`, or `OVIS_TELEMETRY` other than 0 |
| `image/smoke.sh` | podman pod validation (Herdr + Ovis, read-only home/workspace, no network variant, restart isolation) |
| `deploy/` | kustomize overlay on `../exp-002/deploy/base`; `deploy/diff-vs-base.sh` proves only the container and two emptyDirs are added |
| `harness/seal-ovis-token.sh` | Owner-run: random token, SealedSecret `herdr-ovis-token`, plaintext to a 0600 file outside the repo; also used for rotation |
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

## Security boundary: the token is an operator credential

**Holding the Ovis token, or a paired-device credential, gives effectively full trusted Herdr operator privilege.**
That is the same as RBAC `pods/exec` on the Herdr container. It is not a "view transcripts" or "chat only"
credential. Through the terminal input that Ovis exposes for every pane, a holder can:

- run any shell command as uid 1000 in the Herdr container;
- print a pane's environment, including the inherited `CLAUDE_CODE_OAUTH_TOKEN`;
- read or modify agent files and secrets on the home and workspace volumes;
- drive or impersonate any agent.

Ovis does not inherit the Claude credential, its mounts are read-only, and its environment is separate. Those
settings limit what the Ovis **process** holds if it is compromised by itself. They are **not an authorization
boundary** against a person with full PTY control.

Handle the token like an operator credential:
- give it only to people who are trusted Herdr operators;
- never paste it into an issue, chat, screenshot or agent session;
- rotate it on any suspected exposure.

The browser cookie *is* the raw token, kept for about a year (FIND-037). A lost phone or browser profile therefore
means a lost token.

## Token rotation (owner-run)

The first EXP-003 token was echoed into an agent transcript by a Playwright error. It was treated as exposed and was
rotated with this procedure on 2026-11-16 ([#22](https://github.com/jlaska/herdrnetes/issues/22)). Use the same
procedure after any suspected exposure. The procedure:

- uses a fresh token and a new SealedSecret, committed with your signed-commit workflow in the private GitOps
  repository;
- restarts **only the Ovis container**, never the Herdr pod.

Run every step yourself, in your own terminal, not from an agent session. Never print the token, put it in a command
line, paste it into GitHub, or screenshot it. The commands below print only status codes and hashes.

Notation:
- `k` is `kubectl --context <ctx> -n herdrnetes-exp`.
- `D` is `${XDG_DATA_HOME:-$HOME/.local/share}/exp003`.
- `<gitops>` is the experiment app's directory in the private GitOps repository.

1. **Record the baseline** so you can show afterwards that Herdr was untouched:
   - `CTX=<ctx> experiments/exp-003/harness/scenario.sh identity r1 pre-rotate`;
   - note `k get pod herdr-0 -o jsonpath='{.metadata.uid}'`.
2. **Check for paired devices.** A paired device holds its own credential, and that credential survives token
   rotation. Run `k exec herdr-0 -c ovis -- sh -c 'test -s /var/lib/ovis/state/devices.json && echo present || echo none'`.
   None were paired in EXP-003. If the answer is `present`, revoke those devices in Ovis Settings as well.
3. **Keep the old token for the negative test:** `mv "$D/ovis-token" "$D/ovis-token.old"`.
   `seal-ovis-token.sh` refuses to overwrite the file.
4. **Generate and seal a fresh token** over the existing file:
   `experiments/exp-003/harness/seal-ovis-token.sh <sealed-secrets-cert.pem> <gitops>/secrets/herdr-ovis-token.sealed.yaml`.
   The new plaintext goes only to `$D/ovis-token`, with mode 0600.
5. **Commit** in the GitOps repository:
   - `git diff --stat` must list **only** `herdr-ovis-token.sealed.yaml`;
   - make a signed commit and push.
6. **Let it sync, and confirm that nothing else changed:**
   - Argo CD should report a change to the SealedSecret only. The StatefulSet must not change: the pod template
     references the Secret by name and key, so it does not. The `herdr-0` pod UID must stay the same.
   - Confirm the controller updated the Secret by comparing hashes, without printing the token. Run
     `k get secret herdr-ovis-token -o jsonpath='{.data.OVIS_TOKEN}' | base64 -d | sha256sum` and
     `tr -d '\n' <"$D/ovis-token" | sha256sum`. The two hashes must match.
7. **Restart only the Ovis container.** Updating a Secret does **not** change the environment of a process that is
   already running. `OVIS_TOKEN` comes from a `secretKeyRef`, which the kubelet resolves when it creates the container.
   - Run `k exec herdr-0 -c ovis -- kill -TERM 1`, as in RESULTS-ovis M11.
   - Wait until the `ovis` container's restart count has increased and the container is ready. This takes about 2 s,
     or longer under backoff.
   - Do **not** use `kubectl rollout restart`, delete the pod, or edit the StatefulSet. Each of those replaces the
     Herdr pod and stops every agent.
   - Step 8 verifies that the new value reached the process. Do not presume it did.
8. **Verify that the new token works and the old one is rejected.**
   - Start the tunnel: `k port-forward pod/herdr-0 7317:7317 &`.
   - Build header files with the shell built-in `printf`, so the token never appears in a process list:
     ```bash
     umask 077
     printf 'Authorization: Bearer %s\n' "$(cat "$D/ovis-token")"     >"$D/h-new"
     printf 'Authorization: Bearer %s\n' "$(cat "$D/ovis-token.old")" >"$D/h-old"
     for h in new old; do curl -s -o /dev/null -w "$h %{http_code}\n" -H @"$D/h-$h" http://127.0.0.1:7317/api/session; done
     curl -s -o /dev/null -w 'none %{http_code}\n' http://127.0.0.1:7317/api/session
     rm -f "$D/h-new" "$D/h-old"
     ```
   - Expect `new 200`, `old 401`, and `none 401`. `429` (`too_many_attempts`) also counts as a rejection.
   - In each browser, the old cookie is now refused. Sign in again with the new token.
9. **Verify that Herdr was untouched:**
   - `scenario.sh identity r1 post-rotate`, then `scenario.sh identity-diff r1 pre-rotate post-rotate`, must exit 0;
   - the `herdr` container's restart count stays 0, and the pod UID is unchanged.
10. **Dispose of the old token:** `shred -u "$D/ovis-token.old"`. The value in the old transcript is now useless.
    Record in #22 that rotation is done. Give the date and the check results, never the token.

**If Ovis does not come back:** the entrypoint refuses a short token, for example. Herdr is unaffected. Revert the GitOps
commit and repeat step 7, or leave Ovis down. Losing Ovis does not affect agents.
