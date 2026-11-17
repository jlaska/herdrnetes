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

[ "$FAILS" -eq 0 ] || { echo "$FAILS FAILED"; exit 1; }
echo "all passed"
