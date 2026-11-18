# EXP-004 commit-signing harness (credential-free)

Purpose: measure how Git SSH signing behaves for the identity options under evaluation, using only
disposable keys and agents started by the script. No cluster, no real credentials.

Run: `./run-signing.sh` (needs bash, git, OpenSSH, python3). Prints `PASS|FAIL|LIMITATION|NOTE <id> <desc> — <observed>`
and writes `results.tsv` into a fresh temp dir under the scratchpad (override with `SCRATCH=`).
Agent sockets live in a short private dir under `/tmp` (Unix socket paths are limited to about 107 bytes).

| Scenario | Option | What it shows |
|---|---|---|
| S01 | B1 bot key file | key file + `gpg.format=ssh` signs; verifies for the bot principal |
| S02 | B1 | any same-uid process can use the key file (LIMITATION) |
| S03 | all | what git reports when the allowed_signers principal differs from the committer email, or the key is absent |
| S04 | A | key only in a dedicated agent; private file deleted; pubkey-only `user.signingkey` |
| S05 | A | anything reaching the socket can sign, any namespace (LIMITATION) |
| S06 | A | `ssh-add -c` confirmation, askpass deny/approve (headless) |
| S07 | A | signer unavailable: commit fails, no silent unsigned commit |
| S08 | A | `ssh-add -t` key lifetime expiry |
| S09 | C | owner re-signs agent's unsigned commits via `rebase --exec 'git commit --amend --no-edit -S'` |
| S10 | all | tampered commit with kept gpgsig fails verification |
| S11 | A | `agent-relay.py` policy relay: only SSHSIG with namespace `git` is allowed |

Safety: the script unsets `SSH_AUTH_SOCK`/`SSH_AGENT_PID`/`GPG_AGENT_INFO`, uses an isolated `HOME`
(refuses to run inside the repo), `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM=1` and `GNUPGHOME`. Keys are
`ssh-keygen -t ed25519 -N ''` throwaways; agents are its own and are killed in an EXIT trap.

Not tested: real YubiKey/FIDO touch or PIN prompts, GitHub "Verified" badge, GPG card forwarding,
and a relay over `kubectl exec` stdio (S11 uses Unix sockets; the kubectl variant has the same shape,
with a subprocess pipe as upstream, but was not built or tested against the cluster).
