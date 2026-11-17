# EXP-004: on-demand, repository-scoped Git credentials (credential-free prototype)

Purpose: show that Git in a trusted Herdr pane can obtain a short-lived, repository-scoped HTTPS
token per operation from a separate issuer, so the root secret is never in the pane's HOME, and
that a GitHub-like host enforces scope, permission, expiry and revocation. Everything is synthetic:
secrets are generated at test time, no real GitHub, SSH, kubectl or `~/.gitconfig` is touched.

```
 pane (Git) --get--> git-credential-exp004 --Unix socket 0600--> issuer.py (policy, root key, admin secret)
     |                  client id+secret (0600 file)                 ^ introspect (admin)
     +--- HTTP Basic x-access-token:<token> --> mock_githost.py -----+
                                                  `git http-backend` --> bare repos
```

| File | Role |
| --- | --- |
| `harness/issuer.py` | Mints `ghs_mock_*` tokens per policy. Tokens in memory only; client revocations persisted in `--state` (T08c). Ops: token, revoke_own, revoke_token, revoke_client, reinstate_client, recover_state, introspect. A reinstatement takes effect only after the state file is durably committed; a failed save leaves the client revoked, refuses all mints, and needs `recover_state` (inspect the file before any restart). `--backend github` is implemented (App JWT signed by `openssl`, installation token per request, revoke via `DELETE /installation/token`). Each token is `active`, `revoking` (one thread owns the DELETE; other revokers wait for its real outcome, bounded by `--github-timeout` + 5 s), `revoked` or `failed`. `revoke_all`/`revoke_client`/shutdown report `revoked`, `failed` and `unresolved` (DELETE still pending at the deadline) and are `ok` only if both are 0; SIGTERM exits 0 only after a final scan finds no unexpired unrevoked token |
| `harness/mock_githost.py` | Smart-HTTP host: 401 bad/expired/revoked, 404 other repo, 403 read token pushing |
| `harness/git-credential-exp004` | Credential helper: `get` mints, `store` ignored, `erase` revokes (best effort); `quit=1` on failure |
| `harness/issuer-ctl.py` | Admin CLI: revoke_all, revoke_client, reinstate_client, revoke_token (token on stdin). Exits 1 with `REVOCATION INCOMPLETE` if any DELETE failed |
| `tests/fake_github.py` | Offline fake of the GitHub App endpoints (JWT verified with openssl), plus a Git smart-HTTP route, `--delay`, `--fail-delete`, `--token-len`, `--misbehave`, `--delete-delay`, runtime `/__fake/ctl` (fail_delete, delete_delay, delete_trickle). NOT evidence of real GitHub behavior |
| `tests/run-github-offline.sh` | Offline tests G01–G67 of `--backend github` against the fake (127.0.0.1 only, synthetic RSA key, 520-char tokens) |
| `tests/test_issuer_state.py` | Deterministic unit tests of the issuer's token and client state (fake GitHub client with `threading.Event` gates; classes RevocationAccounting, LeadReview, ReinstatePersistence). Run by G42u/G60u |
| `tests/run-matrix.sh` | Self-contained matrix T01-T12; results in `$T/results.tsv` |
| `tests/test-install.sh` | Offline tests I01–I09 of `live/install-issuer.sh` against a throwaway git repo |
| `live/` | Owner-run live materials: `RUNBOOK.md`, `install-issuer.sh` + `MANIFEST.sha256` (verified root install), `issuer-start.sh` (hardened systemd unit), `policy.template.json`, `run-live.sh` (L00–L17), `redact.sed` |

## Run

    tests/run-matrix.sh          # EXP004_TMP=<dir>, EXP004_KEEP=1, EXP004_TTL=<s> (default 3)

Needs python3 (stdlib only) and git. Exit status is non-zero if any test other than
LIMITATION/NOTE fails. The temp dir must be outside the repository.

## Safety notes

- Synthetic secrets only; the mock host speaks plain HTTP on 127.0.0.1, not HTTPS. A real
  deployment needs TLS so the Basic credential is not exposed on the wire.
- Same-UID limitation (T10): any process running as the pane's UID can read the client file and
  call the issuer. The helper keeps the *root* secret out of HOME and makes grants short-lived,
  scoped and revocable; it does not isolate agents from each other. The issuer sees one UID.
- `EXP004_ACCESS=write` is a request, not a control; the issuer policy decides (T04b).
- `GIT_TRACE_REDACT=0` with curl tracing leaks the token (T11b, NOTE).

## Mapping to GitHub

| Mock | GitHub |
| --- | --- |
| `ghs_mock_*` from `issuer.py` | Installation token from `POST /app/installations/{id}/access_tokens` with `repositories` and `permissions` (see `GitHub.mint()`) |
| HMAC root key file | GitHub App private key (RS256 JWT) |
| host returns 404 for another repo | GitHub hides repositories a token cannot see |
| mock TTL (seconds) | GitHub installation tokens last about 1 hour; mock expiry does not prove GitHub's behavior |
| issuer revoke ops, introspect | GitHub `DELETE /installation/token`; there is no introspection, so mock-host revocation semantics must be verified against GitHub separately |

## GitHub backend and separate-identity deployment

`issuer.py --backend github` reads `policy.github` (`api_url`, `app_id`, `owner`, `installation_id`,
`private_key_file`); the key is only passed by path to `openssl dgst -sign`. Intended deployment: run
the issuer as a separate OS user (e.g. `exp004-issuer`) from a root-owned copy of the code, with the
App key readable only by that user; the agent's user connects over the Unix socket. The socket mode
(`--socket-mode`, e.g. 0666 in a 0755 dir) is not the control: policy `client_uids` (SO_PEERCRED)
plus the client secret are, and admin ops need `admin_uids` (default: issuer euid) plus the admin secret.
Tokens are revoked on `revoke_own`/`revoke_token`/`revoke_client`/`revoke_all` and, by default, on SIGTERM/SIGINT.
Offline test: `tests/run-github-offline.sh` (needs openssl; never contacts GitHub).
