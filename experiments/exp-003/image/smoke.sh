#!/usr/bin/env bash
# Local (podman, rootless) validation of the EXP-003 Ovis sidecar next to the EXP-002 Herdr image,
# under pod-like constraints: shared pod network namespace, Herdr container read-only/non-root/no caps
# with throwaway volumes, Ovis container read-only rootfs, home and workspace mounted READ-ONLY,
# private emptyDir-like tmpfs, default seccomp, throwaway token.
#
#   smoke.sh <ovis-image> <herdr-image> <workdir>
#
# Prints PASS/FAIL lines; evidence goes to <workdir>/evidence. Never contacts a cluster.
set -uo pipefail
ovis_img=${1:?ovis image} herdr_img=${2:?herdr image} wd=${3:?workdir}
[ -e "$wd" ] && { echo "refusing to reuse $wd" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$wd"/{home,workspace,evidence}; ev="$wd/evidence"
id=$$; pod="exp003-smoke-$id"; nopod="exp003-smoke-nonet-$id"
token="smoke-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
pass() { echo "PASS $*" | tee -a "$ev/results.txt"; }
fail() { echo "FAIL $*" | tee -a "$ev/results.txt"; }
cleanup() { podman pod rm -f "$pod" "$nopod" >/dev/null 2>&1; }
trap cleanup EXIT
userns="--userns=keep-id:uid=1000,gid=1000"

ovis_run() { # <name> <pod> <port> <token> <host> [extra podman args...]  (mirrors deploy/ovis-sidecar-patch.yaml)
  local name=$1 p=$2 port=$3 tok=$4 host=$5; shift 5
  podman run -d --pod "$p" --name "$name" --read-only --cap-drop=ALL --security-opt no-new-privileges \
    --memory 1g --tmpfs /var/lib/ovis:rw,mode=0700,U --tmpfs /tmp:rw,mode=1777,U \
    -v "$wd/home:/home/herdr:ro,z" -v "$wd/workspace:/workspace:ro,z" \
    -e HOST="$host" -e PORT="$port" -e OVIS_TOKEN="$tok" -e OVIS_TELEMETRY=0 -e DO_NOT_TRACK=1 -e OVIS_AUTO_UPDATE=0 \
    -e HERDR_SOCKET=/home/herdr/.config/herdr/herdr.sock -e HERDR_SOCKET_PATH=/home/herdr/.config/herdr/herdr.sock \
    -e OVIS_HERDR_BIN=/usr/local/bin/herdr -e HOME=/var/lib/ovis -e CLAUDE_CONFIG_DIR=/home/herdr/.claude -e CODEX_HOME=/home/herdr/.codex \
    -e OVIS_STATE_DIR=/var/lib/ovis/state -e OVIS_PASTE_DIR=/var/lib/ovis/paste -e XDG_STATE_HOME=/var/lib/ovis/xdg-state \
    -e XDG_CACHE_HOME=/var/lib/ovis/xdg-cache -e TMPDIR=/tmp "$@" "$ovis_img"
}
probe() { podman exec -i "$1" python3 - "${@:2}" <"$HERE/smoke/http_probe.py"; }

podman pod create --name "$pod" "$userns" >/dev/null || { fail "pod create"; exit 1; }
podman run -d --pod "$pod" --name "$pod-herdr" --read-only --cap-drop=ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,mode=1777 --tmpfs /run/herdr:rw,mode=0700,U -v "$wd/home:/home/herdr:z" -v "$wd/workspace:/workspace:z" \
  -e HOME=/home/herdr -e XDG_CONFIG_HOME=/home/herdr/.config -e XDG_STATE_HOME=/run/herdr/state -e XDG_CACHE_HOME=/run/herdr/cache \
  -e TMPDIR=/tmp "$herdr_img" >/dev/null || { fail "herdr start"; exit 1; }
for _ in $(seq 1 100); do podman exec "$pod-herdr" herdr status server >/dev/null 2>&1 && break; sleep 0.1; done
podman exec "$pod-herdr" mkdir -p /workspace/repo-a
podman exec "$pod-herdr" herdr workspace create --cwd /workspace/repo-a --label repo-a >"$ev/workspace-create.json" 2>&1
hpid() { podman exec "$pod-herdr" sh -c 'p=$(pgrep -x herdr | head -1); echo "$p $(cut -d" " -f22 /proc/$p/stat)"'; }
herdr_before=$(hpid)

# 0. Entrypoint refuses unsafe configuration (fail closed).
for case in "empty-token::127.0.0.1" "short-token:short:127.0.0.1" "non-loopback:$token:0.0.0.0"; do
  IFS=: read -r label tok host <<<"$case"
  if podman run --rm --read-only --tmpfs /var/lib/ovis:rw,U -e HOME=/var/lib/ovis -e OVIS_TELEMETRY=0 -e OVIS_TOKEN="$tok" -e HOST="$host" "$userns" "$ovis_img" >"$ev/refuse-$label.log" 2>&1; then
    fail "entrypoint started with $label"; else pass "entrypoint refuses $label"; fi
done

# 1. Start Ovis (loopback, token).
ovis_run "$pod-ovis" "$pod" 7317 "$token" 127.0.0.1 >/dev/null || { fail "ovis start"; exit 1; }
for _ in $(seq 1 100); do
  podman exec "$pod-ovis" python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:7317/api/health', timeout=3).status == 200 else 1)" 2>/dev/null && break; sleep 0.2
done
podman exec "$pod-ovis" python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:7317/api/health', timeout=3).status == 200 else 1)" \
  && pass "readiness probe command succeeds without a token" || fail "readiness probe"

# 2. (a) token required even from loopback; (b) token lists real workspaces/panes.
probe "$pod-ovis" 127.0.0.1 7317 "$token" >"$ev/http-loopback-token-set.txt" 2>&1
grep -q '^session noauth *401' "$ev/http-loopback-token-set.txt" && grep -q '^session badtoken *401' "$ev/http-loopback-token-set.txt" \
  && pass "loopback request without/with wrong token is refused when OVIS_TOKEN is set" || fail "loopback not gated by token"
grep -q "workspaces: \['repo-a'\]" "$ev/http-loopback-token-set.txt" && pass "token: /api/session lists the real workspace and pane" || fail "workspace listing"

# 3. (c) terminal attach through /ws, and the process tree while attached.
podman cp "$HERE/smoke/ws_attach.py" "$pod-ovis:/tmp/ws_attach.py"
podman exec "$pod-ovis" python3 /tmp/ws_attach.py 127.0.0.1 7317 "" w1:p1 >"$ev/ws-noauth.txt" 2>&1
grep -q '401' "$ev/ws-noauth.txt" && pass "/ws without token refused (401)" || fail "/ws without token"
podman exec -e HOLD=6 "$pod-ovis" sh -c "python3 /tmp/ws_attach.py 127.0.0.1 7317 '$token' w1:p1 >/tmp/ws.out 2>&1 & sleep 5; ps -eo pid,ppid,user,args | grep -v 'ps -eo\|grep\|sh -c\|ws_attach' ; wait; cat /tmp/ws.out" >"$ev/ws-attach-and-ps.txt" 2>&1
grep -q 'OVIS_ATTACH_42' "$ev/ws-attach-and-ps.txt" && pass "terminal attach: typed input echoed back through /ws" || fail "terminal attach"
grep -q 'herdr terminal attach' "$ev/ws-attach-and-ps.txt" && pass "ovis spawned 'herdr terminal attach' (ovis-pty-sidecar parent)" || fail "no terminal attach process"

# 4. (d) read-only home/workspace/rootfs; no EROFS in Ovis logs; unix socket connect works on the RO mount.
podman exec "$pod-ovis" sh -c 'touch /home/herdr/x /workspace/x /opt/ovis/x /x 2>&1; grep -E " /home/herdr | /workspace | / " /proc/mounts | cut -d" " -f2,4 | cut -c1-40; id -u; grep CapEff /proc/self/status; grep Seccomp: /proc/self/status' >"$ev/ro-proof.txt" 2>&1
[ "$(grep -c 'Read-only file system' "$ev/ro-proof.txt")" = 4 ] && pass "home, workspace, /opt/ovis and rootfs are read-only for Ovis" || fail "RO proof"
podman exec "$pod-ovis" python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.connect('/home/herdr/.config/herdr/herdr.sock');print('connected')" >"$ev/ro-socket-connect.txt" 2>&1
grep -q connected "$ev/ro-socket-connect.txt" && pass "unix socket connect works through the read-only home mount" || fail "socket connect on RO mount"
podman logs "$pod-ovis" >"$ev/ovis.log" 2>&1
grep -qiE 'erofs|read-only file system' "$ev/ovis.log" && fail "EROFS in Ovis logs" || pass "no EROFS / read-only errors in Ovis logs"
podman exec "$pod-ovis" find /var/lib/ovis -maxdepth 3 >"$ev/ovis-private-writes.txt" 2>&1

# 5. (e) outbound: no non-loopback sockets in the pod netns; whole thing also runs with no network.
podip=$(podman exec "$pod-ovis" python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(("192.0.2.1",9));print(s.getsockname()[0])')
podhex=$(python3 -c "import socket;print(socket.inet_aton('$podip')[::-1].hex().upper())")
podman exec "$pod-ovis" awk -v p="^(0100007F|00000000|$podhex):" 'NR>1 && $3 !~ p {print $2,$3,$4}' /proc/net/tcp >"$ev/foreign-sockets.txt" 2>&1
[ ! -s "$ev/foreign-sockets.txt" ] && pass "no sockets to non-pod addresses in the pod network namespace" || fail "foreign sockets: $(cat "$ev/foreign-sockets.txt")"
podman pod create --name "$nopod" --network none "$userns" >/dev/null
ovis_run "$pod-ovis-nonet" "$nopod" 7317 "$token" 127.0.0.1 >/dev/null
sleep 5
probe "$pod-ovis-nonet" 127.0.0.1 7317 "$token" >"$ev/http-nonet.txt" 2>&1
podman exec "$pod-ovis-nonet" python3 -c "
import urllib.request,sys
try: urllib.request.urlopen('https://api.github.com', timeout=3)
except Exception as e: print('outbound blocked:', type(e).__name__)" >"$ev/nonet-check.txt" 2>&1
grep -q "workspaces: \['repo-a'\]" "$ev/http-nonet.txt" && grep -q blocked "$ev/nonet-check.txt" && pass "Ovis works with --network none (socket + token path needs no network)" || fail "no-network run"

# 6. Update paths: Ovis self-update unmanaged; 'Update herdr' action reachable but contained.
podman exec "$pod-ovis" python3 -c "
import http.client,json
h={'Authorization':'Bearer $token'}
c=http.client.HTTPConnection('127.0.0.1',7317,timeout=10);c.request('GET','/api/updates',headers=h);print(json.dumps({k:v for k,v in json.loads(c.getresponse().read()).items() if k in ('managed','auto_update','available','blocked_reason')}))
h.update({'X-Herdr-Update':'1','Origin':'http://127.0.0.1:7317','Content-Type':'application/json'})
c=http.client.HTTPConnection('127.0.0.1',7317,timeout=10);c.request('POST','/api/updates/install',body=json.dumps({'expected_revision':'0'*40}),headers=h);r=c.getresponse();print('POST /api/updates/install ->',r.status,r.read()[:120])
" >"$ev/ovis-update-paths.txt" 2>&1
grep -q '"managed": false' "$ev/ovis-update-paths.txt" && pass "Ovis self-update is unmanaged under 'serve' (managed=false)" || fail "ovis updates managed?"

# 7. (f) killing/restarting Ovis leaves the Herdr server untouched.
podman kill "$pod-ovis" >/dev/null; sleep 1; podman start "$pod-ovis" >/dev/null; sleep 4
podman restart -t 5 "$pod-ovis" >/dev/null; sleep 4
herdr_after=$(hpid)
[ "$herdr_before" = "$herdr_after" ] && pass "herdr server pid+start time unchanged across Ovis kill/start/restart ($herdr_after)" || fail "herdr server changed: $herdr_before -> $herdr_after"
probe "$pod-ovis" 127.0.0.1 7317 "$token" 2>&1 | grep -q "workspaces: \['repo-a'\]" && pass "Ovis serves the same workspace after restart" || fail "post-restart"

# 8. Control: with NO token the same server is open from loopback AND from the pod IP (documents why OVIS_TOKEN is mandatory).
echo "(the entrypoint refuses an empty token, so this control bypasses it to show raw Ovis behaviour)" >"$ev/notoken-control.txt"
podman run -d --pod "$pod" --name "$pod-ovis-open" --read-only --cap-drop=ALL --tmpfs /var/lib/ovis:rw,mode=0700,U --tmpfs /tmp:rw,U \
  -v "$wd/home:/home/herdr:ro,z" -e HOST=0.0.0.0 -e PORT=7319 -e OVIS_TOKEN= -e OVIS_TELEMETRY=0 -e HOME=/var/lib/ovis -e OVIS_STATE_DIR=/var/lib/ovis/state \
  -e HERDR_SOCKET=/home/herdr/.config/herdr/herdr.sock -e OVIS_HERDR_BIN=/usr/local/bin/herdr --entrypoint /opt/ovis/ovis-server "$ovis_img" serve >/dev/null 2>&1
sleep 5
for h in 127.0.0.1 "$podip"; do echo "-- no-token control, dst $h" >>"$ev/notoken-control.txt"; probe "$pod-ovis" "$h" 7319 >>"$ev/notoken-control.txt" 2>&1; done
grep -q 'session noauth *200' "$ev/notoken-control.txt" && pass "CONTROL: without OVIS_TOKEN the API is open (loopback 'local' and pod-IP 'open')" || fail "control did not show open access"

echo "evidence in $ev"
