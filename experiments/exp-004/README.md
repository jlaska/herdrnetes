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
| `harness/issuer.py` | Mints `ghs_mock_*` tokens per policy. Tokens in memory only; client revocations persisted in `--state` (T08c). Ops: token, revoke_own, revoke_token, revoke_client, reinstate_client, introspect. `mint_github()` is a stub |
| `harness/mock_githost.py` | Smart-HTTP host: 401 bad/expired/revoked, 404 other repo, 403 read token pushing |
| `harness/git-credential-exp004` | Credential helper: `get` mints, `store` ignored, `erase` revokes (best effort); `quit=1` on failure |
| `tests/run-matrix.sh` | Self-contained matrix T01-T12; results in `$T/results.tsv` |

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
| `ghs_mock_*` from `issuer.py` | Installation token from `POST /app/installations/{id}/access_tokens` with `repositories` and `permissions` (see `mint_github()`) |
| HMAC root key file | GitHub App private key (RS256 JWT) |
| host returns 404 for another repo | GitHub hides repositories a token cannot see |
| mock TTL (seconds) | GitHub installation tokens last about 1 hour; mock expiry does not prove GitHub's behavior |
| issuer revoke ops, introspect | GitHub `DELETE /installation/token`; there is no introspection, so mock-host revocation semantics must be verified against GitHub separately |
