#!/usr/bin/env bash
# EXP-004 credential-free commit-signing harness. Only disposable keys, only agents started
# here, everything under an isolated HOME in a temp dir. Prints
#   PASS|FAIL|LIMITATION|NOTE <id> <desc> — <observed>
# and writes results.tsv into the temp dir. Never touches the real ssh/gpg agents or keys.
set -euo pipefail
unset SSH_AUTH_SOCK SSH_AGENT_PID GPG_AGENT_INFO

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/claude-1000/-home-jlaska-Projects-herdrnetes/3adcc2af-0b4f-4a8e-a162-4153fedc5ab3/scratchpad}
mkdir -p "$SCRATCH"
T=$(mktemp -d "$SCRATCH/exp004-signing.XXXXXX")
case "$T/" in "$REPO"/*) echo "refusing: temp dir inside repo" >&2; exit 2 ;; esac

# Unix socket paths are limited to ~107 bytes; the scratchpad path is too long, so sockets
# live in a private short dir (mode 700, removed on exit).
SD=$(mktemp -d /tmp/e4s.XXXXXX)
export HOME=$T/home
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig
export GIT_CONFIG_NOSYSTEM=1
export GNUPGHOME=$HOME/.gnupg
mkdir -p "$HOME/.ssh" "$GNUPGHOME"
chmod 700 "$HOME/.ssh" "$GNUPGHOME"
: >"$GIT_CONFIG_GLOBAL"

PIDS=()
cleanup() { rm -rf "$SD"; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

TSV=$T/results.tsv
printf 'status\tid\tdescription\tobserved\n' >"$TSV"
FAILS=0
rec() { # status id desc observed
  printf '%s %s %s — %s\n' "$1" "$2" "$3" "$4"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$TSV"
  [ "$1" = FAIL ] && FAILS=$((FAILS + 1))
  return 0
}
one() { tr '\n' ' ' | sed 's/ *$//'; }

# Run a command as another identity: separate HOME, same uid, optional agent socket.
as() { # home sock cmd...   (sock may be "-")
  local h=$1 s=$2
  shift 2
  local e=(env -i PATH="$PATH" HOME="$h" GIT_CONFIG_GLOBAL="$h/.gitconfig" GIT_CONFIG_NOSYSTEM=1 GNUPGHOME="$h/.gnupg")
  [ "$s" != - ] && e+=(SSH_AUTH_SOCK="$s")
  "${e[@]}" "$@"
}
mkhome() { # dir name email
  mkdir -p "$1/.ssh" "$1/.gnupg"
  chmod 700 "$1/.ssh" "$1/.gnupg"
  printf '[user]\n\tname = %s\n\temail = %s\n[gpg]\n\tformat = ssh\n[init]\n\tdefaultBranch = main\n' "$2" "$3" >"$1/.gitconfig"
}
genkey() { ssh-keygen -q -t ed25519 -N '' -C "$2" -f "$1"; }
start_agent() { # sock [env...]  -> sets AGENT_PID
  local s=$1
  shift
  env -u SSH_AUTH_SOCK "$@" ssh-agent -D -a "$s" >/dev/null 2>&1 &
  AGENT_PID=$!
  PIDS+=("$AGENT_PID")
  for _ in $(seq 50); do [ -S "$s" ] && return 0; sleep 0.1; done
  echo "agent did not start" >&2; return 1
}
pubfield() { awk '{print $1" "$2}' "$1"; }
mkrepo() { # dir  (uses current identity env)
  git init -q "$1"
  git -C "$1" commit -q --allow-empty -m base
}

BOT=bot@example.invalid
OWNER=owner@example.invalid
mkhome "$HOME" "Bot" "$BOT"
echo "# git: $(git --version)  ssh: $(ssh -V 2>&1)  python: $(python3 --version)"
echo "# temp dir: $T"

# ---------- S01 bot key file (B1) ----------
genkey "$HOME/.ssh/bot" exp004-bot
git config --global user.signingkey "$HOME/.ssh/bot"
printf '%s namespaces="git" %s\n' "$BOT" "$(pubfield "$HOME/.ssh/bot.pub")" >"$HOME/allowed_signers"
git config --global gpg.ssh.allowedSignersFile "$HOME/allowed_signers"
mkrepo "$T/r1"
git -C "$T/r1" commit -q --allow-empty -S -m s01
out=$(git -C "$T/r1" log --show-signature -1 2>&1 | grep -E 'Good|signature' | head -1 | one)
if git -C "$T/r1" verify-commit HEAD 2>&1 | grep -q "Good \"git\" signature for $BOT"; then
  rec PASS S01 "bot key file signs; verifies for bot principal" "$out"
else rec FAIL S01 "bot key file signs; verifies for bot principal" "$out"; fi

# ---------- S02 same-uid misuse ----------
mkhome "$T/home-evil" "Evil" "evil@example.invalid"
if as "$T/home-evil" - ssh-keygen -Y sign -f "$HOME/.ssh/bot" -n git "$T/r1/.git/HEAD" >/dev/null 2>&1; then
  rec LIMITATION S02 "second same-uid process (different env/HOME) signs with bot key file" "signature produced; file perms give no isolation between same-uid processes"
else rec FAIL S02 "second same-uid process signs with bot key file" "unexpectedly refused"; fi

# ---------- S03 wrong principal ----------
printf '%s namespaces="git" %s\n' "someone-else@example.invalid" "$(pubfield "$HOME/.ssh/bot.pub")" >"$T/allowed_wrong"
vout=$(git -C "$T/r1" -c gpg.ssh.allowedSignersFile="$T/allowed_wrong" verify-commit HEAD 2>&1 | one) && vrc=0 || vrc=$?
lout=$(git -C "$T/r1" -c gpg.ssh.allowedSignersFile="$T/allowed_wrong" log --show-signature -1 2>&1 | grep -i signature | head -1 | one)
rec NOTE S03 "allowed_signers maps key to other email than committer ($BOT)" "verify-commit rc=$vrc: $vout | log: $lout"
printf '' >"$T/allowed_empty"
vout=$(git -C "$T/r1" -c gpg.ssh.allowedSignersFile="$T/allowed_empty" verify-commit HEAD 2>&1 | one) && vrc=0 || vrc=$?
rec NOTE S03b "key absent from allowed_signers" "verify-commit rc=$vrc: $vout"

# ---------- S04 dedicated agent, private key not on disk ----------
H=$T/human
mkdir -p "$H"
genkey "$H/hk" exp004-human
HS=$SD/h.sock
start_agent "$HS"
HPID=$AGENT_PID
SSH_AUTH_SOCK=$HS ssh-add -q "$H/hk" 2>/dev/null
mv "$H/hk.pub" "$H/hk.pub.keep"
rm -f "$H/hk"
mv "$H/hk.pub.keep" "$H/hk.pub"
HUMAN=human@example.invalid
printf '%s namespaces="git" %s\n' "$HUMAN" "$(pubfield "$H/hk.pub")" >"$T/allowed_human"
mkhome "$T/home-h" "Human" "$HUMAN"
git config --file "$T/home-h/.gitconfig" user.signingkey "$H/hk.pub"
git config --file "$T/home-h/.gitconfig" gpg.ssh.allowedSignersFile "$T/allowed_human"
mkrepo_h() { as "$T/home-h" "$1" bash -c "git init -q '$2' && git -C '$2' commit -q --allow-empty -m base"; }
mkrepo_h "$HS" "$T/r4"
if as "$T/home-h" "$HS" git -C "$T/r4" commit -q --allow-empty -S -m s04 &&
  as "$T/home-h" - git -C "$T/r4" verify-commit HEAD 2>&1 | grep -q "Good \"git\" signature for $HUMAN" &&
  [ ! -e "$H/hk" ]; then
  rec PASS S04 "agent-held key signs via SSH_AUTH_SOCK, pubkey-only signingkey, private file deleted" "good signature for $HUMAN; $(ls "$H" | one) on disk"
else rec FAIL S04 "agent-held key signing" "failed"; fi

# ---------- S05 any process with the socket signs ----------
if as "$T/home-evil" "$HS" ssh-keygen -Y sign -f "$H/hk.pub" -n git "$T/r1/.git/HEAD" >/dev/null 2>&1 &&
  as "$T/home-evil" "$HS" ssh-keygen -Y sign -f "$H/hk.pub" -n file "$T/r1/.git/HEAD" >/dev/null 2>&1; then
  rec LIMITATION S05 "any process able to reach the socket signs for any namespace" "unrelated env signed namespace git and file with no prompt"
else rec FAIL S05 "socket holder signs" "unexpectedly refused"; fi

# ---------- S06 confirmation (ssh-add -c) ----------
mkdir -p "$T/s6"
genkey "$T/s6/ck" exp004-confirm
cat >"$T/s6/askpass" <<APEOF
#!/bin/sh
echo "askpass called: \$*" >>"$T/s6/askpass.log"
[ "\$(cat "$T/s6/mode")" = allow ]
APEOF
chmod +x "$T/s6/askpass"
CS=$SD/c.sock
start_agent "$CS" SSH_ASKPASS="$T/s6/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
CPID=$AGENT_PID
SSH_AUTH_SOCK=$CS ssh-add -q -c "$T/s6/ck" 2>/dev/null
mv "$T/s6/ck" "$T/s6/ck.priv"; rm -f "$T/s6/ck.priv"
echo hello >"$T/s6/data"
echo deny >"$T/s6/mode"
if err=$(as "$HOME" "$CS" ssh-keygen -Y sign -f "$T/s6/ck.pub" -n git "$T/s6/data" 2>&1); then
  rec NOTE S06 "confirm agent, askpass denies" "signing SUCCEEDED despite deny (askpass log: $(cat "$T/s6/askpass.log" 2>/dev/null | one))"
else
  gerr=$(as "$HOME" "$CS" git -c user.signingkey="$T/s6/ck.pub" -C "$T/r1" commit --allow-empty -S -m s06deny 2>&1 | one) || true
  rec PASS S06a "confirm agent, askpass denies -> signing fails" "ssh-keygen: $(echo "$err" | one) | git: $gerr | askpass called $(grep -c . "$T/s6/askpass.log" 2>/dev/null || echo 0)x"
fi
echo allow >"$T/s6/mode"
if err=$(as "$HOME" "$CS" ssh-keygen -Y sign -f "$T/s6/ck.pub" -n git "$T/s6/data" 2>&1); then
  rec PASS S06b "confirm agent, askpass approves -> signing succeeds" "askpass log: $(tail -1 "$T/s6/askpass.log" | one)"
else rec NOTE S06b "confirm agent, askpass approves" "failed headlessly: $(echo "$err" | one)"; fi

# ---------- S07 signer unavailable ----------
before=$(git -C "$T/r4" rev-parse HEAD)
kill "$HPID"; wait "$HPID" 2>/dev/null || true
if as "$T/home-h" "$HS" git -C "$T/r4" commit -q --allow-empty -S -m s07 >"$T/s7.err" 2>&1; then
  rec FAIL S07a "commit -S with signer dead" "commit succeeded"
else
  after=$(git -C "$T/r4" rev-parse HEAD)
  [ "$before" = "$after" ] && st="HEAD unchanged" || st="HEAD CHANGED"
  rec PASS S07a "commit -S with agent killed fails, no commit ($st)" "$(one <"$T/s7.err")"
fi
as "$T/home-h" "$HS" git config --file "$T/home-h/.gitconfig" commit.gpgsign true
if as "$T/home-h" "$HS" git -C "$T/r4" commit -q --allow-empty -m s07b >"$T/s7b.err" 2>&1; then
  rec FAIL S07b "commit.gpgsign=true plain commit, signer dead" "unsigned/any commit created"
else
  [ "$before" = "$(git -C "$T/r4" rev-parse HEAD)" ] && st="HEAD unchanged" || st="HEAD CHANGED"
  rec PASS S07b "commit.gpgsign=true plain commit fails, not silently unsigned ($st)" "$(one <"$T/s7b.err")"
fi
as "$T/home-h" "$HS" git config --file "$T/home-h/.gitconfig" commit.gpgsign false
# No SSH_AUTH_SOCK at all
if as "$T/home-h" - git -C "$T/r4" commit -q --allow-empty -S -m s07c >"$T/s7c.err" 2>&1; then
  rec FAIL S07c "commit -S with no SSH_AUTH_SOCK" "commit succeeded"
else rec PASS S07c "commit -S with no SSH_AUTH_SOCK fails" "$(one <"$T/s7c.err")"; fi

# ---------- S08 key lifetime ----------
mkdir -p "$T/s8"
genkey "$T/s8/k" exp004-ttl
LS=$SD/l.sock
start_agent "$LS"
SSH_AUTH_SOCK=$LS ssh-add -q -t 3 "$T/s8/k" 2>/dev/null
rm -f "$T/s8/k"  # else ssh-keygen falls back to the on-disk private key
echo x >"$T/s8/d"
as "$HOME" "$LS" ssh-keygen -Y sign -f "$T/s8/k.pub" -n git "$T/s8/d" >/dev/null 2>&1 && early=ok || early=fail
sleep 4
rm -f "$T/s8/d.sig"
if err=$(as "$HOME" "$LS" ssh-keygen -Y sign -f "$T/s8/k.pub" -n git "$T/s8/d" 2>&1); then
  rec FAIL S08 "ssh-add -t 3: signing after 4s" "still signed (early=$early)"
else
  [ "$early" = ok ] && rec PASS S08 "ssh-add -t 3: signs at t=0, fails after 4s" "$(echo "$err" | one)" || rec FAIL S08 "key lifetime" "early sign failed"
fi

# ---------- S09 owner-reviewed re-sign (C) ----------
AG=$T/home-agent
mkhome "$AG" "Agent" "agent@example.invalid"
as "$AG" - bash -c "git init -q '$T/ar' && cd '$T/ar' && git commit -q --allow-empty -m base && git checkout -q -b work && echo 1 >f1 && git add f1 && git commit -q -m c1 && echo 2 >f2 && git add f2 && git commit -q -m c2"
OW=$T/home-owner
mkhome "$OW" "Owner" "$OWNER"
genkey "$OW/.ssh/ok" exp004-owner
OS=$SD/o.sock
start_agent "$OS"
SSH_AUTH_SOCK=$OS ssh-add -q "$OW/.ssh/ok" 2>/dev/null
rm -f "$OW/.ssh/ok"
printf '%s namespaces="git" %s\n' "$OWNER" "$(pubfield "$OW/.ssh/ok.pub")" >"$T/allowed_owner"
git config --file "$OW/.gitconfig" user.signingkey "$OW/.ssh/ok.pub"
git config --file "$OW/.gitconfig" gpg.ssh.allowedSignersFile "$T/allowed_owner"
as "$OW" - git clone -q "$T/ar" "$T/or"
as "$OW" - git -C "$T/or" checkout -q work
base=$(git -C "$T/or" rev-parse work~2)
orig=$(git -C "$T/or" rev-list --reverse "$base..work" | one)
if as "$OW" "$OS" git -C "$T/or" rebase -q --exec 'git commit --amend --no-edit -S -q' "$base" >"$T/s9.err" 2>&1; then
  new=$(git -C "$T/or" rev-list --reverse "$base..HEAD" | one)
  good=1
  for c in $new; do
    as "$OW" - git -C "$T/or" verify-commit "$c" 2>&1 | grep -q "Good \"git\" signature for $OWNER" || good=0
  done
  ae=$(git -C "$T/or" log --format=%ae "$base..HEAD" | sort -u | one)
  ce=$(git -C "$T/or" log --format=%ce "$base..HEAD" | sort -u | one)
  [ "$orig" != "$new" ] && chg=changed || chg=same
  if [ $good = 1 ] && [ "$ae" = agent@example.invalid ] && [ "$ce" = "$OWNER" ] && [ $chg = changed ]; then
    rec PASS S09a "owner rebase --exec amend -S re-signs 2 agent commits" "verified for $OWNER; author=$ae committer=$ce hashes $chg"
  else rec FAIL S09a "owner re-sign" "good=$good author=$ae committer=$ce hashes=$chg"; fi
else rec FAIL S09a "owner re-sign" "rebase failed: $(one <"$T/s9.err")"; fi
bad=0
for c in $orig; do as "$OW" - git -C "$T/or" verify-commit "$c" >/dev/null 2>&1 && bad=1; done
[ $bad = 0 ] && rec PASS S09b "original unsigned agent commits fail verify-commit" "both rejected" || rec FAIL S09b "original agent commits" "unexpectedly verified"

# ---------- S10 tampered signature ----------
h=$(git -C "$T/r1" rev-parse HEAD)
git -C "$T/r1" cat-file commit "$h" | sed 's/^s01$/s01-tampered/' >"$T/tampered"
th=$(git -C "$T/r1" hash-object -t commit -w "$T/tampered")
grep -q '^gpgsig' "$T/tampered" || echo "WARN: no gpgsig kept" >&2
if tout=$(git -C "$T/r1" verify-commit "$th" 2>&1 | one); [ "$th" != "$h" ] && ! git -C "$T/r1" verify-commit "$th" >/dev/null 2>&1; then
  rec PASS S10 "commit body edited, gpgsig kept -> verify fails" "$tout"
else rec FAIL S10 "tampered commit" "verified: $tout"; fi

# ---------- S11 relay ----------
mkdir -p "$T/s11"
RS=$SD/r.sock
RD=$SD/d.sock
python3 "$HERE/agent-relay.py" --listen "$RS" --upstream "$OS" --policy git-sign 2>"$T/s11/relay.log" &
PIDS+=($!)
python3 "$HERE/agent-relay.py" --listen "$RD" --upstream "$OS" 2>"$T/s11/open.log" &
PIDS+=($!)
for _ in $(seq 50); do [ -S "$RS" ] && [ -S "$RD" ] && break; sleep 0.1; done
OWPUB=$OW/.ssh/ok.pub
as "$OW" - git clone -q "$T/ar" "$T/r11" 2>/dev/null
if as "$OW" "$RS" git -C "$T/r11" commit -q --allow-empty -S -m s11 2>"$T/s11/git.err" &&
  as "$OW" - git -C "$T/r11" verify-commit HEAD 2>&1 | grep -q "Good \"git\" signature for $OWNER"; then
  rec PASS S11a "git signing through filtered relay" "good signature for $OWNER; relay: $(grep 'type=13' "$T/s11/relay.log" | tail -1 | one)"
else rec FAIL S11a "git signing through filtered relay" "$(one <"$T/s11/git.err")"; fi
if err=$(as "$OW" "$RS" ssh-keygen -Y sign -f "$OWPUB" -n file "$T/s6/data" 2>&1); then
  rec FAIL S11b "ssh-keygen -n file through relay" "signed"
else rec PASS S11b "ssh-keygen -n file through relay refused" "$(echo "$err" | one) | relay: $(grep 'namespace=file' "$T/s11/relay.log" | tail -1 | one)"; fi
cat >"$T/s11/client.py" <<'PYEOF'
import socket, struct, sys
def snd(s, b): s.sendall(struct.pack(">I", len(b)) + b)
def rcv(s):
    n = struct.unpack(">I", s.recv(4))[0]; b = b""
    while len(b) < n: b += s.recv(n - len(b))
    return b
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
snd(s, bytes([11])); r = rcv(s)
if r[0] != 12: print("identities refused type", r[0]); sys.exit(1)
kl = struct.unpack_from(">I", r, 5)[0]; blob = r[9:9 + kl]
data = b"authentication-style challenge, not SSHSIG"
snd(s, bytes([13]) + struct.pack(">I", len(blob)) + blob + struct.pack(">I", len(data)) + data + struct.pack(">I", 0))
r = rcv(s)
print("reply type", r[0])  # 14 = SIGN_RESPONSE, 5 = FAILURE
sys.exit(0 if r[0] == 14 else 3)
PYEOF
cout=$(python3 -I "$T/s11/client.py" "$RD" 2>&1 | one) && crc=0 || crc=$?
[ $crc = 0 ] && rec PASS S11c0 "control: raw non-SSHSIG sign via UNFILTERED relay succeeds" "$cout" || rec FAIL S11c0 "control raw sign unfiltered" "$cout"
cout=$(python3 -I "$T/s11/client.py" "$RS" 2>&1 | one) && crc=0 || crc=$?
[ $crc = 3 ] && rec PASS S11c "raw non-SSHSIG (auth-style) sign via filtered relay refused" "$cout | relay: $(grep 'not-sshsig' "$T/s11/relay.log" | tail -1 | one)" || rec FAIL S11c "raw sign via filtered relay" "rc=$crc $cout"
if SSH_AUTH_SOCK=$RS ssh-add -D >"$T/s11/d.out" 2>&1; then
  n=$(SSH_AUTH_SOCK=$OS ssh-add -l 2>&1 | one)
  rec FAIL S11d "ssh-add -D through relay" "accepted ($(one <"$T/s11/d.out")); upstream: $n"
else
  rec PASS S11d "ssh-add -D through relay refused" "$(one <"$T/s11/d.out") | upstream still: $(SSH_AUTH_SOCK=$OS ssh-add -l 2>&1 | one)"
fi
genkey "$T/s11/extra" exp004-extra
if SSH_AUTH_SOCK=$RS ssh-add "$T/s11/extra" >"$T/s11/a.out" 2>&1; then
  rec FAIL S11e "ssh-add (add identity) through relay" "accepted"
else rec PASS S11e "ssh-add (add identity) through relay refused" "$(one <"$T/s11/a.out")"; fi
rec NOTE S11f "kubectl-exec stdio relay" "same shape (proxy upstream = subprocess pipe); NOT built or tested against a cluster"

echo "# results: $TSV  (FAIL count: $FAILS)"
[ "$FAILS" = 0 ]
