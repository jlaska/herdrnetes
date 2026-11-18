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
ADMIN=$(rand); printf %s "$ADMIN" >"$T/issuer/admin.secret"
printf '[]' >"$T/issuer/revoked.json"   # owner step: the issuer refuses a missing state file
chmod 600 "$T"/issuer/* "$T"/keys/app.pem
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
start_issuer() { # [extra issuer args]
    : >"$T/logs/issuer.log"
    python3 "$H/issuer.py" "$SOCK" --policy "$T/issuer/policy.json" --admin-secret "$T/issuer/admin.secret" \
        --state "$T/issuer/revoked.json" --backend github "$@" 2>>"$T/logs/issuer.log" &
    ISSUER_PID=$!
    wait_ready "import socket; socket.socket(socket.AF_UNIX).connect('$SOCK')"
}
stop_issuer() { cat "$T/logs/issuer.log" >>"$T/logs/history.log" 2>/dev/null || true; kill "$ISSUER_PID" 2>/dev/null || true; wait "$ISSUER_PID" 2>/dev/null || true; rm -f "$SOCK"; }
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
OUT=$(nopen); R=$(ctl revoke_all) || true
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
R=$(ctl revoke_all) || true
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

# wait_exit <pid> <max seconds>: sets XRC to the exit status; SIGKILLs and sets 124 on timeout
XRC=0
wait_exit() {
    local i
    for ((i = 0; i < $2 * 10; i++)); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$1" 2>/dev/null; then kill -KILL "$1"; wait "$1" 2>/dev/null || true; XRC=124
    else XRC=0; wait "$1" 2>/dev/null || XRC=$?; fi
}
minted() { fake_state | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }

# G20 (F2): revoke_client lands while a mint is in flight -> the late token is killed, not returned
stop_issuer; stop_fake; start_fake --delay 3; start_issuer
helper_get agent-rw write acme/a &
HPID=$!
sleep 0.7
R=$(ctl revoke_client --client agent-rw) || true; wait "$HPID" 2>/dev/null || true
check G20 "revoke_client mid-mint: helper gets no token, fake has 0 open, late token killed" \
    "minted=$(minted) open=$(nopen); $(grep -o '"event": "late_token_killed"[^}]*' "$T/logs/issuer.log" | head -c 150)" \
    "minted=$(minted) open=$(nopen) out=$(cat "$T/out/last.out") $R" \
    bash -c "[ $(minted) -ge 1 ] && [ $(nopen) -eq 0 ] && ! grep -q '^password=' '$T/out/last.out' && grep -q late_token_killed '$T/logs/issuer.log'"
ctl reinstate_client --client agent-rw >/dev/null

# G21 (F3): SIGTERM during a mint slower than the old 15 s wait: issuer waits, kills the late token, exits 0
stop_issuer; stop_fake; start_fake --delay 20; start_issuer --github-timeout 30 --drain-seconds 75
helper_get agent-ro read acme/a &
HPID=$!
sleep 1; T0=$SECONDS; kill -TERM "$ISSUER_PID"; wait_exit "$ISSUER_PID" 40; D=$((SECONDS - T0)); wait "$HPID" 2>/dev/null || true
check G21 "SIGTERM mid 20 s mint: issuer drains, exit 0 after ${D}s, token revoked, helper got none" \
    "rc=$XRC minted=$(minted) open=$(nopen)" "rc=$XRC minted=$(minted) open=$(nopen) $(tail -c 300 "$T/logs/issuer.log")" \
    bash -c "[ $XRC -eq 0 ] && [ $(minted) -ge 1 ] && [ $(nopen) -eq 0 ] && ! grep -q '^password=' '$T/out/last.out' && [ $D -ge 15 ]"
rm -f "$SOCK"

# G22 (F3): drain deadline passes before the mint returns -> exit 2, CRITICAL + fallback
stop_fake; start_fake --delay 6; start_issuer --drain-seconds 2 --unsafe-short-drain
helper_get agent-ro read acme/a &
HPID=$!
sleep 1; kill -TERM "$ISSUER_PID"; wait_exit "$ISSUER_PID" 20; wait "$HPID" 2>/dev/null || true
check G22 "drain-seconds 2 < mint delay 6: exit 2, CRITICAL + fallback logged" "rc=$XRC" "rc=$XRC $(tail -c 300 "$T/logs/issuer.log")" \
    bash -c "[ $XRC -eq 2 ] && grep -q '\"level\": \"CRITICAL\"' '$T/logs/issuer.log' && grep -q 'uninstall the GitHub App' '$T/logs/issuer.log'"
sleep 6
echo "LIMITATION G22 a token GitHub issues after the issuer has exited cannot be revoked by it [fake shows open=$(nopen) after the delayed mint finished; fallback: uninstall the App installation]"
rm -f "$SOCK"

# G28/G29 (F5/F3): DELETE failing at GitHub is reported, never silent
stop_fake; start_fake --fail-delete; start_issuer
helper_get agent-rw write acme/a; helper_get agent-ro read acme/a
RC28=0; ctl revoke_all >"$T/out/ctl28.out" 2>"$T/out/ctl28.err" || RC28=$?
check G28 "fail-delete: issuer-ctl revoke_all exits 1, REVOCATION INCOMPLETE on stderr, tokens still open" \
    "rc=$RC28 open=$(nopen) $(cat "$T/out/ctl28.out")" "rc=$RC28 open=$(nopen) $(cat "$T/out/ctl28.out" "$T/out/ctl28.err")" \
    bash -c "[ $RC28 -eq 1 ] && grep -q '^REVOCATION INCOMPLETE:' '$T/out/ctl28.err' && [ $(nopen) -ge 2 ] && grep -q '\"ok\": false' '$T/out/ctl28.out'"
kill -TERM "$ISSUER_PID"; wait_exit "$ISSUER_PID" 20
check G29 "fail-delete + SIGTERM: exit 2, CRITICAL logged" "rc=$XRC" "rc=$XRC $(tail -c 300 "$T/logs/issuer.log")" \
    bash -c "[ $XRC -eq 2 ] && grep -q '\"level\": \"CRITICAL\"' '$T/logs/issuer.log'"
rm -f "$SOCK"

# G30 (F5c): broad token + failing DELETE -> the refusal says so
stop_fake; start_fake --fail-delete --misbehave broaden; start_issuer
helper_get agent-rw write acme/a
check G30 "broad token with DELETE failing: helper error says DELETE FAILED" "$(head -c 200 "$T/out/last.err")" "$(head -c 200 "$T/out/last.err")" \
    bash -c "grep -q 'DELETE FAILED: token remains valid until expiry' '$T/out/last.err' && grep -q quit=1 '$T/out/last.out'"
stop_issuer; stop_fake

# G31: normal revoke_all via issuer-ctl exits 0 with ok true
start_fake; start_issuer
helper_get agent-rw write acme/a; helper_get agent-ro read acme/a
RC31=0; R=$(ctl revoke_all) || RC31=$?
check G31 "issuer-ctl revoke_all: exit 0, ok true, no tokens open" "rc=$RC31 $R" "rc=$RC31 $R open=$(nopen)" \
    bash -c "[ $RC31 -eq 0 ] && echo '$R' | grep -q '\"ok\": true' && [ $(nopen) -eq 0 ]"
stop_issuer; stop_fake

# G23-G27 (F4): the state file must exist and be sane, else refuse to start
state_refuses() { # <id> <desc> <state path>
    local rc=0 err
    err=$(timeout 10 python3 "$H/issuer.py" "$SOCK.s" --policy "$T/issuer/policy.json" --admin-secret "$T/issuer/admin.secret" \
        --state "$3" --backend github 2>&1 >/dev/null) || rc=$?
    check "$1" "$2" "exit $rc: $(printf %s "$err" | head -c 110)" "exit $rc (started?)" test "$rc" -ne 0 -a "$rc" -ne 124 -a ! -S "$SOCK.s"
}
state_refuses G23 "missing state file: refuses to start" "$T/issuer/none.json"
printf '{bad' >"$T/issuer/bad.json"; chmod 600 "$T/issuer/bad.json"
state_refuses G24 "corrupt JSON state: refuses to start" "$T/issuer/bad.json"
printf '{"a":1}' >"$T/issuer/obj.json"; chmod 600 "$T/issuer/obj.json"
state_refuses G25 "state is a JSON object, not a list: refuses to start" "$T/issuer/obj.json"
printf '[1]' >"$T/issuer/num.json"; chmod 600 "$T/issuer/num.json"
state_refuses G25b "state list of non-strings: refuses to start" "$T/issuer/num.json"
printf '[]' >"$T/issuer/wide.json"; chmod 666 "$T/issuer/wide.json"
state_refuses G26 "state mode 0666: refuses to start" "$T/issuer/wide.json"
start_fake; start_issuer
ctl revoke_client --client agent-rw >/dev/null; stop_issuer
cp -p "$T/issuer/revoked.json" "$T/issuer/revoked.copy"; rm -f "$T/issuer/revoked.json"
state_refuses G27a "revoked state deleted, restart: refuses (no empty-set start)" "$T/issuer/revoked.json"
cp -p "$T/issuer/revoked.copy" "$T/issuer/revoked.json"; start_issuer
helper_get agent-rw write acme/a
check G27b "state restored from copy: starts, agent-rw still refused" "$(head -c 100 "$T/out/last.err")" "$(head -c 100 "$T/out/last.err")" \
    bash -c "grep -q 'client revoked' '$T/out/last.err' && ! grep -q '^password=' '$T/out/last.out'"
ctl reinstate_client --client agent-rw >/dev/null; stop_issuer; stop_fake

# --- L: ~520-char stateless-style tokens through the real Git smart-HTTP path ---
G=$T/git; WK=$T/work; mkdir -p "$G/acme" "$WK"
git init -q --bare -b main "$G/acme/a.git"
git init -q -b main "$T/seed"
git -C "$T/seed" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m initial
git -C "$T/seed" push -q "$G/acme/a.git" main
cat >"$T/rec-helper" <<EOF
#!/bin/sh
# runs the real helper and records issued tokens (outside every scanned directory) for the leak scan
out=\$("$H/git-credential-exp004" "\$@") || exit \$?
printf '%s\n' "\$out" | sed -n 's/^password=//p' >>"$T/tokens.rec"
printf '%s\n' "\$out"
EOF
chmod 700 "$T/rec-helper"; (umask 077; : >"$T/tokens.rec")
cat >"$HOME/.gitconfig" <<EOF
[credential]
	helper =
	helper = $T/rec-helper
	useHttpPath = true
EOF
start_fake --token-len 520 --git-root "$G"; start_issuer
GURL=http://127.0.0.1:$PORT/acme/a.git
gitc() { env EXP004_HOST=127.0.0.1:"$PORT" EXP004_CLIENT_FILE="$CF/agent-ro.json" git "$@"; }
hget() { # <client> <access>: mint a token via the helper for the git host; token in TOK
    local raw
    raw=$(printf 'protocol=http\nhost=127.0.0.1:%s\npath=acme/a.git\n\n' "$PORT" |
        env EXP004_HOST=127.0.0.1:"$PORT" EXP004_CLIENT_FILE="$CF/$1.json" EXP004_ACCESS="$2" "$H/git-credential-exp004" get 2>/dev/null) || true
    TOK=$(printf '%s\n' "$raw" | sed -n 's/^password=//p')
    printf '%s\n' "$TOK" >>"$T/tokens.rec"
    printf '%s\n' "$raw" | sed 's/^password=.*/password=<present>/' >"$T/out/last.out"
}
replay_git() { # <token>: one-shot helper replays the token from a 0600 file
    (umask 077; printf %s "$1" >"$T/replay.tok")
    env REPLAY_FILE="$T/replay.tok" git -c credential.helper= -c credential.helper="$T/replay-helper" ls-remote "$GURL" >/dev/null 2>&1
}
cat >"$T/replay-helper" <<'EOF'
#!/bin/sh
[ "$1" = get ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$(cat "$REPLAY_FILE")"
EOF
chmod 700 "$T/replay-helper"

hget agent-ro read; LONGTOK=$TOK
check G32 "520-char token via helper: length exactly 520, password_expiry_utc present" "len=${#LONGTOK}; $(tr '\n' ' ' <"$T/out/last.out" | head -c 120)" "len=${#LONGTOK}" \
    bash -c "[ ${#LONGTOK} -eq 520 ] && grep -q '^password_expiry_utc=[0-9]*$' '$T/out/last.out'"
L=0; gitc ls-remote "$GURL" >"$T/out/lsremote.out" 2>"$T/out/lsremote.err" || L=$?
C=0; gitc clone -q "$GURL" "$WK/clone" 2>"$T/out/clone.err" || C=$?
check G33 "real git ls-remote and clone through the helper with 520-char tokens" "ls-remote rc=$L ($(wc -l <"$T/out/lsremote.out") refs), clone rc=$C" \
    "ls-remote rc=$L clone rc=$C $(head -c 200 "$T/out/clone.err")" test "$L" -eq 0 -a "$C" -eq 0 -a -s "$T/out/lsremote.out" -a -d "$WK/clone/.git"
# G34: erase -> revoke_own -> replay of the same long token -> 401 with credentials, git fails
hget agent-rw write; T34=$TOK
printf 'protocol=http\nhost=127.0.0.1:%s\npath=acme/a.git\npassword=%s\n\n' "$PORT" "$T34" |
    env EXP004_HOST=127.0.0.1:"$PORT" EXP004_CLIENT_FILE="$CF/agent-rw.json" "$H/git-credential-exp004" erase
RP=0; replay_git "$T34" || RP=$?
check G34 "helper erase revoked the 520-char token; replay gets 401 (with credentials) and git fails" "git rc=$RP; $(grep -c '"auth": true, "status": 401' "$T/fakelogs/fake.log") authed 401s at fake" "git rc=$RP" \
    bash -c "[ $RP -ne 0 ] && grep -q '\"kind\": \"git\".*\"auth\": true, \"status\": 401' '$T/fakelogs/fake.log'"
# G35: admin revoke_token with the long token on stdin
hget agent-rw write; T35=$TOK; O35=$(nopen)
RP0=0; replay_git "$T35" || RP0=$?   # valid before revocation
RC35=0; R=$(printf '%s\n' "$T35" | ctl revoke_token --token-stdin) || RC35=$?
RP=0; replay_git "$T35" || RP=$?
check G35 "issuer-ctl revoke_token with the 520-char token on stdin: exit 0; replay ok before ($RP0), rejected after" "rc=$RC35 $R; open $O35 -> $(nopen); replay rc=$RP" "rc=$RC35 $R; open $O35 -> $(nopen) replay rc=$RP0/$RP" \
    test "$RC35" -eq 0 -a "$(nopen)" -eq $((O35 - 1)) -a "$RP0" -eq 0 -a "$RP" -ne 0
# G36: both redactors fully remove the long token
S36=$(printf %s "$LONGTOK" | python3 -I -c '
import importlib.util, subprocess, sys
tok = sys.stdin.read()
sp = importlib.util.spec_from_file_location("issuer", sys.argv[1] + "/issuer.py")
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
text = "pre %s mid (%s) Bearer %s end" % (tok, tok, tok)
def clean(out): return not any(tok[i:i + 12] in out for i in range(len(tok) - 11))
a = m.sanitize(text, 100000)
b = subprocess.run(["sed", "-E", "-f", sys.argv[2]], input=text, capture_output=True, text=True).stdout
print("sanitize clean=%s sed clean=%s; sed out: %s" % (clean(a), clean(b), b.strip()[:60]))
sys.exit(0 if clean(a) and clean(b) and "<redacted>" in b else 1)' "$H" "$here/live/redact.sed") && ok=1 || ok=0
check G36 "issuer.sanitize and live/redact.sed both fully redact a 520-char token" "$S36" "$S36" test "$ok" = 1
# G37: leak scan, including a default (unforced) GIT_TRACE/GIT_TRACE_CURL fetch
F37=0; env GIT_TRACE=1 GIT_TRACE_CURL=1 EXP004_HOST=127.0.0.1:"$PORT" EXP004_CLIENT_FILE="$CF/agent-ro.json" git -C "$WK/clone" fetch -q origin 2>"$T/out/trace.log" || F37=$?
stop_issuer
S37=$(python3 -I - "$T/tokens.rec" "$T/logs" "$HOME" "$WK" "$T/out" "$T/issuer" <<'EOF'
import base64, os, sys
toks = {t.strip() for t in open(sys.argv[1]) if len(t.strip()) > 100}
pats = set()
for t in toks:
    for s in (t, base64.b64encode(("x-access-token:" + t).encode()).decode()):
        pats |= {s[i:i + 12].encode() for i in range(len(s) - 11)}
hits, nfiles = [], 0
for root in sys.argv[2:]:
    for d, _, fs in os.walk(root):
        for f in fs:
            nfiles += 1
            data = open(os.path.join(d, f), "rb").read()
            if any(p in data for p in pats):
                hits.append(os.path.relpath(os.path.join(d, f), root))
print("tokens=%d files=%d hits=%s" % (len(toks), nfiles, hits))
sys.exit(1 if hits or not toks else 0)
EOF
) && ok=1 || ok=0
check G37 "no 12+ char substring of any 520-char token (or its Basic b64 form) in issuer log, HOME, worktree, .git/config, trace, outputs" "$S37; fetch rc=$F37" "$S37" test "$ok" = 1
check G37b "default git trace redacts the Authorization header" \
    "$(grep -ci 'authorization: basic <redacted>' "$T/out/trace.log") redacted header lines, none unredacted" "trace has unredacted or no auth header" \
    bash -c "grep -qi 'authorization: basic <redacted>' '$T/out/trace.log' && ! grep -i 'authorization: basic' '$T/out/trace.log' | grep -qvi '<redacted>'"
stop_fake

# --- lead review additions (second review round) ---
start_fake; start_issuer
# G38 one killer per token: erase revokes it, then admin revoke_token and revoke_all must not
# DELETE it again (no spurious 401 "failed") -- and a 401 on DELETE would count as already unusable.
helper_get agent-ro read acme/a
printf 'protocol=https\nhost=github.com\npath=acme/a.git\npassword=%s\n\n' "$TOK" |
    env EXP004_CLIENT_FILE="$CF/agent-ro.json" "$H/git-credential-exp004" erase
R1=$(printf '%s\n' "$TOK" | ctl revoke_token --token-stdin 2>&1) && r1=0 || r1=$?
R2=$(ctl revoke_all 2>&1) && r2=0 || r2=$?
dels=$(grep -c '"method": "DELETE"' "$T/fakelogs/fake.log" || true)
check G38 "revoked token: revoke_token and revoke_all neither re-DELETE nor report failure" "DELETEs=$dels; $R1; $R2" \
    "rc=$r1/$r2 DELETEs=$dels; $R1; $R2" test "$r1" = 0 -a "$r2" = 0 -a "$dels" = 1
# G39 a revocation that cannot be persisted stops ALL minting (fail closed), not just that client
chmod 500 "$T/issuer"
R=$(ctl revoke_client --client agent-rw 2>&1) && r=0 || r=$?
helper_get agent-ro read acme/a
chmod 700 "$T/issuer"
check G39 "state save fails: revoke_client reports ok:false and the issuer refuses every mint" "rc=$r; $(head -c 140 "$T/out/last.err")" \
    "rc=$r $R; $(head -c 160 "$T/out/last.err")" bash -c "[ $r -ne 0 ] && [ -z '$TOK' ] && grep -q 'refuses all mints' '$T/out/last.err'"
stop_issuer
printf '[]' >"$T/issuer/revoked.json"; chmod 600 "$T/issuer/revoked.json"
# G40 the client hangs up before the reply: the undelivered token is killed, not left valid
stop_fake; start_fake --delay 2; start_issuer
python3 -I - "$SOCK" "${SEC[agent-ro]}" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall((json.dumps({"op": "token", "client": "agent-ro", "secret": sys.argv[2], "repo": "acme/a", "access": "read"}) + "\n").encode())
s.close()  # gone before the 2 s mint returns
EOF
sleep 3.5
minted=$(fake_state | grep -o '": ' | wc -l); open=$(nopen)
check G40 "client gone before reply: undelivered token DELETEd" "minted=$minted open=$open; $(grep -o '"event": "undelivered_token_killed"[^}]*' "$T/logs/issuer.log" | tail -1)" \
    "minted=$minted open=$open; $(tail -c 300 "$T/logs/issuer.log")" \
    bash -c "[ $minted -ge 1 ] && [ $open = 0 ] && grep -q '\"undelivered_token_killed\", \"killed\": true' '$T/logs/issuer.log'"
stop_issuer; stop_fake
# G41 drain shorter than the mint budget is refused at start (without the test-only override)
err=$(timeout 10 python3 "$H/issuer.py" "$SOCK.x" --policy "$T/issuer/policy.json" --admin-secret "$T/issuer/admin.secret" \
    --state "$T/issuer/revoked.json" --backend github --drain-seconds 20 2>&1 >/dev/null) && rc=0 || rc=$?
check G41 "drain-seconds below openssl + 2 x github-timeout refused" "exit $rc: ${err##*: }" "exit $rc" test "$rc" -ne 0 -a ! -S "$SOCK.x"

# --- fix A: revocation accounting (third review round) ---
# Invariant: a completed revocation or a successful shutdown never claims all tokens were revoked while
# a revocation is unresolved or failed. Each token has one DELETE owner; every other revoker waits for
# that DELETE's real outcome (bounded by settle_timeout = --github-timeout + 5). Synthetic data only;
# the fake is NOT evidence of real GitHub behavior. Timing assertions use generous slack.
mkpolicy "$PORT" ''
printf '[]' >"$T/issuer/revoked.json"; chmod 600 "$T/issuer/revoked.json"
now() { date +%s.%N; }
dt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
fctl() { python3 -c 'import sys,urllib.request; urllib.request.urlopen("http://127.0.0.1:%s/__fake/ctl?%s" % (sys.argv[1], sys.argv[2])).read()' "$PORT" "$1"; }
arrived() { grep -c '"event": "delete_arrived"' "$T/fakelogs/fake.log" || true; }
ndel() { grep -c '"method": "DELETE"' "$T/fakelogs/fake.log" || true; }
wait_arrived() { local i; for ((i = 0; i < ${2:-100}; i++)); do [ "$(arrived)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
BGP=""
rt_bg() { # <tag> <token>: background `ctl revoke_token`; results in $T/out/<tag>.{out,err,rc,t}
    ( rc=0; s=$(now); printf '%s\n' "$2" | ctl revoke_token --token-stdin >"$T/out/$1.out" 2>"$T/out/$1.err" || rc=$?
      echo "$rc" >"$T/out/$1.rc"; dt "$s" "$(now)" >"$T/out/$1.t" ) &
    BGP="$BGP $!"
}
wait_bg() { wait $BGP 2>/dev/null || true; BGP=""; }
rc_of() { cat "$T/out/$1.rc"; }
exit_log() { grep -o '"event": "revoke_on_exit".*' "$T/logs/issuer.log" | tail -1; }
fix_a() { stop_issuer; stop_fake; start_fake "$@"; start_issuer ${ISS_ARGS:-}; }

# G42: slow DELETE (3 s, succeeds); a second revoke_all starts during it and must wait for it
ISS_ARGS="" fix_a --delete-delay 3
helper_get agent-rw write acme/a; T42=$TOK
rt_bg g42a "$T42"; wait_arrived 1 || true
S=$(now); RC=0; ctl revoke_all >"$T/out/g42b.out" 2>"$T/out/g42b.err" || RC=$?; E=$(dt "$S" "$(now)"); wait_bg
check G42 "slow DELETE: concurrent revoke_all waits for it (${E}s >= 2), exit 0, ok true, revoked 1, exactly 1 DELETE" \
    "rc=$RC ${E}s $(cat "$T/out/g42b.out"); DELETEs=$(ndel)" "rc=$RC ${E}s $(cat "$T/out/g42b.out" "$T/out/g42b.err"); DELETEs=$(ndel); open=$(nopen)" \
    bash -c "[ $RC -eq 0 ] && awk 'BEGIN{exit !($E >= 2)}' && grep -q '\"ok\": true' '$T/out/g42b.out' && grep -q '\"revoked\": 1' '$T/out/g42b.out' && [ $(ndel) -eq 1 ] && [ $(nopen) -eq 0 ]"

# G43: slow DELETE that then FAILS, claimed by revoke_token; concurrent revoke_all and revoke_token
ISS_ARGS="" fix_a
helper_get agent-rw write acme/a; T43=$TOK
fctl 'delete_delay=3&fail_delete=1'
rt_bg g43a "$T43"; wait_arrived 1 || true
rt_bg g43b "$T43"
RC=0; ctl revoke_all >"$T/out/g43c.out" 2>"$T/out/g43c.err" || RC=$?; wait_bg
check G43 "failing slow DELETE: concurrent revoke_all exit 1, ok false, REVOCATION INCOMPLETE (failure never counted as success)" \
    "rc=$RC $(cat "$T/out/g43c.out" | head -c 160); open=$(nopen)" "rc=$RC $(cat "$T/out/g43c.out" "$T/out/g43c.err"); open=$(nopen)" \
    bash -c "[ $RC -eq 1 ] && grep -q '\"ok\": false' '$T/out/g43c.out' && grep -q '\"failed\": 1' '$T/out/g43c.out' && grep -q '^REVOCATION INCOMPLETE:' '$T/out/g43c.err' && [ $(nopen) -eq 1 ]"
check G43b "failing slow DELETE: concurrent revoke_token exit 1 'concurrent revocation failed', owner exit 1, exactly 1 DELETE" \
    "rc=$(rc_of g43b) $(head -c 130 "$T/out/g43b.out"); owner rc=$(rc_of g43a); DELETEs=$(ndel)" \
    "rc=$(rc_of g43b) $(cat "$T/out/g43b.out"); owner rc=$(rc_of g43a); DELETEs=$(ndel)" \
    bash -c "[ $(rc_of g43b) -eq 1 ] && grep -q 'concurrent revocation failed' '$T/out/g43b.out' && ! grep -q '\"revoked\": 1' '$T/out/g43b.out' && [ $(rc_of g43a) -eq 1 ] && [ $(ndel) -eq 1 ]"

# G44: two concurrent revoke_token for the same token (success): both exit 0, one DELETE
ISS_ARGS="" fix_a --delete-delay 2
helper_get agent-rw write acme/a; T44=$TOK
rt_bg g44a "$T44"; rt_bg g44b "$T44"; wait_bg
check G44 "two concurrent revoke_token, same token: both exit 0, exactly 1 DELETE, one says 'revoked by a concurrent request'" \
    "rc=$(rc_of g44a)/$(rc_of g44b); DELETEs=$(ndel); $(cat "$T/out/g44a.out" "$T/out/g44b.out" | tr '\n' ' ')" \
    "rc=$(rc_of g44a)/$(rc_of g44b); DELETEs=$(ndel); $(cat "$T/out/g44a.out" "$T/out/g44b.out" "$T/out/g44a.err" "$T/out/g44b.err")" \
    bash -c "[ $(rc_of g44a) -eq 0 ] && [ $(rc_of g44b) -eq 0 ] && [ $(ndel) -eq 1 ] && [ \$(cat '$T/out/g44a.out' '$T/out/g44b.out' | grep -c 'revoked by a concurrent request') -eq 1 ] && [ $(nopen) -eq 0 ]"

# G45: slow DELETE overlapping SIGTERM (success): shutdown waits for it, exit 0
ISS_ARGS="" fix_a --delete-delay 3
helper_get agent-rw write acme/a; T45=$TOK
rt_bg g45 "$T45"; wait_arrived 1 || true
S=$(now); kill -TERM "$ISSUER_PID"; wait_exit "$ISSUER_PID" 30; E=$(dt "$S" "$(now)"); wait_bg
check G45 "SIGTERM during a slow DELETE (success): exit 0 only after it resolved (${E}s >= 2), open=0, no CRITICAL" \
    "rc=$XRC ${E}s open=$(nopen); $(exit_log)" "rc=$XRC ${E}s open=$(nopen); $(tail -c 400 "$T/logs/issuer.log")" \
    bash -c "[ $XRC -eq 0 ] && awk 'BEGIN{exit !($E >= 2)}' && [ $(nopen) -eq 0 ] && ! grep -q CRITICAL '$T/logs/issuer.log' && grep -q '\"unresolved\": 0.*\"residual\": 0' '$T/logs/issuer.log'"
rm -f "$SOCK"

# G45b: same, but the DELETE fails: exit 2, CRITICAL + fallback
ISS_ARGS="" fix_a --delete-delay 3
helper_get agent-rw write acme/a; T45=$TOK
fctl 'fail_delete=1'
rt_bg g45b "$T45"; wait_arrived 1 || true
S=$(now); kill -TERM "$ISSUER_PID"; wait_exit "$ISSUER_PID" 30; E=$(dt "$S" "$(now)"); wait_bg
check G45b "SIGTERM during a slow DELETE that fails: exit 2, CRITICAL + fallback, token still open (${E}s)" \
    "rc=$XRC ${E}s open=$(nopen)" "rc=$XRC ${E}s open=$(nopen); $(tail -c 400 "$T/logs/issuer.log")" \
    bash -c "[ $XRC -eq 2 ] && awk 'BEGIN{exit !($E >= 2)}' && [ $(nopen) -eq 1 ] && grep -q '\"level\": \"CRITICAL\"' '$T/logs/issuer.log' && grep -q 'uninstall the GitHub App' '$T/logs/issuer.log' && grep -q '\"failed\": 1' '$T/logs/issuer.log'"
rm -f "$SOCK"

# G46: the DELETE times out (github-timeout 2, fake answers after 10 s) while shutdown waits
ISS_ARGS="--github-timeout 2 --drain-seconds 14" fix_a --delete-delay 10
helper_get agent-rw write acme/a; T46=$TOK
rt_bg g46 "$T46"; wait_arrived 1 || true
S=$(now); kill -TERM "$ISSUER_PID"; wait_exit "$ISSUER_PID" 40; E=$(dt "$S" "$(now)"); wait_bg
check G46 "DELETE timing out during shutdown: exit 2, CRITICAL, bounded (${E}s < 30), never exit 0" \
    "rc=$XRC ${E}s; $(exit_log | head -c 200)" "rc=$XRC ${E}s; $(tail -c 400 "$T/logs/issuer.log")" \
    bash -c "[ $XRC -eq 2 ] && awk 'BEGIN{exit !($E < 30)}' && grep -q '\"level\": \"CRITICAL\"' '$T/logs/issuer.log'"
rm -f "$SOCK"

# G47: an unresolved network operation (trickled DELETE outlives the per-socket timeout) + SIGTERM
ISS_ARGS="--github-timeout 2 --drain-seconds 14" fix_a
helper_get agent-rw write acme/a
fctl 'delete_trickle=1'
S=$(now); kill -TERM "$ISSUER_PID"; wait_exit "$ISSUER_PID" 40; E=$(dt "$S" "$(now)")
check G47 "trickled DELETE + SIGTERM: exit 2 within ~settle_timeout (${E}s, 7 expected), log shows unresolved >= 1, never exit 0" \
    "rc=$XRC ${E}s open=$(nopen); $(exit_log | head -c 160)" "rc=$XRC ${E}s open=$(nopen); $(tail -c 400 "$T/logs/issuer.log")" \
    bash -c "[ $XRC -eq 2 ] && awk 'BEGIN{exit !($E >= 5 && $E < 15)}' && [ $(nopen) -eq 1 ] && grep -Eq '\"unresolved\": [1-9]' '$T/logs/issuer.log' && grep -q '\"level\": \"CRITICAL\"' '$T/logs/issuer.log' && grep -q '\"ok\": false' '$T/logs/issuer.log'"
rm -f "$SOCK"

# G48: concurrent revocations all succeed, then SIGTERM: clean exit, nothing residual
ISS_ARGS="" fix_a --delete-delay 1
helper_get agent-rw write acme/a; TA=$TOK; helper_get agent-ro read acme/a; TB=$TOK; helper_get agent-rw write acme/a   # third token stays unrevoked until shutdown
rt_bg g48a "$TA"; rt_bg g48a2 "$TA"; rt_bg g48b "$TB"
RC=0; ctl revoke_all >"$T/out/g48c.out" 2>&1 || RC=$?; wait_bg
kill -TERM "$ISSUER_PID"; wait_exit "$ISSUER_PID" 30
check G48 "concurrent revocations then SIGTERM: exit 0, revoke_on_exit ok true, failed 0, unresolved 0, residual 0, open=0" \
    "rc=$XRC revoke_all rc=$RC; open=$(nopen); $(exit_log | head -c 170)" "rc=$XRC revoke_all rc=$RC $(cat "$T/out/g48c.out"); open=$(nopen); $(tail -c 400 "$T/logs/issuer.log")" \
    bash -c "[ $XRC -eq 0 ] && [ $RC -eq 0 ] && [ $(nopen) -eq 0 ] && [ \$(cat $T/out/g48a.rc $T/out/g48a2.rc $T/out/g48b.rc | sort -u) = 0 ] && grep '\"event\": \"revoke_on_exit\"' '$T/logs/issuer.log' | grep -q '\"ok\": true' && grep '\"event\": \"revoke_on_exit\"' '$T/logs/issuer.log' | grep -q '\"failed\": 0, \"unresolved\": 0' && grep '\"event\": \"revoke_on_exit\"' '$T/logs/issuer.log' | grep -q '\"residual\": 0' && ! grep -q CRITICAL '$T/logs/issuer.log'"
rm -f "$SOCK"

# G49: a revoked token is rejected by the fake's Git smart-HTTP route after a concurrent revocation
stop_issuer; stop_fake; start_fake --delete-delay 2 --git-root "$G"; start_issuer
hget agent-rw write; T49=$TOK
RP0=0; replay_git "$T49" || RP0=$?
rt_bg g49a "$T49"; rt_bg g49b "$T49"; wait_bg
RP1=0; replay_git "$T49" || RP1=$?
hget agent-rw write; T49b=$TOK; RP2=0; replay_git "$T49b" || RP2=$?
check G49 "git replay: token valid before (rc $RP0), rejected with 401 after concurrent revoke (rc $RP1); the new token differs and works (rc $RP2)" \
    "rc=$(rc_of g49a)/$(rc_of g49b) DELETEs=$(ndel); replay before/after/new=$RP0/$RP1/$RP2; $(grep -c '"kind": "git".*"auth": true, "status": 401' "$T/fakelogs/fake.log") authed 401s" \
    "rc=$(rc_of g49a)/$(rc_of g49b) DELETEs=$(ndel); replay before/after/new=$RP0/$RP1/$RP2" \
    bash -c "[ $RP0 -eq 0 ] && [ $RP1 -ne 0 ] && [ $RP2 -eq 0 ] && [ '$T49' != '$T49b' ] && [ $(rc_of g49a) -eq 0 ] && [ $(rc_of g49b) -eq 0 ] && [ $(ndel) -eq 1 ] && grep -q '\"kind\": \"git\".*\"auth\": true, \"status\": 401' '$T/fakelogs/fake.log'"
printf '%s\n' "$T49b" | ctl revoke_token --token-stdin >/dev/null || true

# G50: SIGKILL while a DELETE is pending. Documented LIMITATION (like G22), not a pass/fail claim
ISS_ARGS="" fix_a --delete-delay 5
helper_get agent-rw write acme/a; T50=$TOK
rt_bg g50 "$T50"; wait_arrived 1 || true
kill -KILL "$ISSUER_PID"; wait_exit "$ISSUER_PID" 10; wait_bg
if [ "$XRC" -eq 137 ] && ! grep -q '"event": "revoke_on_exit"' "$T/logs/issuer.log"; then
    echo "LIMITATION G50 SIGKILL with a DELETE pending: issuer exit $XRC, no revoke_on_exit line, so nothing was reported as revoked [fake open=$(nopen) right after the kill; the fake may still complete the in-flight DELETE; real GitHub tokens stay valid until expiry <= 1 h; fallback: uninstall the App installation]"
else
    report FAIL G50 "SIGKILL with a DELETE pending: unexpected exit or a revoke_on_exit line" "rc=$XRC $(tail -c 300 "$T/logs/issuer.log")"
fi
rm -f "$SOCK"

# G51: revoke_client overlapping a pending revoke_token of that client's token reflects the real outcome
ISS_ARGS="" fix_a --delete-delay 3
helper_get agent-rw write acme/a; T51=$TOK
fctl 'fail_delete=1'
rt_bg g51a "$T51"; wait_arrived 1 || true
RC=0; ctl revoke_client --client agent-rw >"$T/out/g51.out" 2>"$T/out/g51.err" || RC=$?; wait_bg
check G51 "revoke_client during a pending revoke_token that FAILS: exit 1, ok false, failed 1, token still open" \
    "rc=$RC $(head -c 120 "$T/out/g51.out"); open=$(nopen)" "rc=$RC $(cat "$T/out/g51.out" "$T/out/g51.err"); open=$(nopen)" \
    bash -c "[ $RC -eq 1 ] && grep -q '\"ok\": false' '$T/out/g51.out' && grep -q '\"failed\": 1' '$T/out/g51.out' && grep -q '^REVOCATION INCOMPLETE' '$T/out/g51.err' && [ $(nopen) -eq 1 ] && [ $(ndel) -eq 1 ]"
ctl reinstate_client --client agent-rw >/dev/null
ISS_ARGS="" fix_a --delete-delay 3
helper_get agent-rw write acme/a; T51=$TOK
rt_bg g51b "$T51"; wait_arrived 1 || true
RC=0; ctl revoke_client --client agent-rw >"$T/out/g51s.out" 2>"$T/out/g51s.err" || RC=$?; wait_bg
check G51b "revoke_client during a pending revoke_token that succeeds: exit 0, ok true, revoked 1, one DELETE, open=0" \
    "rc=$RC $(head -c 120 "$T/out/g51s.out"); open=$(nopen) DELETEs=$(ndel)" "rc=$RC $(cat "$T/out/g51s.out" "$T/out/g51s.err"); open=$(nopen) DELETEs=$(ndel)" \
    bash -c "[ $RC -eq 0 ] && grep -q '\"ok\": true' '$T/out/g51s.out' && grep -q '\"revoked\": 1' '$T/out/g51s.out' && [ $(nopen) -eq 0 ] && [ $(ndel) -eq 1 ]"
ctl reinstate_client --client agent-rw >/dev/null
stop_issuer; stop_fake

# G42u: deterministic unit tests of the token state machine (no sleeps for ordering)
URC=0; python3 -I "$here/tests/test_issuer_state.py" >"$T/out/unit.out" 2>&1 || URC=$?
check G42u "tests/test_issuer_state.py (RevocationAccounting, deterministic): $(grep -E '^Ran ' "$T/out/unit.out")" "$(tail -1 "$T/out/unit.out")" "rc=$URC $(tail -20 "$T/out/unit.out")" test "$URC" -eq 0
# --- fix B: reinstate_client persistence (third review round) ---
# A client must not regain authorization unless the reinstatement is durably committed. Self-contained.
reset_state() { chmod 700 "$T/issuer"; printf '[]' >"$T/issuer/revoked.json"; chmod 600 "$T/issuer/revoked.json"; }
reset_state
python3 -I "$here/tests/test_issuer_state.py" ReinstatePersistence -v >"$T/out/g60u.out" 2>&1 && u=0 || u=$?
check G60u "unit: ReinstatePersistence (failed save, atomic publish, recover_state, revoke/reinstate race)" "$(tail -3 "$T/out/g60u.out" | tr '\n' ' ')" \
    "rc=$u $(tail -c 400 "$T/out/g60u.out")" test "$u" = 0
start_fake; start_issuer
R=$(ctl revoke_client --client agent-rw 2>&1) && r=0 || r=$?
helper_get agent-rw write acme/a
check G60 "revoked client cannot mint" "rc=$r; $(head -c 100 "$T/out/last.err")" "rc=$r; tok='$TOK' $(head -c 160 "$T/out/last.err")" \
    bash -c "[ $r -eq 0 ] && [ -z '$TOK' ] && grep -q 'client revoked' '$T/out/last.err'"
R=$(ctl reinstate_client --client agent-rw 2>&1) && r=0 || r=$?
stop_issuer; start_issuer
helper_get agent-rw write acme/a
check G61 "reinstated client: file no longer lists it; mints after issuer restart" "rc=$r; file=$(cat "$T/issuer/revoked.json"); minted" \
    "rc=$r $R; file=$(cat "$T/issuer/revoked.json"); $(head -c 120 "$T/out/last.err")" \
    bash -c "[ $r -eq 0 ] && ! grep -q agent-rw '$T/issuer/revoked.json' && [ -n '$TOK' ]"
ctl revoke_client --client agent-rw >/dev/null 2>&1 || true
chmod 500 "$T/issuer"
R=$(ctl reinstate_client --client agent-rw 2>&1) && r=0 || r=$?
helper_get agent-rw write acme/a; T62=$TOK
check G62 "failed reinstatement persistence: ctl exits 1 with actionable message; client still refused" "rc=$r; ${R:0:150}" \
    "rc=$r $R; tok='$T62' $(head -c 120 "$T/out/last.err")" \
    bash -c "[ $r -eq 1 ] && [ -z '$T62' ] && grep -q 'reinstatement NOT persisted' <<<'$R' && grep -q 'remains revoked' <<<'$R'"
helper_get agent-ro read acme/a
check G63 "fail-closed after failed reinstatement: agent-ro cannot mint either" "$(head -c 120 "$T/out/last.err")" \
    "tok='$TOK' $(head -c 160 "$T/out/last.err")" bash -c "[ -z '$TOK' ] && grep -q 'refuses all mints' '$T/out/last.err'"
R=$(ctl reinstate_client --client agent-rw 2>&1) && r=0 || r=$?
check G64 "reinstate_client while state is broken is refused" "rc=$r; ${R:0:150}" "rc=$r $R" \
    bash -c "[ $r -eq 1 ] && grep -q 'run recover_state first' <<<'$R'"
R=$(ctl recover_state 2>&1) && r=0 || r=$?
helper_get agent-ro read acme/a
check G67 "recover_state while the dir is still unwritable: exit 1, minting stays refused" "rc=$r; ${R:0:120}" "rc=$r $R; tok='$TOK'" \
    bash -c "[ $r -eq 1 ] && grep -q 'recovery save failed' <<<'$R' && [ -z '$TOK' ] && grep -q 'refuses all mints' '$T/out/last.err'"
chmod 700 "$T/issuer"
R=$(ctl recover_state 2>&1) && r=0 || r=$?
helper_get agent-ro read acme/a; TOKRO=$TOK
helper_get agent-rw write acme/a; TOKRW=$TOK; ERRRW=$(head -c 100 "$T/out/last.err")
R2=$(ctl reinstate_client --client agent-rw 2>&1) && r2=0 || r2=$?
helper_get agent-rw write acme/a
check G65 "recover_state: exit 0, agent-ro mints, failed reinstatement NOT applied, fresh reinstate then mints" \
    "rc=$r; ${R:0:80}; ro minted; rw refused ($ERRRW); reinstate rc=$r2; rw minted" \
    "rc=$r $R; ro='${TOKRO:+minted}' rw-before='${TOKRW:+minted}' reinstate rc=$r2 rw-after='${TOK:+minted}'" \
    bash -c "[ $r -eq 0 ] && grep -q '\"recovered\": 1' <<<'$R' && [ -n '$TOKRO' ] && [ -z '$TOKRW' ] && [ $r2 -eq 0 ] && [ -n '$TOK' ]"
ctl revoke_client --client agent-rw >/dev/null 2>&1 || true
chmod 500 "$T/issuer"
ctl reinstate_client --client agent-rw >/dev/null 2>&1 || true   # fails: broken, client still revoked
stop_issuer
chmod 700 "$T/issuer"
start_issuer
helper_get agent-rw write acme/a
check G66 "restart after failed reinstatement (no recover): file still lists the client, still refused" \
    "file=$(cat "$T/issuer/revoked.json"); $(head -c 80 "$T/out/last.err")" "file=$(cat "$T/issuer/revoked.json"); tok='$TOK'" \
    bash -c "grep -q agent-rw '$T/issuer/revoked.json' && [ -z '$TOK' ] && grep -q 'client revoked' '$T/out/last.err'"
stop_issuer; stop_fake
reset_state

[ "$FAILS" -eq 0 ] || { echo "$FAILS FAILED"; exit 1; }
echo "all passed"
