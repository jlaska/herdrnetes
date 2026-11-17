#!/usr/bin/env bash
# EXP-004 github-backend test, OFFLINE: issuer --backend github against tests/fake_github.py on 127.0.0.1.
# Synthetic RSA key only; never contacts api.github.com. The fake is NOT evidence of real GitHub behavior.
# Usage: tests/run-github-offline.sh   (EXP004_TMP=<dir> temp base, EXP004_KEEP=1 keeps it)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
H=$here/harness
die() { echo "run-github-offline: $*" >&2; exit 1; }
repo_root=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || echo "$here")
base=$(realpath "${EXP004_TMP:-${TMPDIR:-/tmp}}")
case "$base/" in "$repo_root"/*) die "temp dir $base is inside the repository" ;; esac
T=$(mktemp -d -p "$base" exp004gh.XXXXXX)

export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config TMPDIR=$T
mkdir -p "$HOME/.config/exp004" "$T"/{issuer,logs,fakelogs,out,keys}
CF=$HOME/.config/exp004
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false
unset SSH_ASKPASS GH_TOKEN GITHUB_TOKEN GIT_TRACE GIT_TRACE_CURL
SOCKDIR=$(mktemp -d -p "${XDG_RUNTIME_DIR:-$T}" e4.XXXXXX)
export EXP004_ISSUER_SOCK=$SOCKDIR/i.sock EXP004_HOST=github.com
SOCK=$EXP004_ISSUER_SOCK
MYUID=$(id -u)
ISSUER_PID="" FAKE_PID="" FAILS=0
cleanup() {
    kill "$ISSUER_PID" "$FAKE_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    if [ "${EXP004_KEEP:-0}" = 1 ]; then echo "kept $T"; else rm -rf "$T"; fi
    rm -rf "$SOCKDIR"
}
trap cleanup EXIT

rand() { python3 -c 'import secrets; print(secrets.token_hex(16))'; }
sha() { printf %s "$1" | sha256sum | cut -d' ' -f1; }
report() { # <PASS|FAIL> <id> <desc> <observed>
    printf '%s %s %s [%s]\n' "$1" "$2" "$3" "$4"
    if [ "$1" = FAIL ]; then FAILS=$((FAILS + 1)); fi
    return 0
}
check() { # <id> <desc> <ok> <fail> <command...>
    local id=$1 d=$2 okr=$3 failr=$4; shift 4
    if "$@"; then report PASS "$id" "$d" "$okr"; else report FAIL "$id" "$d" "$failr"; fi
}
wait_ready() { for _ in $(seq 50); do python3 -c "$1" 2>/dev/null && return 0; sleep 0.1; done; die "not ready"; }

# --- fixtures: synthetic key, admin secret, client files ---
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$T/keys/app.pem" 2>/dev/null
openssl pkey -in "$T/keys/app.pem" -pubout -out "$T/keys/app.pub" 2>/dev/null
ADMIN=$(rand); printf %s "$ADMIN" >"$T/issuer/admin.secret"; chmod 600 "$T"/issuer/* "$T"/keys/app.pem
declare -A SEC
for c in agent-rw agent-ro probe-b probe-perm; do
    SEC[$c]=$(rand)
    printf '{"client": "%s", "secret": "%s"}' "$c" "${SEC[$c]}" >"$CF/$c.json"
done
chmod 600 "$CF"/*.json

mkpolicy() { # <api port> <extra top-level json fragment, may be empty>
    cat >"$T/issuer/policy.json" <<EOF
{ $2 "ttl_seconds": 3600,
 "github": {"api_url": "http://127.0.0.1:$1", "app_id": "Iv1.synthetic", "owner": "acme",
            "installation_id": 42, "private_key_file": "$T/keys/app.pem"},
 "clients": {
 "agent-rw": {"secret_sha256": "$(sha "${SEC[agent-rw]}")", "repos": {"acme/a": "write"}},
 "agent-ro": {"secret_sha256": "$(sha "${SEC[agent-ro]}")", "repos": {"acme/a": "read"}},
 "probe-b": {"secret_sha256": "$(sha "${SEC[probe-b]}")", "repos": {"acme/b": "read"}},
 "probe-perm": {"secret_sha256": "$(sha "${SEC[probe-perm]}")",
    "repos": {"acme/a": {"permissions": {"contents": "write", "workflows": "write"}}}}}}
EOF
}
start_fake() { # [extra args]
    : >"$T/fakelogs/fake.log"
    python3 "$here/tests/fake_github.py" --port "$PORT" --pub "$T/keys/app.pub" "$@" 2>>"$T/fakelogs/fake.log" &
    FAKE_PID=$!
    wait_ready "import socket; socket.create_connection(('127.0.0.1',$PORT))"
}
stop_fake() { kill "$FAKE_PID" 2>/dev/null || true; wait "$FAKE_PID" 2>/dev/null || true; }
start_issuer() {
    : >"$T/logs/issuer.log"
    python3 "$H/issuer.py" "$SOCK" --policy "$T/issuer/policy.json" --admin-secret "$T/issuer/admin.secret" \
        --state "$T/issuer/revoked.json" --backend github 2>>"$T/logs/issuer.log" &
    ISSUER_PID=$!
    wait_ready "import socket; socket.socket(socket.AF_UNIX).connect('$SOCK')"
}
stop_issuer() { kill "$ISSUER_PID" 2>/dev/null || true; wait "$ISSUER_PID" 2>/dev/null || true; rm -f "$SOCK"; }
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

fake_state() { python3 -c 'import sys,urllib.request; print(urllib.request.urlopen("http://127.0.0.1:%s/__fake/state"%sys.argv[1]).read().decode())' "$PORT"; }
nrev() { fake_state | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(d.values()))'; }
nopen() { fake_state | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(not v for v in d.values()))'; }
ctl() { python3 "$H/issuer-ctl.py" "$SOCK" --admin-secret "$T/issuer/admin.secret" "$@"; }
# helper_get <client> <access> <path>: output (with password masked) to $T/out/last.out, token to $TOK
TOK="" HRC=0 HT=0
helper_get() {
    local t0 raw
    t0=$(date +%s.%N); HRC=0
    raw=$(printf 'protocol=https\nhost=github.com\npath=%s.git\n\n' "$3" |
        env EXP004_CLIENT_FILE="$CF/$1.json" EXP004_ACCESS="$2" "$H/git-credential-exp004" get 2>"$T/out/last.err") || HRC=$?
    HT=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
    TOK=$(printf '%s\n' "$raw" | sed -n 's/^password=//p')
    printf '%s\n' "$raw" | sed 's/^password=.*/password=<present>/' >"$T/out/last.out"
}
shape_ok() { grep -qx 'username=x-access-token' "$T/out/last.out" && grep -qx 'password=<present>' "$T/out/last.out" &&
    grep -q '^password_expiry_utc=[0-9]*$' "$T/out/last.out"; }
fake_has() { grep -q -- "$1" "$T/fakelogs/fake.log"; }
err_has() { grep -q -- "$1" "$T/out/last.err"; }
nreq() { grep -c '"method": "POST"' "$T/fakelogs/fake.log" || true; }

mkpolicy "$PORT" '"client_uids": ['"$MYUID"'],'
start_fake; start_issuer
echo "github offline, fake on 127.0.0.1:$PORT, uid $MYUID"

helper_get agent-ro read acme/a
check G01 "mint read for acme/a via helper" "$(head -c 200 "$T/out/last.out" | tr '\n' ' ')" "rc=$HRC $(head -c 200 "$T/out/last.err")" shape_ok
check G01b "fake saw repositories [a], contents:read+metadata:read" "request body matches" "body mismatch" \
    fake_has '"body": {"repositories": \["a"\], "permissions": {"contents": "read", "metadata": "read"}}'
check G02 "JWT verified by fake (no 401), exp-iat<=600 enforced by fake" "jwt ok logged, 0 bad" "bad jwt seen" \
    bash -c "grep -q '\"jwt\": \"ok\"' '$T/fakelogs/fake.log' && ! grep -q '\"jwt\": \"bad\"' '$T/fakelogs/fake.log'"

N0=$(nreq)
helper_get agent-ro write acme/a
check G03 "agent-ro asking write refused by issuer, no request at fake" "$(cat "$T/out/last.err" | head -c 150)" "rc=$HRC reqs $N0 -> $(nreq)" \
    bash -c "[ $HRC -eq 0 ] && grep -q 'quit=1' '$T/out/last.out' && grep -q 'exceeds policy' '$T/out/last.err' && [ $N0 -eq $(nreq) ]"

helper_get probe-b read acme/b
check G04 "probe-b (repo not in installation): sanitized 422, quit=1" "$(head -c 160 "$T/out/last.err")" "$(head -c 160 "$T/out/last.err")" \
    bash -c "grep -q quit=1 '$T/out/last.out' && grep -q 'github mint failed: HTTP 422' '$T/out/last.err'"
helper_get probe-perm probe acme/a
check G05 "probe-perm (workflows:write ungranted): sanitized 422, quit=1" "$(head -c 160 "$T/out/last.err")" "$(head -c 160 "$T/out/last.err")" \
    bash -c "grep -q quit=1 '$T/out/last.out' && grep -q 'github mint failed: HTTP 422' '$T/out/last.err'"

helper_get agent-rw write acme/a; TOK7=$TOK
check G07 "helper erase -> revoke_own -> fake shows revoked" "open tokens $(nopen) after erase" "erase did not revoke" \
    bash -c "b=\$(python3 -c 'import sys,hashlib;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:8])' '$TOK7')
    printf 'protocol=https\nhost=github.com\npath=acme/a.git\npassword=%s\n\n' '$TOK7' |
      EXP004_CLIENT_FILE='$CF/agent-rw.json' '$H/git-credential-exp004' erase
    python3 -c 'import sys,json,urllib.request;d=json.load(urllib.request.urlopen(\"http://127.0.0.1:$PORT/__fake/state\"));sys.exit(0 if d[sys.argv[1]] else 1)' \$b"

helper_get agent-rw write acme/a; helper_get agent-ro read acme/a
OUT=$(nopen); R=$(ctl revoke_all)
check G08 "revoke_all revokes all $OUT outstanding tokens at fake" "$R; open now $(nopen)" "$R; open now $(nopen)" \
    bash -c "[ $OUT -ge 2 ] && [ \$(echo '$R' | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"revoked\"])') -eq $OUT ] && [ $(nopen) -eq 0 ]"

# G15: revoke_client DELETEs at fake; later mint refused
helper_get agent-rw write acme/a; helper_get agent-rw write acme/a
OUT=$(nopen); R=$(ctl revoke_client --client agent-rw)
helper_get agent-rw write acme/a
check G15 "revoke_client agent-rw: $OUT tokens revoked at fake, new mint refused" "$R; $(head -c 100 "$T/out/last.err")" "$R; open $(nopen)" \
    bash -c "[ $OUT -eq 2 ] && [ $(nopen) -eq 0 ] && echo '$R' | grep -q '\"revoked\": 2, \"failed\": 0' && grep -q 'client revoked' '$T/out/last.err'"
ctl reinstate_client --client agent-rw >/dev/null

# G09: SIGTERM with outstanding tokens
helper_get agent-rw write acme/a; helper_get agent-ro read acme/a
OUT=$(nopen); kill -TERM "$ISSUER_PID"; wait "$ISSUER_PID" 2>/dev/null || true
check G09 "SIGTERM revokes $OUT outstanding tokens (revoke-on-exit)" "open now $(nopen); $(grep -o '"event": "revoke_on_exit".*' "$T/logs/issuer.log")" "open now $(nopen)" \
    bash -c "[ $OUT -eq 2 ] && [ $(nopen) -eq 0 ]"
cp "$T/logs/issuer.log" "$T/logs/issuer-g09.log"; rm -f "$SOCK"

# G11 / G12 / G10 / G06 use fresh issuers
mkpolicy "$PORT" '"client_uids": ['"$((MYUID + 1))"'],'
start_issuer
helper_get agent-rw write acme/a
check G11 "client_uids excluding current uid refused" "$(head -c 120 "$T/out/last.err")" "$(head -c 120 "$T/out/last.err")" \
    bash -c "grep -q 'uid not permitted' '$T/out/last.err' && grep -q quit=1 '$T/out/last.out'"
stop_issuer
mkpolicy "$PORT" '"admin_uids": ['"$((MYUID + 1))"'],'
start_issuer
R=$(ctl revoke_all)
check G12 "admin_uids excluding current uid: admin op refused" "$R" "$R" bash -c "echo '$R' | grep -q 'uid not permitted for admin ops'"
stop_issuer

mkpolicy "$PORT" ''
start_issuer; stop_fake
helper_get agent-rw write acme/a
check G10 "fake down: 'github unreachable', quit=1, ${HT}s (<12s)" "$(head -c 120 "$T/out/last.err")" "$(head -c 120 "$T/out/last.err")" \
    bash -c "grep -q 'github unreachable' '$T/out/last.err' && grep -q quit=1 '$T/out/last.out' && awk 'BEGIN{exit !($HT < 12)}'"

start_fake --misbehave broaden
helper_get agent-rw write acme/a
check G06 "misbehaving fake returns extra repo: issuer refuses, token DELETEd" "$(head -c 120 "$T/out/last.err"); revoked $(nrev)" "revoked $(nrev); $(head -c 120 "$T/out/last.err")" \
    bash -c "grep -q 'broader than requested' '$T/out/last.err' && grep -q quit=1 '$T/out/last.out' && [ $(nrev) -eq 1 ] && grep -q '\"method\": \"DELETE\".*204' '$T/fakelogs/fake.log'"
stop_issuer; stop_fake

# G13 leak scan (fake log excluded: the fake legitimately holds its own state)
leaks() { grep -rEl 'ghs_FAKE|eyJ' "$T/logs" "$HOME" "$T/out" "$T/issuer" 2>/dev/null || true; }
L=$(leaks)
check G13 "no ghs_FAKE token or JWT (eyJ) in issuer logs, HOME, outputs (fake log excluded)" "no matches" "found in: $L" test -z "$L"

# G14 sanitizer unit check
S=$(python3 -I - "$H" <<'EOF'
import sys, importlib.util
sp = importlib.util.spec_from_file_location("issuer", sys.argv[1] + "/issuer.py")
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
out = m.sanitize("bad ghs_abc123DEF_x-y.z token and QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo0MTIzNDU2 end")
print(out)
sys.exit(0 if "ghs_" not in out and "QUJD" not in out and out.count("<redacted>") == 2 else 1)
EOF
) && ok=1 || ok=0
check G14 "sanitizer redacts ghs_ token and 40-char base64 run" "$S" "$S" test "$ok" = 1

# G16 redirects are refused: the JWT must not follow a Location header anywhere
stop_issuer; stop_fake; start_fake --misbehave redirect; start_issuer
helper_get agent-ro read acme/a
followed=$(grep -c followed_redirect "$T/fakelogs/fake.log" || true)
check G16 "redirect from the API is refused, JWT not re-sent" "$(head -c 120 "$T/out/last.err"); followed=$followed" \
    "followed=$followed: $(head -c 160 "$T/out/last.err")" test -z "$TOK" -a "$followed" = 0
# G16c control: a default urllib client does follow this redirect with its Authorization header,
# so G16 would catch a regression (synthetic bearer value).
python3 -I -c 'import sys,urllib.request as u
try: u.urlopen(u.Request("http://127.0.0.1:%s/app/installations/42/access_tokens" % sys.argv[1], data=b"{}", method="POST", headers={"Authorization": "Bearer synthetic"}), timeout=5)
except Exception: pass' "$PORT"
leaked=$(grep -c '"followed_redirect": true, "had_auth": true' "$T/fakelogs/fake.log" || true)
check G16c "control: unguarded urllib follows the redirect carrying Authorization" "followed with auth=$leaked" "followed with auth=$leaked" test "$leaked" -ge 1

# G19 SIGTERM during an in-flight mint: the late token is still revoked before exit
stop_issuer; stop_fake; start_fake --delay 2; start_issuer
helper_get agent-ro read acme/a &
HPID=$!
sleep 0.7
kill -TERM "$ISSUER_PID"; wait "$ISSUER_PID" 2>/dev/null || true; wait "$HPID" 2>/dev/null || true
ex=$(grep -o '"event": "revoke_on_exit"[^}]*' "$T/logs/issuer.log" | tail -1)
check G19 "SIGTERM mid-mint: in-flight token tracked and revoked before exit" "minted=$(fake_state | grep -c :) open=$(nopen); $ex" \
    "open=$(nopen); $ex" test "$(nopen)" = 0 -a "$(fake_state | grep -c :)" -ge 1

# G17/G18 configuration guards: refuse to start (issuer exits non-zero before listening)
stop_issuer
refuses() { # <id> <desc> <python expr editing policy dict p>
    python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1])); exec(sys.argv[2]); json.dump(p, open(sys.argv[1]+".bad","w"))' \
        "$T/issuer/policy.json" "$3"
    local rc=0 err
    err=$(timeout 10 python3 "$H/issuer.py" "$SOCK.bad" --policy "$T/issuer/policy.json.bad" --admin-secret "$T/issuer/admin.secret" \
        --state "$T/issuer/revoked.json" --backend github 2>&1 >/dev/null) || rc=$?
    check "$1" "$2" "exit $rc: $err" "exit $rc (started?)" test "$rc" -ne 0 -a "$rc" -ne 124 -a ! -S "$SOCK.bad"
}
refuses G17 "plain-http api_url to a non-loopback host refused" 'p["github"]["api_url"]="http://api.github.com"'
refuses G18 "policy access value other than read/write refused" 'p["clients"]["agent-rw"]["repos"]["acme/a"]="admin"'

[ "$FAILS" -eq 0 ] || { echo "$FAILS FAILED"; exit 1; }
echo "all passed"
