# EXP-004 results (run `m1`, mock/local, 2026-11-16)

Everything here is **synthetic and local**: generated secrets, disposable ed25519 keys, a mock issuer and a mock
Git host on `127.0.0.1`. Nothing touched GitHub, the cluster, the owner's agents, keys or `~/.gitconfig`. Mock
expiry and revocation show how the *design* behaves; they say nothing about GitHub's real behavior. Temp paths are
shown as `<T>`; fingerprints are elided.

Environment: Fedora workstation, git 2.56.0, OpenSSH 10.2p1, Python 3.13.16. The live Herdr image has git 2.47.3
and OpenSSH 10.0p2 (FIND-039). The matrix was **not** run inside that image: a local `podman` run of the pinned
image was not permitted in this session. Compatibility with 2.47.3 is inferred from Git docs (`password_expiry_utc`
≥ 2.41, SSH signing ≥ 2.34), not observed.

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
| Helper in the pinned image (git 2.47.3) | Local pinned-image run not permitted this session | owner |
| Anything in the live Herdr pod | Out of scope without review | — |
