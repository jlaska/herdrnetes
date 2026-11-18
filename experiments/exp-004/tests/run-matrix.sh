#!/usr/bin/env bash
# EXP-004 test matrix: credential issuer + mock Git host + Git credential helper, all synthetic.
# Usage: tests/run-matrix.sh        (EXP004_TMP=<dir> to choose the temp base, EXP004_KEEP=1 to keep it,
#                                    EXP004_TTL=<seconds> token lifetime, default 3)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
H=$here/harness
TTL=${EXP004_TTL:-3}
die() { echo "run-matrix: $*" >&2; exit 1; }

repo_root=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || echo "$here")
base=$(realpath "${EXP004_TMP:-${TMPDIR:-/tmp}}")
case "$base/" in "$repo_root"/*) die "temp dir $base is inside the repository" ;; esac
T=$(mktemp -d -p "$base" exp004.XXXXXX)

# --- isolated environment: nothing from the real HOME, system config, askpass or tokens leaks in ---
export HOME=$T/home HOMEB=$T/homeB XDG_CONFIG_HOME=$T/home/.config
mkdir -p "$HOME/.config/exp004" "$HOMEB" "$T"/{issuer,records,logs,out,work,repos}
CF=$HOME/.config/exp004
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false
unset SSH_ASKPASS GH_TOKEN GITHUB_TOKEN GIT_TRACE GIT_TRACE_CURL GIT_TRACE_PACKET
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
SOCKDIR=$(mktemp -d -p "${XDG_RUNTIME_DIR:-$T}" e4.XXXXXX)   # sun_path is ~107 bytes max: keep it short
export EXP004_ISSUER_SOCK=$SOCKDIR/i.sock EXP004_HOST=127.0.0.1:$PORT
URL=http://$EXP004_HOST
W=$T/work
export EXP004_TEST_RECORD_TOKENS=$T/records/tokens.txt
ISSUER_PID="" HOST_PID="" FAILS=0 RC=0 ELAPSED=0 HMARK=0
: >"$T/results.tsv"

cleanup() {
    kill "$ISSUER_PID" "$HOST_PID" 2>/dev/null || true
    if [ "${EXP004_KEEP:-0}" = 1 ]; then echo "kept $T"; else rm -rf "$T"; fi
    rm -rf "$SOCKDIR"
}
trap cleanup EXIT

rand() { python3 -c 'import secrets; print(secrets.token_hex(16))'; }
sha() { printf %s "$1" | sha256sum | cut -d' ' -f1; }

# --- fixtures: secrets, policy, client files, helper config, bare repos ---
rand >"$T/issuer/root.key"; ADMIN=$(rand); printf %s "$ADMIN" >"$T/issuer/admin.secret"
SEC_RO=$(rand); SEC_RW=$(rand)
printf "[]" >"$T/issuer/revoked-clients.json"   # owner step: the issuer refuses a missing state file
chmod 600 "$T"/issuer/*
cat >"$T/issuer/policy.json" <<EOF
{"ttl_seconds": $TTL, "clients": {
 "agent-ro": {"secret_sha256": "$(sha "$SEC_RO")", "repos": {"acme/app": "read"}},
 "agent-rw": {"secret_sha256": "$(sha "$SEC_RW")", "repos": {"acme/app": "write"}}}}
EOF
printf '{"client": "agent-ro", "secret": "%s"}' "$SEC_RO" >"$CF/agent-ro.json"
printf '{"client": "agent-rw", "secret": "%s"}' "$SEC_RW" >"$CF/agent-rw.json"
chmod 600 "$CF"/*.json
cat >"$GIT_CONFIG_GLOBAL" <<EOF
[user]
	name = Exp Four
	email = exp004@example.invalid
[init]
	defaultBranch = main
[credential]
	helper =
	helper = $H/git-credential-exp004
	useHttpPath = true
EOF
cp "$GIT_CONFIG_GLOBAL" "$HOMEB/.gitconfig"
for r in app other; do
    mkdir -p "$T/repos/acme"; git init -q --bare "$T/repos/acme/$r.git"
    git init -q "$T/seed-$r"; git -C "$T/seed-$r" commit -q --allow-empty -m "initial $r"
    git -C "$T/seed-$r" push -q "$T/repos/acme/$r.git" main
done
# One-shot replay helper: echoes a captured token from a 0600 file and logs which actions Git called.
cat >"$T/replay-helper" <<'EOF'
#!/bin/sh
echo "$1" >>"$REPLAY_LOG"
[ "$1" = get ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$(cat "$REPLAY_FILE")"
EOF
chmod 700 "$T/replay-helper"; : >"$T/replay.log"

# --- helpers ---
ro=(env EXP004_CLIENT_FILE="$CF/agent-ro.json")
rw=(env EXP004_CLIENT_FILE="$CF/agent-rw.json")
rww=(env EXP004_CLIENT_FILE="$CF/agent-rw.json" EXP004_ACCESS=write)

wait_ready() { # <python connect expression> ; poll up to 5 s
    for _ in $(seq 50); do python3 -c "$1" 2>/dev/null && return 0; sleep 0.1; done
    die "not ready: $1"
}
start_issuer() {
    python3 "$H/issuer.py" "$EXP004_ISSUER_SOCK" --policy "$T/issuer/policy.json" \
        --root-key "$T/issuer/root.key" --admin-secret "$T/issuer/admin.secret" \
        --state "$T/issuer/revoked-clients.json" 2>>"$T/logs/issuer.log" &
    ISSUER_PID=$!
    wait_ready "import socket; socket.socket(socket.AF_UNIX).connect('$EXP004_ISSUER_SOCK')"
}
stop_issuer() { kill "$ISSUER_PID"; wait "$ISSUER_PID" 2>/dev/null || true; rm -f "$EXP004_ISSUER_SOCK"; }
ask() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); s.sendall((sys.argv[2]+"\n").encode()); print(s.makefile().readline().strip())' \
        "$EXP004_ISSUER_SOCK" "$1"; }
adm() { ask "{\"op\":\"$1\",\"admin\":\"$ADMIN\",$2}"; }
capture() { # <client-file-name> <access> <repo>: run the helper like Git does, print the token
    printf 'protocol=http\nhost=%s\npath=%s.git\n\n' "$EXP004_HOST" "$3" |
        env EXP004_CLIENT_FILE="$CF/$1.json" EXP004_ACCESS="$2" "$H/git-credential-exp004" get 2>/dev/null |
        sed -n 's/^password=//p'
}
replay() { # <id> <token> <git args...>: use a captured token through the one-shot helper
    local id=$1 tok=$2; shift 2
    (umask 077; printf %s "$tok" >"$T/replay.tok")
    run "$id" env REPLAY_FILE="$T/replay.tok" REPLAY_LOG="$T/replay.log" git -c credential.helper= \
        -c credential.helper="$T/replay-helper" "$@"
}
run() { # <id> <cmd...>: sets RC, ELAPSED, HMARK; output in $T/out/<id>.{out,err}
    local id=$1 t0; shift
    HMARK=$(wc -l <"$T/logs/host.log"); t0=$(date +%s.%N); RC=0
    timeout 30 "$@" >"$T/out/$id.out" 2>"$T/out/$id.err" || RC=$?
    ELAPSED=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}')
}
host_saw() { tail -n +"$((HMARK + 1))" "$T/logs/host.log" | grep -q -- "$1"; }
err_has() { grep -q -- "$1" "$T/out/$2.err"; }
report() { # <PASS|FAIL|LIMITATION|NOTE> <id> <desc> <observed>
    printf '%s %s %s [%s]\n' "$1" "$2" "$3" "$4"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$1" "$ELAPSED" "$RC" "$3" "$4" >>"$T/results.tsv"
    if [ "$1" = FAIL ]; then FAILS=$((FAILS + 1)); fi
    return 0
}
check() { # <id> <desc> <ok-reason> <fail-reason> <command...>: PASS when the command succeeds
    local id=$1 d=$2 okr=$3 failr=$4; shift 4
    if "$@"; then report PASS "$id" "$d" "$okr"; else report FAIL "$id" "$d" "$failr"; fi
}
rc_ok() { [ "$RC" -eq 0 ]; }
rc_fail_host() { [ "$RC" -ne 0 ] && host_saw "$1"; }
rc_fail_with() { [ "$RC" -ne 0 ] && err_has "$1" "$2"; }

: >"$T/logs/host.log"
start_issuer
python3 "$H/mock_githost.py" --root "$T/repos" --port "$PORT" --issuer-sock "$EXP004_ISSUER_SOCK" \
    --admin-file "$T/issuer/admin.secret" 2>>"$T/logs/host.log" &
HOST_PID=$!
wait_ready "import socket; socket.create_connection(('127.0.0.1',$PORT))"
echo "git $(git --version | cut -d' ' -f3), ttl ${TTL}s, port $PORT"
START=$(date +%s)

# --- T01-T04: normal flows and a read-only token ---
run T01 "${ro[@]}" git clone "$URL/acme/app.git" "$W/ro"
check T01 "clone acme/app with agent-ro" "exit 0, $(git -C "$W/ro" log --oneline 2>/dev/null | wc -l) commit" "exit $RC: $(head -c 200 "$T/out/T01.err")" rc_ok
run T02 "${ro[@]}" git -C "$W/ro" fetch
check T02 "fetch with agent-ro" "exit 0" "exit $RC" rc_ok

run T03a "${rw[@]}" git clone "$URL/acme/app.git" "$W/rw"
git -C "$W/rw" commit -q --allow-empty -m "from agent-rw"
run T03 "${rww[@]}" git -C "$W/rw" push origin HEAD:refs/heads/exp004/test
check T03 "push exp004/test with agent-rw (access=write)" "exit 0, branch in bare repo" "exit $RC: $(head -c 200 "$T/out/T03.err")" \
    bash -c "[ $RC -eq 0 ] && git -C '$T/repos/acme/app.git' rev-parse -q --verify refs/heads/exp004/test >/dev/null"

git -C "$W/ro" commit -q --allow-empty -m "from agent-ro"
run T04 "${ro[@]}" git -C "$W/ro" push origin HEAD:refs/heads/exp004/ro
check T04 "push with agent-ro rejected by host" "exit $RC, host returned 403" "exit $RC, 403 not seen" \
    bash -c "[ $RC -ne 0 ] && grep -q 403 '$T/out/T04.err' && ! git -C '$T/repos/acme/app.git' rev-parse -q --verify refs/heads/exp004/ro >/dev/null"
run T04b "${ro[@]}" env EXP004_ACCESS=write git -C "$W/ro" push origin HEAD:refs/heads/exp004/ro
check T04b "agent-ro asking for write is refused by the issuer (EXP004_ACCESS is not a control)" "exit $RC, issuer: exceeds policy" "exit $RC: $(head -c 200 "$T/out/T04b.err")" \
    rc_fail_with "exceeds policy" T04b

# --- T05-T08: scope, expiry, revocation ---
run T05 "${rw[@]}" git clone "$URL/acme/other.git" "$W/other"
check T05 "clone acme/other with agent-rw refused by issuer, no prompt" "exit $RC, $(grep -o 'not in policy' "$T/out/T05.err" | head -1)" "exit $RC: $(head -c 200 "$T/out/T05.err")" \
    bash -c "[ $RC -ne 0 ] && grep -q 'not in policy' '$T/out/T05.err' && ! grep -qi 'username for' '$T/out/T05.err'"

TOK=$(capture agent-ro read acme/app)
replay T06 "$TOK" ls-remote "$URL/acme/other.git"
check T06 "app token replayed against acme/other -> 404" "exit $RC, host 404 (repo hidden)" "exit $RC, host log lacks 404" \
    rc_fail_host "404 "

TOK=$(capture agent-ro read acme/app)
sleep $((TTL + 1))
replay T07a "$TOK" ls-remote "$URL/acme/app.git"
check T07a "expired token replayed -> 401" "exit $RC, host: 401 token expired" "exit $RC" \
    rc_fail_host "401 token expired"
run T07b "${ro[@]}" git -C "$W/ro" fetch
check T07b "normal helper flow after expiry mints a new token" "exit 0 (new mint per operation)" "exit $RC" rc_ok
if grep -qx erase "$T/replay.log"; then e=yes; else e=no; fi
RC=0; report NOTE T07c "Git called helper erase after 401 on a rejected token" "$e"

TOK=$(capture agent-ro read acme/app)
adm revoke_token "\"token\":\"$TOK\"" >/dev/null
replay T08a "$TOK" ls-remote "$URL/acme/app.git"
check T08a "revoke_token then replay -> 401" "exit $RC, host: 401 token revoked" "exit $RC" \
    rc_fail_host "401 token revoked"
adm revoke_client '"client":"agent-rw"' >/dev/null
git -C "$W/rw" commit -q --allow-empty -m "after revoke"
run T08b "${rww[@]}" git -C "$W/rw" push origin HEAD:refs/heads/exp004/revoked
check T08b "revoke_client agent-rw: helper refuses, push fails" "exit $RC, issuer: client revoked" "exit $RC: $(head -c 200 "$T/out/T08b.err")" \
    rc_fail_with "client revoked" T08b
stop_issuer; start_issuer   # a restart must not reinstate a revoked client
run T08c "${rww[@]}" git -C "$W/rw" push origin HEAD:refs/heads/exp004/revoked
check T08c "revoke_client survives issuer restart" "exit $RC, issuer: client revoked" "exit $RC: $(head -c 200 "$T/out/T08c.err")" \
    rc_fail_with "client revoked" T08c
adm reinstate_client '"client":"agent-rw"' >/dev/null   # so T10 can use agent-rw again

# --- T09: issuer down ---
stop_issuer
run T09 "${ro[@]}" git -C "$W/ro" fetch
check T09 "issuer stopped: fetch fails fast, no hang/prompt" "exit $RC in ${ELAPSED}s, 'issuer unavailable' seen" "exit $RC in ${ELAPSED}s: $(head -c 200 "$T/out/T09.err")" \
    bash -c "[ $RC -ne 0 ] && grep -q 'issuer unavailable' '$T/out/T09.err' && awk 'BEGIN{exit !($ELAPSED < 5)}'"
start_issuer

# --- T10: same-UID agent B ---
run T10 env -i PATH="$PATH" HOME="$HOMEB" GIT_CONFIG_GLOBAL="$HOMEB/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 EXP004_ISSUER_SOCK="$EXP004_ISSUER_SOCK" EXP004_HOST="$EXP004_HOST" \
    EXP004_CLIENT_FILE="$CF/agent-rw.json" EXP004_ACCESS=write \
    bash -c "git clone -q '$URL/acme/app.git' '$W/b' && git -C '$W/b' commit -q --allow-empty -m 'agent B' && git -C '$W/b' push -q origin HEAD:refs/heads/exp004/b"
uids=$(python3 -c '
import json,sys
for l in open(sys.argv[1]):
    if l.startswith("{"):
        d=json.loads(l)
        if d.get("op")=="token" and d.get("client")=="agent-rw" and d["result"]=="ok": print(d["peer"]["uid"], d["peer"]["pid"])
' "$T/logs/issuer.log" | sort -u | awk '{u[$1]=1; p[$2]=1} END{printf "uids=%d pids=%d", length(u), length(p)}')
if [ "$RC" -eq 0 ]; then report LIMITATION T10 "agent B (same UID, other env/HOME) reused agent-rw's client file and pushed" "expected; issuer sees one uid for all callers ($uids)"
else report FAIL T10 "agent B push" "exit $RC: $(head -c 200 "$T/out/T10.err")"; fi

# --- T12 (before the final scan): restart invalidates tokens, nothing persisted ---
OLD=$(capture agent-ro read acme/app)
stop_issuer; start_issuer
reason=$(adm introspect "\"token\":\"$OLD\",\"repo\":\"acme/app\"")
replay T12 "$OLD" ls-remote "$URL/acme/app.git"
persisted=$({ grep -rla ghs_mock_ "$HOME" "$HOMEB" 2>/dev/null || true; } | wc -l)
check T12 "issuer restart: old token invalid, no token-bearing file in HOME" "introspect=$reason; replay exit $RC; files with ghs_mock_ in HOME: $persisted" "introspect=$reason; replay exit $RC; persisted=$persisted" \
    bash -c "[ $RC -ne 0 ] && [ $persisted -eq 0 ] && echo '$reason' | grep -q unknown"

# --- T11: leak scan ---
patterns() {
    python3 -c 'import sys,base64
for t in open(sys.argv[1]).read().split(): print(t); print(base64.b64encode(b"x-access-token:"+t.encode()).decode())' \
        "$EXP004_TEST_RECORD_TOKENS" >"$T/records/patterns.txt"
}
TRACE=$T/trace.txt
env "${ro[@]:1}" GIT_TRACE=1 GIT_TRACE_CURL=1 GIT_TRACE_PACKET=0 git -C "$W/ro" fetch 2>"$TRACE" || true
helper_calls=$(grep -o "git-credential-exp004 [a-z]*" "$TRACE" | sort | uniq -c | tr -s ' ' | tr '\n' ';')
patterns
ntok=$(wc -l <"$EXP004_TEST_RECORD_TOKENS")
hits=$(grep -rlaF -f "$T/records/patterns.txt" -- "$HOME" "$HOMEB" "$W" "$T/repos" "$T/logs" "$T/out" "$T/results.tsv" "$TRACE" 2>/dev/null || true)
for p in "$ISSUER_PID" "$HOST_PID"; do
    grep -qaF -f "$T/records/patterns.txt" "/proc/$p/cmdline" "/proc/$p/environ" 2>/dev/null && hits="$hits /proc/$p"
done
for d in ro rw b; do
    u=$(git -C "$W/$d" remote get-url origin); case $u in *@*) hits="$hits url-with-@:$d" ;; esac
done
if [ -z "$hits" ]; then report PASS T11 "leak scan: $ntok issued tokens not in HOME, worktrees/.git/config, logs, results, GIT_TRACE_CURL trace, issuer/host /proc, remote URLs" "no hits; helper calls seen in trace: $helper_calls"
else report FAIL T11 "leak scan" "hits: $hits"; fi
env "${ro[@]:1}" GIT_TRACE_REDACT=0 GIT_TRACE_CURL=1 git -C "$W/ro" fetch 2>"$TRACE" || true
patterns
if grep -qaF -f "$T/records/patterns.txt" "$TRACE"; then n=yes; else n=no; fi
report NOTE T11b "GIT_TRACE_REDACT=0 trace contains a token (base64 Authorization header)" "$n (expected yes; trace deleted)"
rm -f "$TRACE"

echo "elapsed $(( $(date +%s) - START ))s, results: $T/results.tsv (EXP004_KEEP=1 to keep)"
[ "$FAILS" -eq 0 ] || { echo "FAILURES: $FAILS"; exit 1; }
echo "ALL PASS"
