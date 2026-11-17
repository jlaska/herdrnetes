# EXP-004: Git credentials and signing

**Status:** Milestones 1–4 executed **mock/local** on 2026-11-16 (run `m1`). On 2026-11-17 (run `m2`), both
matrices were re-run in the pinned Herdr image under local Podman (FIND-052). The live GitHub adapter was implemented
and tested **offline** against a fake API (FIND-053). The owner approved G1–G4 and G6 with conditions and declined G5
([decisions](https://github.com/jlaska/herdrnetes/issues/5)). The owner's first security review of the adapter (`9aa6ef1`)
did **not** clear it for live credentials and listed five blocking findings. Those are now corrected and regression-tested
offline (FIND-054). **Not yet run:** every live GitHub test. It is waiting on a second security review and on
owner-performed key steps, with all autonomous agents stopped
([`live/RUNBOOK.md`](../../experiments/exp-004/live/RUNBOOK.md)). Nothing in the cluster, the running Herdr
pod, GitOps, SealedSecrets, or the owner's GitHub/SSH/GPG/YubiKey identities was changed. Proposed for review; no ADR
changes made. Tracking issue: [#5](https://github.com/jlaska/herdrnetes/issues/5). Builds on
[EXP-003](03-remote-access.md) (FIND-023–038).

Investigate repository-scoped, short-lived GitHub App credentials for clone/fetch/push; commit signing as an
independent identity decision; and how to avoid touching a YubiKey physically connected to the Herdr host. Compare
attack surface and refresh/revocation behavior. Never commit keys/tokens or expose secrets in issue evidence.

Evidence types: **[observed]** = measured here (locally unless marked *pod*), **[mock]** = observed against the mock
issuer/host, so it shows the design's behavior but not GitHub's, **[docs]** = current GitHub/Git/OpenSSH documentation,
**[inference]** = our reasoning, not yet tested. Harness and per-test results:
[`experiments/exp-004/`](../../experiments/exp-004/), [`RESULTS.md`](../../experiments/exp-004/RESULTS.md).

**Requirements:** REQ-008. **Related:** EXP-006 ([#7](https://github.com/jlaska/herdrnetes/issues/7)), native SSH
access ([#25](https://github.com/jlaska/herdrnetes/issues/25)).

**Orchestration:** Opus lead (threat model, security decisions, review, synthesis). Sonnet: GitHub-auth and signing
research, both prototypes. Haiku: read-only inventory. Per-agent model selection was available and used. Sub-agents
received only synthetic secrets. The lead re-ran both matrices and reviewed the security-relevant code, which found and
fixed one fail-open defect (FIND-045).

## 1. Baseline (read-only)

| Item | Value |
| --- | --- |
| Pod | `herdr-0` (post-EXP-003 pod). `herdr` restarts 0. `ovis` restarts 4, all `Completed/0`, consistent with EXP-003 token rotation |
| Image | `herdrnetes-herdr:exp002-h095-c311@sha256:c5a235ae…d277` (unchanged): git 2.47.3, OpenSSH 10.0p2 (`ssh-keygen -Y`, `ssh-agent`), python3. **No** gpg, gh, curl, socat, nc, sshd, libsecret |
| Git state in pod | No global/system gitconfig, `~/.git-credentials`, `~/.ssh`, `~/.config/gh`, `~/.gnupg`. 0 repositories in `/workspace`, 0 token patterns in shell history, no ServiceAccount token |
| Server environment (names) | 18 variables. The only secret-like one is `CLAUDE_CODE_OAUTH_TOKEN` (EXP-002) |
| Workstation | git 2.56.0, OpenSSH 10.2p1, GnuPG 2.4.9. SSH agent is gpg-agent with hardware-backed keys. Commits are signed with OpenPGP. Values were not read |

## 2. Identity model

Five separate things, which the design must not conflate:

| Concept | Established by | Strength |
| --- | --- | --- |
| Author / committer | `user.name`/`user.email` of the process | **None.** Any process can claim anyone |
| Push identity | Credential presented to GitHub (App token → `<app>[bot]`, to verify live) | Authenticated by GitHub |
| Signer | Whoever can invoke the private key; mapped to a name by allowed signers or GitHub's key↔account binding | Only as strong as key custody (FIND-047, 048, 051) |
| Branch/permission policy | GitHub permissions, rulesets | Enforced server-side, independent of the client |
| Authorization | A human reviewing and approving | Not implied by any token or signature |

| Workflow | Push identity | Signing | Human |
| --- | --- | --- | --- |
| Human-interactive | Owner, from the **workstation** | Owner's YubiKey, **workstation only** (C) | Yes |
| Unattended agent | App installation token: one repo, `contents:read` (or `write` to agent branches), ≤1 h | Unsigned and reviewed, or GitHub-signed API commits (B2, untested). **Never** the owner's key | No |

## 3. Threat model (shared trusted pod)

- **One UID, one home, one workspace.** Anything one pane can reach, every pane and agent can reach: files, sockets,
  helper caches, signing agents, environment. Per-agent env/`.gitconfig` is not a boundary (FIND-044, 051).
- **Root credential custody.** The App private key never enters the image, home/workspace PVC, server environment, or
  a Secret mounted into the Herdr pod. A separately controlled issuer holds it.
- **Token confidentiality against agents is not achievable.** An agent can run `git credential fill` or disable trace
  redaction (FIND-046). The controls that remain are **scope, lifetime, revocation and audit**, not secrecy.
- **Leak channels checked:** remote URLs, `.git/config`, argv/environ, credential caches (`credential-cache` would put
  a socket in the shared home), traces, history, restart persistence. Agent transcripts: not tested (FIND-046).
- **Signing.** Any key file or agent socket in the pod is usable by every agent. A valid signature proves which key
  signed, not which agent, and not that a human approved.

## 4. Discovery findings (Milestone 1)

- **FIND-039 — The pod starts Git-credential-free, and its tools support the candidate mechanisms.** [observed, pod]
  [docs] Git 2.47.3 supports SSH signing (≥2.34) and the credential-helper `password_expiry_utc` attribute (≥2.41).
  OpenSSH 10.0 supports `-Y sign/verify`, sk keys and agent confirmation. The image has no gpg, so relaying the owner's
  current OpenPGP signer would need an image change. (REQ-008)
- **FIND-040 — Any Git credential placed in the Herdr server environment would reach every pane, as
  `CLAUDE_CODE_OAUTH_TOKEN` already does.** [observed, pod; extends EXP-002/003] A `GH_TOKEN` or mounted credential
  would behave the same way. Git credentials therefore stay out of the server environment and pod spec and are fetched
  per operation. (REQ-008)
- **FIND-041 — `kubectl exec` carries no SSH or GPG agent, and the owner's workstation agent is the YubiKey-backed
  gpg-agent.** [observed, docs: OpenSSH `PROTOCOL.agent`] Relaying that agent would expose the owner's SSH
  **authentication** keys as well as signing, to every same-UID process, for the life of the session. OpenSSH
  destination constraints (`ssh-add -h`) apply to authentication, not signatures. The agent protocol has no per-key
  namespace or "sign-only" restriction. **Not done; rejected for the shared pod.** (REQ-008)

## 5. Scoped GitHub authentication (Milestones 2–3)

### Options [docs, fetched 2026-11-16; rows marked * are general knowledge, not re-verified]

| Option | Scope | Lifetime | Revocation | Push attributed to | Root secret | Unattended-agent fit |
| --- | --- | --- | --- | --- | --- | --- |
| **App installation token** | Selected repos; per-token down-scope via `repositories` + `permissions` (cannot exceed the installation) | 1 h; mint anew | `DELETE /installation/token` (204); uninstall; delete App key | `<app>[bot]` (verify live) | App private key (max 25 per App, no expiry), held by the issuer | **Best**, if the key stays outside the pod |
| Deploy key* | One repo, read or read/write | No expiry | Delete key | The key | SSH private key, which would sit in the agent's reach | Long-lived. Acceptable only for read-only bootstrap |
| Fine-grained PAT* | Selected repos | Owner-set maximum | Owner deletes it | **The owner** | The token itself | Poor: impersonates the human |
| Classic PAT* | Broad | Optional | Owner deletes it | The owner | The token | Reject |
| `GITHUB_TOKEN` / Actions OIDC* | Actions only | Job | Automatic | `github-actions[bot]` | — | Not applicable outside Actions |

Docs facts the live tests must confirm: the JWT is RS256 with `exp` ≤10 min. Contents read suffices for fetch,
Contents write for push. Workflows is separate (needed to change `.github/workflows`). Since 2026-04-27 tokens may use
a new stateless `ghs_<appid>_<jwt>` format, so length must not be assumed. Rulesets can restrict updates to a branch
pattern with the App excluded from bypass, and "require signed commits" rejects unsigned pushes. **Not documented in the
pages fetched:** the status code for over-requesting permissions, revocation latency on Git HTTPS, and whether
uninstalling or removing a repo invalidates outstanding tokens.

### Prototype

```
git (pane) ── get ──> git-credential-exp004 ── Unix socket 0600 ──> issuer (policy, root key, revocation state, audit)
    │                  client file 0600, no cache, quit=1 on failure        │ mock: HMAC token   real: JWT → POST …/access_tokens
    └── HTTPS Basic x-access-token:<token> ──> Git host (mock: git http-backend + introspect; real: GitHub)
```

The remote URL is unchanged. `credential.helper=` resets inherited helpers, `credential.useHttpPath=true` gives the
helper the repository, and `GIT_TERMINAL_PROMPT=0` plus `quit=1` prevent prompting. The `--backend github` path is a
documented stub until G2/G3 are approved.

### Findings

- **FIND-042 — An on-demand credential helper gives normal Git short-lived, repository-scoped credentials with no
  token on disk or in the remote URL, and fails closed.** [mock] Clone, fetch and push worked with unmodified
  `https://` remotes. A new token is minted per operation (T07b). With the issuer down, Git exits 128 in 0.04 s,
  prints "issuer unavailable", and neither prompts nor falls back (T09). Git calls `store` after success, which the
  helper ignores, and `erase` after a 401, which the helper uses for best-effort revocation (T07c). (REQ-008)
- **FIND-043 — Scope is enforced twice: the issuer refuses to mint, and the host refuses the token.** [mock] An
  out-of-scope repository is refused at mint time (T05). An in-scope token replayed elsewhere gets 404 (T06). A read
  token pushing gets 403 (T04). The client's requested access level is only a request (T04b). On GitHub the second
  layer is GitHub itself plus rulesets; only the first layer is ours. (REQ-008)
- **FIND-044 — In the shared pod the issuer can authenticate the *workload*, not the *agent*.** [mock] A second
  process with its own HOME and environment, but the same UID, read agent A's client file and pushed. The issuer saw one
  UID across all callers (`SO_PEERCRED`, T10). Per-agent authorization needs an independently authenticated execution
  identity (EXP-006, [#7](https://github.com/jlaska/herdrnetes/issues/7)). Until then, issuer policy should be written
  per pod: the union of what any agent there may do. (REQ-008, REQ-011)
- **FIND-045 — Revocation state must be durable and live with the issuer, and an issuer restart does not revoke real
  tokens.** [mock, inference] The first prototype kept client revocation in memory, so an issuer restart silently
  reinstated a revoked client. That is fail-open; it was fixed, and T08c now proves revocation survives a restart. The
  mock's tokens vanish on restart (T12). GitHub's do **not**: a minted installation token stays valid for its hour
  regardless of the issuer. Emergency revocation is therefore `DELETE /installation/token` for known tokens, then
  removing the repo from the installation or suspending/uninstalling the App (effect on live tokens untested). (REQ-008)
- **FIND-046 — Normal Git paths do not leak the token, but any agent can deliberately expose it.** [mock] No minted
  token appeared in HOME, worktrees, `.git/config`, remote URLs, logs, `/proc` of the issuer/host, or a default
  `GIT_TRACE_CURL` trace (T11). With `GIT_TRACE_REDACT=0` the token appears base64-encoded in the trace (T11b). Agent
  transcripts were not tested, but an agent that runs `git credential fill` would record the token in its transcript on
  the home PVC, which Ovis also reads (FIND-028). Short lifetime and narrow scope are the real controls. (REQ-008)
- **FIND-052 — The helper and signing behavior are unchanged on the pod's toolchain.** [observed, pinned image under
  local Podman, `--network=none`, no host credentials] Both matrices gave identical outcomes with git 2.47.3,
  OpenSSH 10.0p2 and Python 3.13.5. This confirms FIND-039's version inference. It does not test the live pod. (REQ-008)
- **FIND-053 — An issuer holding the App key needs explicit transport and lifecycle guards; the first adapter lacked
  them.** [observed offline, fake API] The lead's review found three gaps. (1) Python's urllib follows redirects and
  re-sends the `Authorization` header: a control test showed the bearer arriving at the redirect target. (2) Nothing
  required https. (3) A mint finishing after revoke-on-exit left a token alive for up to 1 h. The fixed adapter refuses
  redirects and non-https API URLs, tracks every minted token before any further check, and on SIGTERM stops new mints,
  drains in-flight ones, then DELETEs all (G09, G16, G16c, G17, G19). The separate-identity deployment
  (`live/RUNBOOK.md`) keeps the key and the code that reads it out of the agent's UID. That covers the root secret
  only; minted tokens still reach the client UID (FIND-044). (REQ-008)
- **FIND-054 — Revocation is only as strong as its concurrency, persistence and failure reporting.** [observed
  offline, fake API; owner security review of `9aa6ef1`] The owner's review found five ways the adapter could leave a
  token live, or a client re-enabled, while appearing safe.
  1. Code was installed from an agent-writable checkout.
  2. A mint finishing after `revoke_client` was delivered.
  3. Shutdown waited a fixed 15 s, shorter than one mint can take.
  4. A missing state file meant "nothing revoked".
  5. Failed DELETEs still produced exit 0.

  The lead's second review found four more:
  6. A state-save failure left minting on.
  7. Racing kills DELETEd twice and reported false failures.
  8. Serial DELETEs could overrun the stop budget.
  9. A token whose reply the client never received stayed live.

  Corrections:
  - Install only from a root-owned fresh clone, with triple verification (I01–I09).
  - Track and check under one lock, and kill late tokens (G20).
  - A drain bounded by a startup-enforced mint budget, a stop budget of 120 s, and parallel DELETEs (G21, G41).
  - State must pre-exist and validate. A state that cannot be persisted stops all minting (G23–G27, G39).
  - `ok:false`, a non-zero exit, `REVOCATION INCOMPLETE`/`CRITICAL` with a written fallback, and an accurate
    DELETE-failed message (G28–G31).
  - One claim per token (G38); undelivered tokens are killed (G40).

  The 520-character stateless token format passes the helper, real Git, revocation and redaction (G32–G37).
  **Limitations that remain:**
  - A token GitHub issues after the issuer has exited or given up waiting cannot be revoked by it (G22).
  - SIGKILL, a crash or power loss revoke nothing.

  In both cases the only control is uninstalling the App and waiting out the ≤1 h expiry. (REQ-008)
- **FIND-055 — An agent on the owner's workstation produced commits signed with the owner's hardware-backed key.**
  [observed] The three EXP-004 commits on PR #28 before the corrections, and this correction commit, were created by the agent
  session. `git log --format=%G?` shows `G`, a good signature by the owner's identity, because `commit.gpgsign=true` is
  global. No signing prompt was visible to the agent session; whether a card touch occurred cannot be observed from it.
  This is the workstation form of FIND-048: a signature by the owner's key shows that the owner's signer was reachable,
  not that the owner reviewed the commit. It reinforces recommendation 3. Owner-reviewed signing must be a deliberate
  owner action, and an agent session should run with signing disabled or a separate key. The owner explicitly requested
  that this correction commit be signed; nothing in the owner's configuration was changed. (REQ-008)

## 6. Commit signing (Milestone 4)

Options: **A** human signer reached remotely (agent forwarding or relay); **A2/C** the owner signs on the workstation
after review; **B1** bot key file in the pod; **B2** commits created through the GitHub API by the App (GitHub-signed);
**B3** automation key held by an external signer; **B4** gitsign (Sigstore).

- **FIND-047 — A good SSH signature identifies a key, not the committer.** [observed] `verify-commit` returned 0 and
  `Good "git" signature for someone-else@example.invalid` for a commit whose committer was a different address. Git
  does not compare the allowed-signers principal with the author or committer (S03). Identity binding lives entirely in
  the allowed-signers file locally, and in GitHub's key↔account↔email rules remotely (untested). (REQ-008)
- **FIND-048 — A signing agent socket is a signing oracle for every process that can reach it; confirmation, lifetime
  and absence fail closed.** [observed] Any process with the socket signed `git` and `file` namespaces without prompting
  (S05). `ssh-add -c` worked headlessly: askpass runs on the agent's side, and a denial aborted the commit (S06).
  `ssh-add -t` expired the key (S08). A dead or missing agent aborted the commit even with `commit.gpgsign=true`, so no
  unsigned commit was silently created (S07). The error in both cases is the misleading "No private key found for
  public key". A private key file next to the `.pub` bypasses the agent entirely. (REQ-008)
- **FIND-049 — A small filtering relay can add the policy the agent protocol lacks.** [observed] Placed in front of an
  agent, it allowed only list-identities and `SSHSIG` sign requests with namespace `git`. It refused `-n file`,
  auth-style raw signatures, and key add/remove (S11). It cannot tell *which* commit it signs, so it does not replace
  confirmation or touch. The same relay over `kubectl exec` stdio was **not built or tested**. (REQ-008)
- **FIND-050 — Owner-reviewed re-signing works with plain Git and keeps the key off the cluster.** [observed, disposable
  keys] The owner fetched two unsigned agent commits and ran `git rebase --exec 'git commit --amend --no-edit -S' <base>`.
  The result verified for the owner, author stayed the agent, committer became the owner, and hashes changed (S09).
  Original agent commits remain unsigned and fail verification. With the owner's real YubiKey this would be one touch
  per commit (by card touch policy), on the workstation only. (REQ-008)
- **FIND-051 — A bot signing key in the shared home proves only "something in this pod signed".** [observed] A second
  same-UID process signed with the bot key file (S02). Bot signatures add no assurance over the App push identity, plus a
  long-lived key to rotate. Not recommended for the MVP. (REQ-008)

| Option | Key custody | Unattended | Human presence | GitHub Verified | Who in the pod can invoke it | Revocation | Tested |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A: human key via forwarded/relayed agent | Workstation hardware | No | Session + touch/confirm per signature | Yes, if the key is a signing key and email matches (untested) | Every process, while connected (S05). Touch/confirm limits it to visible events | Remove key; past verifications persist [docs] | Locally with a disposable key (S04–S08, S11) |
| **C: owner re-signs on workstation** | Workstation hardware | No | Per batch | Yes, as owner (untested, G6) | Nobody | Same as A | **Locally** (S09) |
| B1: bot key file | Shared home PVC | Yes | None | Only via a user account key | Every process (S02) | Rotate key | Locally (S01–S02) |
| B2: App API-created commits | GitHub | Yes | None | Docs: verified when authenticated as the App with no custom author/committer | Anyone holding the token | Token expiry/revoke | **Not tested** (G2) |
| B3: external signer (machine user key) | Separate service | Yes | None | Via machine-user account | Anyone reaching the signer socket, subject to policy | At the signer | Not tested. A relay (S11) is the policy core |
| B4: gitsign | Keyless, OIDC | Needs an OIDC identity | — | Not shown Verified by GitHub (not verified here) | Whoever holds the OIDC token | Short-lived cert | Not tested |

## 7. Integrated workflows (Milestone 5)

| Workflow | Actor and permissions | Credential | Signer | Result |
| --- | --- | --- | --- | --- |
| A Read-only agent | Client with `read` on one repo | Per-op token, mock TTL | None | **[mock] Works:** clone/fetch ok, push 403, other repo refused (T01–T06) |
| B Development agent | Client with `write` on one repo | Per-op token | None (unsigned, for review) | **[mock] Works:** push to `exp004/test` (T03). Branch restriction needs a GitHub ruleset: **blocked (G4)** |
| C Human-reviewed signed contribution | Agent prepares; owner reviews | Owner's own Git credential on the workstation | Owner key, workstation | **[observed locally, disposable keys] Works** (S09). Real YubiKey + GitHub Verified: **blocked (G6)** |
| D Failure | Any | Expired/revoked token, issuer down, signer gone | Any | **[mock/observed] Fails closed:** 401/refusal (T07–T09), no unsigned commit (S07). No privilege escalation was observed |

Every workflow shares FIND-044: within the pod, the credential belongs to the pod, not to an agent.

## 8. Recommendation for the trusted MVP (proposal, not an accepted decision)

1. **Unattended agents:** a GitHub App with Contents read/write and Metadata, installed only on selected repositories.
   Tokens are down-scoped per request to one repository and the minimum permission, minted on demand by an issuer
   **outside** the Herdr pod and its PVCs, through a no-cache, fail-closed credential helper. Agents push only to
   non-protected branches (a ruleset on `main` with no App bypass), and humans merge through PRs.
2. **Agent commits are unsigned** (or GitHub-signed through the API, if B2 passes live tests). The App push identity
   plus PR review is the attribution and authorization story. No bot key in the shared home.
3. **Human-attributed commits are signed on the workstation (C)**, with the YubiKey never leaving it and never relayed
   into the shared pod. This satisfies REQ-008 without a YubiKey on the Herdr host.
4. **Remote human signing (A) is deferred** until there is an owner-supervised session over the #25 path, a
   **dedicated signing-only key** (not the auth keys), per-signature touch or confirmation, and a namespace-filtering
   relay. Even then, every agent in the pod can request signatures while the session is up.
5. **Per-agent credentials are deferred to EXP-006.** In the shared pod, write issuer policy per pod.

## 9. Credential cleanup and revocation procedure (for the live tests)

1. Revoke each token the issuer minted (`DELETE /installation/token`) and stop the issuer.
2. Remove the test repos from the installation, uninstall the App, then delete the App (this invalidates its keys).
3. Delete the private key file from the workstation. Confirm none was ever copied to the pod (FIND-039 baseline
   recheck).
4. Remove any disposable signing key from the owner's account (G5) and delete the test repositories.
5. Re-run the pod baseline (section 1) to confirm the pod is unchanged.

## 10. Traceability

| Requirement | Findings | Status |
| --- | --- | --- |
| REQ-008 Git access and commit signing without a YubiKey on the Herdr host | FIND-039–055 | **Partly met (mock/local).** Design shown: scoped short-lived credentials without a root secret in the pod (FIND-042–045), and human signing kept on the workstation (FIND-050). **Not yet shown against GitHub** (G1–G6). Per-agent isolation **not achievable** in the shared pod (FIND-044, 048, 051) |
| REQ-011 Agent isolation (future) | FIND-044, 051 | Input to EXP-006: per-agent Git authorization depends on per-agent execution identity |
| REQ-007 Remote access | FIND-041 | `kubectl exec` carries no agent. Remote signing depends on #25 |

## 11. Follow-ups

| Item | Findings | Where |
| --- | --- | --- |
| Live GitHub App and test-repo matrix (G1–G6) | FIND-042–046, 050 | [#5](https://github.com/jlaska/herdrnetes/issues/5), pending owner approval |
| Where the issuer runs for the cluster (separate pod and identity, egress path from Herdr, key custody) | FIND-040, 044, 045 | [#26](https://github.com/jlaska/herdrnetes/issues/26) |
| Credentials in agent transcripts and Ovis-visible history | FIND-046 | [#27](https://github.com/jlaska/herdrnetes/issues/27) |
| Per-agent Git authorization | FIND-044, 051 | [#7](https://github.com/jlaska/herdrnetes/issues/7) |
| Owner-supervised remote signing over native SSH | FIND-041, 048, 049 | [#25](https://github.com/jlaska/herdrnetes/issues/25) |
