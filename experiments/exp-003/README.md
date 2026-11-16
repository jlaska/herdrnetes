# EXP-003 harness: remote clients against the EXP-002 Herdr pod

Client-side tests of access path B ([`docs/experiments/03-remote-access.md`](../../docs/experiments/03-remote-access.md)
sections 3 and 4): a local `herdr client` talks through a local Unix socket and
`kubectl exec -i herdr-0 -- herdr remote-client-bridge` to the pod's UI client socket. No change to the pod, image or
NetworkPolicy. Reuses the EXP-002 `lib.sh` (target checks, `pod_facts`, `require_ack`). Raw evidence goes to
`$EXP_EVIDENCE` (default `$XDG_DATA_HOME/exp003`, refused if inside this repository).

| Path | Purpose |
| --- | --- |
| `harness/lib.sh` | Sources the EXP-002 lib; adds `identity <label>` and `identity_diff <a> <b>` |
| `harness/identity.py` | `build` (raw capture to `identity.json`) and `diff` (UNCHANGED/CHANGED, non-zero if the server or a pane shell was replaced) |
| `harness/bridge.py` | Local socket listener that spawns one `remote-client-bridge` per connection and pumps bytes |
| `harness/client.sh` | Runs `herdr client` against the bridge socket with the `herdr --remote` environment |
| `harness/scenario.sh` | `setup`, `identity`, `identity-diff`, `cleanup` for one disposable `exp003-<run>` workspace |

## Run

```bash
export CTX=<kube-context>
S=$XDG_RUNTIME_DIR/h3.sock                                 # keep it short: sun_path is about 107 bytes
harness/scenario.sh setup r1                               # workspace exp003-r1, sleep + ticker panes, baseline identity
harness/bridge.py "$S" &                                   # refuses unless the pod's server is running and compatible
harness/client.sh "$S"                                     # in a real terminal; HERDR_BIN=/path/to/herdr for skew tests
# ... kill the client, kill the bridge child, stop the bridge for N seconds ...
harness/scenario.sh identity r1 after-kill
harness/scenario.sh identity-diff r1 baseline after-kill   # non-zero = server/pane shell replaced
harness/scenario.sh cleanup r1                             # dry run; add --yes (+ EXP_ACK) to close it
```

`identity` records pod UID, image ID, restart count, server PID and start time (`/proc/<pid>/stat`), per-pane shell PID
and foreground command lines, agent metadata (session references hashed, never printed), counts, and the client version.

## Safety

- `remote-client-bridge` **starts a server** if none is listening. `bridge.py` therefore checks
  `herdr status server --json` (`running` and `endpoint_compatible`) before listening and before every connection.
  The check is not atomic. If the server disappears between the check and the exec, the bridge would start a second,
  unsupervised server. No second server was started in the observed runs; this is an observation, not a guarantee.
- Nothing here stops the server, deletes or restarts the pod, or changes the image. `cleanup` closes only the workspace
  labelled `exp003-<run>` and removes `/workspace/exp003/<run>` when it carries this run's marker; it needs `EXP_ACK`.
- Do not use `herdr --remote` or saved machines against this server (FIND-026). Do not run bare `herdr` in the pod while
  the server is down (FIND-027).
- The bridge socket is `0600`, but anyone who can use it controls every pane (FIND-025). The bridge removes it on exit.
  Evidence may contain screen content: keep it private.
- Run `scenario.sh identity` (which calls `check_target`) before starting the bridge; `bridge.py` itself trusts `CTX`.
