# EXP-004 live GitHub runbook (owner-run)

Implements the approvals in [#5](https://github.com/jlaska/herdrnetes/issues/5) (G1–G4, optional G6; G5 declined).
**Status: awaiting security review of the live adapter. Do not start phase 3 before that review.**

Every step that touches the App key, the admin secret or `sudo` is performed by the **owner**. Autonomous agents
prepared these files, but never run them, and never see the key, JWTs, tokens or unredacted output.

## Security model

| Asset | Where | Who can read it |
| --- | --- | --- |
| App private key | `/var/lib/exp004-issuer/app.pem`, `exp004-issuer:exp004-issuer 0400`, dir `0700` | Only the `exp004-issuer` user (and root) |
| Issuer code | `/usr/local/libexec/exp004/` (root-owned copy of the **reviewed** commit) | Everyone may read it; only root may write it. An agent cannot alter the code that holds the key |
| Admin secret, policy, revocation state | `/var/lib/exp004-issuer/` | `exp004-issuer` only |
| Issuer process | Transient systemd unit, `--uid=exp004-issuer`, `ProtectHome=yes` (cannot read `/home`), `ProtectSystem=strict`, `NoNewPrivileges` | — |
| Client secrets | `~/.config/exp004-live/*.json` (0600) | **Every process of the owner's login, including agents** |
| Minted tokens | Issuer memory; the client-side Git process | Any process of the owner's login while the issuer runs |

What this does **not** protect: the client side is the owner's UID. While the issuer runs, any process of that login,
including an agent session, can request tokens **within policy**: `herdrnetes-exp004-a` contents read/write, ≤1 h.
That is the workload boundary of FIND-044. Policy and the App installation keep the blast radius to one throwaway
repository. Stop the issuer when not testing.

Preconditions the owner checks:

- The owner's login has **no passwordless sudo** (`sudo -l` shows no `NOPASSWD`). An agent able to run
  `sudo -n` would defeat the separate identity.
- `sudo` timestamps are per-terminal (Fedora default `timestamp_type=tty`). Do not run `sudo` in a terminal that hosts
  an agent.
- Close or pause agent sessions on the workstation during **phase 3 key handling**. The browser download briefly
  lands in the owner's home.

## Phase 1 — test repositories (G1)

```bash
O=<github-owner>
gh repo create "$O/herdrnetes-exp004-a" --private --add-readme
gh repo create "$O/herdrnetes-exp004-b" --private --add-readme
for r in a b; do gh repo view "$O/herdrnetes-exp004-$r" --json nameWithOwner,visibility,id,createdAt; done
```

Record and review identity and visibility (both `PRIVATE`). The README is the only content. Use `gh repo create`
without `--add-readme` if a zero-commit repository is required; `run-live.sh` then needs an initial commit first.

## Phase 2 — GitHub App (G2), browser

1. *Settings → Developer settings → GitHub Apps → New GitHub App.* Name `herdrnetes-exp004-<random>`, homepage the
   test repository URL. **Webhook: uncheck Active.**
2. Repository permissions: **Contents: Read and write**. Metadata becomes Read-only automatically. **Nothing else.**
3. *Where can this GitHub App be installed?* **Only on this account.** Create it, and note the **App ID / Client ID**.
4. *Install App → Only select repositories → `herdrnetes-exp004-a`.* Note the installation ID from the URL
   (`…/settings/installations/<id>`).
5. Confirm the scope (owner's gh):
   `gh api /user/installations/<id>/repositories --jq '.total_count, .repositories[].full_name'`, which must be
   exactly `1` and `<owner>/herdrnetes-exp004-a`.

## Phase 3 — issuer under a separate identity (G3)

Run from a terminal with no agent. Check out the reviewed commit and verify it:

```bash
REV=<reviewed commit sha from #5>
git -C ~/Projects/herdrnetes fetch && git -C ~/Projects/herdrnetes diff --quiet "$REV" -- experiments/exp-004 || echo "TREE DIFFERS FROM REVIEW"
X=~/Projects/herdrnetes/experiments/exp-004
sudo useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin exp004-issuer
sudo install -d -o root -g root -m 0755 /usr/local/libexec/exp004
sudo install -o root -g root -m 0755 "$X/harness/issuer.py" "$X/harness/issuer-ctl.py" "$X/live/issuer-start.sh" /usr/local/libexec/exp004/
sha256sum /usr/local/libexec/exp004/* ; git -C ~/Projects/herdrnetes show "$REV:experiments/exp-004/harness/issuer.py" | sha256sum
sudo install -d -o exp004-issuer -g exp004-issuer -m 0700 /var/lib/exp004-issuer
```

Generate the App key in the browser (*App settings → Private keys → Generate*), then move it immediately:

```bash
sudo install -o exp004-issuer -g exp004-issuer -m 0400 ~/Downloads/<app>.*.private-key.pem /var/lib/exp004-issuer/app.pem
shred -u ~/Downloads/<app>.*.private-key.pem
sudo -u exp004-issuer sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /var/lib/exp004-issuer/admin.secret'
```

Client credentials (secrets stay in the owner's home; only their hashes go into the policy):

```bash
umask 077; mkdir -p ~/.config/exp004-live
for c in agent-ro agent-rw probe-b probe-perm; do
  s=$(head -c 32 /dev/urandom | base64 | tr -d '/+=')
  printf '{"client": "%s", "secret": "%s"}' "$c" "$s" > ~/.config/exp004-live/$c.json
  echo "$c $(printf %s "$s" | sha256sum | cut -d' ' -f1)"; unset s
done
```

Fill `live/policy.template.json`: owner, App ID, installation ID, the four hashes, and `client_uids` = `id -u`. Install
it as `exp004-issuer`-owned `0400` at `/var/lib/exp004-issuer/policy.json`. Then start the issuer:

```bash
sudo /usr/local/libexec/exp004/issuer-start.sh
systemctl status exp004-issuer; sudo journalctl -u exp004-issuer -n 5
```

Admin commands (owner, separate terminal):

```bash
CTL="sudo -u exp004-issuer /usr/bin/python3 /usr/local/libexec/exp004/issuer-ctl.py /run/exp004-issuer/issuer.sock --admin-secret /var/lib/exp004-issuer/admin.secret"
$CTL revoke_all ; $CTL revoke_client --client agent-rw ; $CTL reinstate_client --client agent-rw
sudo systemctl stop exp004-issuer     # SIGTERM: finishes in-flight mints, then DELETEs every outstanding token
```

## Phase 4 — rulesets on `a` only (G4)

Rulesets on private repositories depend on the plan. If either call returns an upgrade or 403/404 error, L12 is
**blocked**.

```bash
gh api -X POST "repos/$O/herdrnetes-exp004-a/rulesets" --input - <<'EOF'
{"name":"exp004-protect-main","target":"branch","enforcement":"active","bypass_actors":[],
 "conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},
 "rules":[{"type":"update"},{"type":"deletion"},{"type":"non_fast_forward"}]}
EOF
gh api -X POST "repos/$O/herdrnetes-exp004-a/rulesets" --input - <<'EOF'
{"name":"exp004-signed","target":"branch","enforcement":"active","bypass_actors":[],
 "conditions":{"ref_name":{"include":["refs/heads/signed/**"],"exclude":[]}},
 "rules":[{"type":"required_signatures"}]}
EOF
```

## Phase 5 — live matrix (owner terminal)

```bash
~/Projects/herdrnetes/experiments/exp-004/live/run-live.sh "$O" r1            # add --expiry (61 min) / --manual-scope
```

It prints its own hash and the helper's hash at start; compare them with the reviewed commit. It pauses for the admin
steps of L10 and L11, which you run with `$CTL`/`systemctl` in the other terminal. Sanitized results go to
`~/.local/share/exp004-live/r1/results.tsv`. Review them before sharing, then paste them into #5. Also run
`sudo journalctl -u exp004-issuer | grep -cE 'gh[a-z]_|eyJ'` (expect `0`).

| ID | Checks | Expected |
| --- | --- | --- |
| L00 | Both repositories exist and are private | private |
| L01–L03 | Clone, fetch, push `exp004/live-<run>` | succeed |
| L04 | Push with a read-only token | GitHub rejects (403) |
| L05 | Repository `b` | issuer refuses (policy) |
| L06 | Mint for `b` (outside the installation) | GitHub refuses (code recorded) |
| L07 | Mint with `workflows: write` (not granted) | GitHub refuses (code recorded) |
| L08 | Token for `a` used on `b` | not found |
| L09 | `DELETE /installation/token`, then reuse | rejected; latency recorded |
| L10 | `revoke_client` | new mints refused **and** the outstanding token dead at GitHub |
| L11 | Issuer stopped | Git fails closed; outstanding token revoked on exit |
| L12a/b | Push to `main`; unsigned push to `signed/**` | ruleset rejects, or **blocked** by plan |
| L13 | Push of a `.github/workflows` file | rejected without the workflows permission (the file is `workflow_dispatch` only) |
| L14 | Activity API actor for the L03 push | recorded (expected `<app>[bot]`) |
| L15 | Token/JWT scan of HOME, worktrees, config, default trace, evidence | 0 |
| L16 | Real 1 h expiry | `--expiry` only; otherwise **untested** |
| L17 | Remove `a` from the installation with a live token | `--manual-scope` only; otherwise **untested** |

## Phase 6 — optional owner-signed contribution (G6)

On the owner workstation, with the existing YubiKey/GPG setup and the owner's own credential (no agent involved):

```bash
git clone "https://github.com/$O/herdrnetes-exp004-a.git" /tmp/e4-g6 && cd /tmp/e4-g6
git fetch origin exp004/live-r1 && git switch -c g6 FETCH_HEAD
git rebase --exec 'git commit --amend --no-edit -S' main      # one touch per commit
git log --show-signature -1 && git push origin HEAD:refs/heads/signed/owner-r1
gh api "repos/$O/herdrnetes-exp004-a/commits/$(git rev-parse HEAD)" --jq .commit.verification
```

Expected: the push to `signed/**` is accepted (signed), and `verification.verified` is `true` with the reason
recorded. If skipped, GitHub "Verified" stays **untested**.

## Phase 7 — cleanup (record each step's status in #5)

```bash
$CTL revoke_all; sudo systemctl stop exp004-issuer
# GitHub: uninstall the App from the account, then delete the App (invalidates its keys)
sudo shred -u /var/lib/exp004-issuer/app.pem /var/lib/exp004-issuer/admin.secret
sudo rm -rf /var/lib/exp004-issuer /usr/local/libexec/exp004 && sudo userdel exp004-issuer
shred -u ~/.config/exp004-live/*.json && rmdir ~/.config/exp004-live
gh repo delete "$O/herdrnetes-exp004-a" --yes; gh repo delete "$O/herdrnetes-exp004-b" --yes   # after results review
```

Keep `~/.local/share/exp004-live/` (sanitized evidence) until review is complete.
