# EXP-004 results (run `m1`, mock/local, 2026-11-16)

Everything here is **synthetic and local**: generated secrets, disposable ed25519 keys, a mock issuer and a mock
Git host on `127.0.0.1`. Nothing touched GitHub, the cluster, the owner's agents, keys or `~/.gitconfig`. Mock
expiry and revocation show how the *design* behaves; they say nothing about GitHub's real behavior. Temp paths are
shown as `<T>`; fingerprints are elided.

Environment: Fedora workstation, git 2.56.0, OpenSSH 10.2p1, Python 3.13.16.

**Pinned image (run `m2`, 2026-11-17, owner-approved):** both matrices were also run inside the live Herdr image
`ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277` (git 2.47.3,
OpenSSH 10.0p2, Python 3.13.5, uid 1000) under local rootless Podman. Flags: `--network=none --read-only
--userns=keep-id`, tmpfs `/tmp`, disposable `HOME=/tmp/h`, and only `experiments/exp-004` mounted read-only. No host
credentials, sockets or cluster config were mounted. Outcomes were **identical** to the workstation run: T01–T12 all
pass (T10 LIMITATION, T07c/T11b NOTE), and S01–S11 have 0 FAIL (FIND-052).

## Authentication matrix (`tests/run-matrix.sh`, ~6 s, TTL 3 s)

Each run reproduced the same output. The issuer was restarted mid-run (T08c, T12).

| ID | Scenario | Result | Observed |
| --- | --- | --- | --- |
| T01 | Clone in-scope repo, read client | PASS | exit 0 |
| T02 | Fetch | PASS | exit 0 |
| T03 | Push `exp004/test`, write client | PASS | exit 0, branch in bare repo |
| T04 | Push with read client | PASS (rejected) | exit 128, host 403 |
| T04b | Read client *asks* for write (`EXP004_ACCESS=write`) | PASS (rejected) | issuer: "access write exceeds policy (read)" |
| T05 | Clone out-of-scope repo | PASS (rejected) | exit 128, issuer: "not in policy". No prompt |
| T06 | In-scope token replayed against another repo | PASS (rejected) | host 404 (repo hidden) |
| T07a | Expired token replayed | PASS (rejected) | host 401 "token expired" |
| T07b | Normal operation after expiry | PASS | new token minted per operation |
| T07c | Does Git call `erase` after a 401? | NOTE | yes, so the helper's best-effort `revoke_own` runs |
| T08a | `revoke_token`, then replay | PASS (rejected) | host 401 "token revoked" |
| T08b | `revoke_client`, then push | PASS (rejected) | issuer: "client revoked by administrator" |
| T08c | Client revocation survives an issuer restart | PASS (rejected) | first prototype **failed open** here; fixed (FIND-045) |
| T09 | Issuer stopped | PASS (fails closed) | exit 128 in 0.04 s, "issuer unavailable at <sock>", `quit=1`, no prompt |
| T10 | Agent B (same UID, separate HOME/env) reuses agent A's client file | **LIMITATION** | push succeeded; issuer log shows 1 uid across 4 pids (FIND-044) |
| T12 | Issuer restart | PASS | old token unknown → replay 401. 0 files containing a token in HOME |
| T11 | Leak scan for all 13 minted tokens (raw and base64) | PASS | none in HOME, worktrees, `.git/config`, remote URLs, issuer/host logs, results, default `GIT_TRACE=1 GIT_TRACE_CURL=1` trace, issuer/host `/proc/*/{cmdline,environ}` |
| T11b | Same trace with `GIT_TRACE_REDACT=0` | NOTE | token present as base64 `Authorization` header (trace deleted) |

Notes:

- Git called the helper `get` and then `store` after successful operations. `store` is ignored; nothing is cached.
- The `/proc` scan covered the issuer and host, not a helper caught mid-request. The helper never takes secrets in argv
  or environment (the client file path only).
- Not covered by the mock: TLS (the mock is plain HTTP), the rate of minting against GitHub, and transcripts of real
  agents (FIND-046).

## Signing matrix (`signing/run-signing.sh`, ~15 s)

Disposable keys only. The script unsets `SSH_AUTH_SOCK`/`GPG_AGENT_INFO` and runs its own `ssh-agent`s on private
sockets. Reproduced by the lead with identical outcomes.

| ID | Option | Scenario | Result | Observed |
| --- | --- | --- | --- | --- |
| S01 | B1 | Bot key file signs; `verify-commit` with allowed signers | PASS | `Good "git" signature for bot@example.invalid with ED25519 key SHA256:…` |
| S02 | B1 | Second same-UID process signs with the bot key file | **LIMITATION** | signature produced |
| S03 | — | allowed_signers maps the key to a different email than the committer | NOTE | `verify-commit` rc=0, `Good "git" signature for someone-else@example.invalid` (FIND-047) |
| S03b | — | Key absent from allowed_signers | NOTE | rc=1, `Good "git" signature with ED25519 key … No principal matched.` |
| S04 | A | Agent-held key, `user.signingkey` = public key only, private file deleted | PASS | good signature; only `.pub` on disk |
| S05 | A | Any process that can reach the agent socket | **LIMITATION** | signed namespaces `git` and `file`, no prompt |
| S06a | A | `ssh-add -c`, askpass denies | PASS (rejected) | `Couldn't sign message (signer): agent refused operation` → `fatal: failed to write commit object` |
| S06b | A | `ssh-add -c`, askpass approves | PASS | signs. Askpass runs on the **agent** side (headless with `SSH_ASKPASS_REQUIRE=force`) |
| S07a–c | A | Agent killed / no socket / `commit.gpgsign=true` plain commit | PASS (fails closed) | `error: No private key found for public key "<T>/hk.pub"` → no commit, HEAD unchanged |
| S08 | A | `ssh-add -t 3` | PASS | signs at t=0, fails after 4 s (same misleading message as S07) |
| S09a | C | Owner fetches 2 unsigned agent commits, `git rebase --exec 'git commit --amend --no-edit -S'` | PASS | good for owner; author = agent, committer = owner, hashes changed |
| S09b | C | Original agent commits | PASS (rejected) | unsigned, `verify-commit` fails |
| S10 | — | Commit body edited, `gpgsig` kept | PASS (rejected) | `Signature verification failed: incorrect signature` |
| S11a | A+relay | Git signing through the filtering relay (`--policy git-sign`) | PASS | relay: `type=13 key=SHA256:… namespace=git allow` |
| S11b | A+relay | `ssh-keygen -Y sign -n file` through relay | PASS (rejected) | relay: `namespace=file DENY` |
| S11c0 | control | Raw non-SSHSIG sign request through the *unfiltered* relay | PASS | reply type 14 (signed), so the filter is what blocks S11c |
| S11c | A+relay | Same raw (auth-style) request, filtered relay | PASS (rejected) | reply type 5, `not-sshsig DENY` |
| S11d/e | A+relay | `ssh-add -D` / add identity through relay | PASS (rejected) | "Failed to remove all identities." / "agent refused operation" |
| S11f | A+relay | Same relay carried over `kubectl exec` stdio | NOTE | **not built or tested** against the cluster |

Surprises recorded by the implementer and checked by the lead:

- A private key file next to the `.pub` defeats agent-only signing: `ssh-keygen -Y sign -f key.pub` falls back to it.
  Agent-held signing requires that no private file be reachable.
- Unix socket paths over ~107 bytes fail. Both harnesses put sockets in a short `mktemp -d` and remove it on exit.

## Not tested (blocked or out of scope)

| Case | Why | Gate |
| --- | --- | --- |
| Real installation tokens: clone/fetch/push, read-only push denial, other-repo denial, 1 h expiry, `DELETE /installation/token`, uninstall/remove-repo effect on live tokens, over-request status code, pusher attribution | Needs an owner-created App and test repos | G1–G3 |
| Ruleset: App cannot update `main`; "require signed commits" rejects unsigned agent pushes | Needs test repo | G4 |
| GitHub "Verified" for an SSH signing key, owner re-signed commit, App API-created (`createCommitOnBranch`) commit | Needs test repo / key | G5, G6, G2 |
| YubiKey touch through a forwarded/relayed agent; OpenPGP `S.gpg-agent.extra` forwarding | Real owner hardware; image has no gpg; not requested (FIND-041) | not requested |
| Anything in the live Herdr pod | Out of scope without review | — |

## GitHub adapter, offline (`tests/run-github-offline.sh`, run `m2`, 2026-11-17)

`issuer.py --backend github` against `tests/fake_github.py` on 127.0.0.1 with a synthetic RSA key. The fake checks the
JWT signature with `openssl` and emulates mint and `DELETE /installation/token`. **Its error codes and wording are
invented and are not evidence of GitHub's behavior.** All of G01–G19 pass.

| ID | Check | Observed |
| --- | --- | --- |
| G01/G01b | Helper mint for `acme/a` | Request body `repositories: ["a"]`, `permissions: {contents: read, metadata: read}`. Helper prints `password_expiry_utc` |
| G02 | App JWT | Verified by the fake. `exp − iat ≤ 600` |
| G03 | Read client asks for write | Refused locally; no request reached the API |
| G04/G05 | Repository outside the installation; ungranted `workflows` | API 422, surfaced sanitized: `github mint failed: HTTP 422 …`, `quit=1` |
| G06 | API returns a broader token than requested | Issuer refuses and DELETEs it |
| G07/G08/G15 | `erase` → revoke_own; `revoke_all`; `revoke_client` | Each DELETEs at the API (counts match). `revoke_client` also refuses new mints |
| G09/G19 | SIGTERM, including **mid-mint** | All outstanding tokens DELETEd before exit, `inflight_abandoned: 0` |
| G10 | API unreachable | `github unreachable: ConnectionRefusedError`, `quit=1`, fast |
| G11/G12 | Peer UID not in `client_uids` / `admin_uids` | Refused |
| G13/G14 | Leak scan / sanitizer | No token or `eyJ` JWT in issuer logs, HOME, outputs. `ghs_…` and long base64 redacted |
| G16/G16c | API answers with a 302 redirect | Issuer refuses, and the JWT is not re-sent. **Control:** a default urllib client follows the same redirect *with* its Authorization header |
| G17/G18 | `http://` API URL to a non-loopback host; policy access `"admin"` | Issuer refuses to start |

The lead's review of the first adapter found, and fixed:
- urllib followed redirects with the Authorization header (G16c shows this was a real risk);
- no https requirement;
- a shutdown race in which a mint that finished after revoke-on-exit left a live token;
- a helper timeout (3 s) shorter than the API timeout (10 s);
- an untracked token if a broad-token DELETE failed;
- the test-only token-recording hook active for the github backend;
- unvalidated policy access values.

All are covered by tests above except the helper timeout and the recording hook, which are now mock-only by
construction.

## Second review corrections (run `m3`, 2026-11-17)

The owner's review of `9aa6ef1` (PR #28) listed five blocking findings plus a long-token regression. The lead's review
of the corrections found four more (rows 6–9). All are offline: fake API, synthetic keys and 520-char synthetic
tokens. **These do not show GitHub's behavior.** Suites: `tests/test-install.sh` (I01–I09),
`tests/run-github-offline.sh` (G01–G41), `tests/run-matrix.sh` (T01–T12, unchanged except for state initialization).

| # | Finding | Correction | Tests |
| --- | --- | --- | --- |
| 1 | Install copied unreviewed code from the agent-writable checkout | `live/install-issuer.sh`, run as root from a fresh root-owned clone at the full 40-hex rev. It refuses on any dirty tracked file and requires the manifest to equal the committed one, and every file to equal its committed blob. It stages from `git show <rev>`, re-verifies the stage, installs, and verifies the installed files. As root, any non-root-owned or group/world-writable source path or dest ancestor is refused. Rollback on failure | I01–I09 (root-only ownership checks **untested offline**) |
| 2 | `revoke_client` raced an in-flight mint | Track and check (closing / state-broken / client revoked / broader) run in one critical section. `revoke_client` adds, persists and snapshots in one critical section. A late token is DELETEd and never delivered | G20 |
| 3 | Fixed 15 s shutdown wait < mint time | `--drain-seconds` (45) must be ≥ openssl 10 s + 2 × `--github-timeout`, enforced at start (G41). `TimeoutStopSec=120`. DELETEs in parallel. Exit 0 only if drained and all revoked, else exit 2 + CRITICAL + fallback | G21 (20 s mint), G22, G29 |
| 4 | Missing state file = empty revocation set | State must pre-exist as a regular file owned by the issuer, not group/world-writable, holding a JSON list of strings; otherwise the issuer refuses to start. Writes are atomic with fsync | G23–G27 |
| 5 | Revocation failure looked like success | `ok:false` + `fallback` in replies. `issuer-ctl` exits 1 with `REVOCATION INCOMPLETE`. Shutdown exits 2. A broad token reports "DELETEd at GitHub" vs "DELETE FAILED…" | G28–G31 |
| 6 | (lead) State-save failure left minting on | `state_broken`: every mint refused until the owner fixes the state | G39 |
| 7 | (lead) Racing kills DELETEd twice; the second 401 counted as failure | One claim per token. A 401 on DELETE counts as already unusable (DELETE authenticates with the token itself) | G38 |
| 8 | (lead) Serial DELETEs could exceed the stop budget | Parallel DELETEs (16 workers) | G09, G29 |
| 9 | (lead) Token minted but the reply never delivered (helper timeout or hang-up) | The issuer kills it. The helper timeout is raised to 45 s, above the worst mint path | G40 |
| L | ~520-char stateless tokens | Helper, real `git ls-remote`/`clone` through a fake Git smart-HTTP route, erase/revoke and replay → 401, `revoke_token` via stdin, `sanitize` and `live/redact.sed`, leak scan for any 12-char substring | G32–G37b |

**Remaining limitations (stated, not fixed):**
- G22: a token GitHub issues after the issuer has exited or abandoned the request cannot be revoked by the issuer.
- SIGKILL, a crash or power loss revoke nothing.
- The fake's acceptance of the revoked-token replay is not evidence of GitHub's behavior.
- The client side is still the owner's UID (FIND-044), accepted by the owner only while all agents are stopped.
