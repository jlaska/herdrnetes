#!/usr/bin/env bash
# EXP-008 stage A local harness: can an OpenShell sandbox's canonical main
# process play the role tmux played in EXP-006? Herdr panes are disposable
# `openshell sandbox connect` clients; the gateway owns the session.
#
#   experiments/exp-008/local/demo.sh <RUN>
#
# Procedure: experiments/exp-008/local/PLAN.md (P3, A1-A7, C, stop conditions)
# plus the pre-registered corrections listed in the README. Runs exactly once.
# Everything lives under /tmp/hx8/<RUN>/e: a dedicated rootless Podman service
# and store, a loopback mTLS OpenShell gateway, and a disposable Herdr 0.9.5.
# Nothing here addresses the operator's live Herdr, OpenShell config/state,
# default Podman store, ssh/gpg agents or git. <RUN> must already exist with
# the two verified binaries (created by preflight); the whole run root is
# removed by the cleanup trap after evidence has been copied out.
# shellcheck disable=SC2329 # most functions are invoked indirectly (EXIT trap, `p3 <item> <fn>`, poll/wait_for "$@")
set -u
set -o pipefail
unset SSH_AUTH_SOCK
umask 077

# ------------------------------------------------------------ fixed inputs
HERE=$(cd "$(dirname "$0")" && pwd)
refuse() { echo "REFUSE: $*" >&2; exit 2; }
[ "$#" -eq 1 ] || refuse "usage: demo.sh <RUN>"
RUN=$1
[[ $RUN =~ ^[0-9A-Za-z][0-9A-Za-z_-]{0,30}$ ]] || refuse "bad run id '$RUN'"
HERDR_BIN=${HERDR_BIN:-$(command -v herdr || true)}
PATH=/usr/bin:/bin # the controller only ever uses system tools (jq/curl: /usr/bin)
export PATH
SCRATCH=/tmp/hx8
ROOT=$SCRATCH/$RUN
E=$ROOT/e
EVID=$HERE/evidence/$RUN
PORT=${PORT:-21123}
GW=exp008-$RUN # gateway name == CLI registration == sandbox name == podman network
WORKLOAD=ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16
RT_IMG=ghcr.io/nvidia/openshell/sandbox@sha256:e57d07cd6cc1fc314b80368d6b51ec6fbf825fb62cd8f081312941180846866f
SUP_IMG=ghcr.io/nvidia/openshell/supervisor@sha256:f1ec231b5dbe5b6a40c33acb2ac847995aabb959a56134ef6d7d7aa4f43199d3
CLI_BIN=$ROOT/bin/cli/openshell
GW_BIN=$ROOT/bin/gw/openshell-gateway
CLI_SHA=2db8e54f63feebe9f994efaf6004bbd45c55bc70ea455eda42fe82a0ea7c7e69
GW_SHA=865e8c5ae15a599ca001d023efc137527ff8e102b0cccb90a85184a1c6e33978
BUDGET=1800 # seconds from script start (PLAN stop condition)
OUTDIR=/sandbox/out
JQ=/usr/bin/jq
SS=/usr/bin/ss
CURL=/usr/bin/curl
PODMAN=/usr/bin/podman
UID_=$(id -u)
USER_=$(id -un)
HOST_=$(hostname 2>/dev/null || true)
SECONDS=0

# Refusals: nothing has been created yet, so exit 2 touches nothing.
for t in awk sed grep tr od sort find stat readlink realpath timeout setsid sha256sum ps jq curl podman ssh \
  systemctl getconf cat date head tail wc mkdir rm cp cmp diff cut sleep tee id printenv ss; do
  command -v "$t" >/dev/null 2>&1 || refuse "missing tool: $t"
done
[ "$(command -v jq)" = "$JQ" ] && [ "$(command -v ss)" = "$SS" ] && [ "$(command -v podman)" = "$PODMAN" ] || refuse "jq/ss/podman must be the /usr/bin ones"
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || refuse "herdr not found (set HERDR_BIN)"
[ -d "$SCRATCH" ] && [ ! -L "$SCRATCH" ] && [ "$(stat -c %u "$SCRATCH")" = "$UID_" ] || refuse "$SCRATCH missing, a symlink or not ours"
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || refuse "$ROOT missing or a symlink"
[ "$(stat -c %u "$ROOT")" = "$UID_" ] && [ "$(stat -c %a "$ROOT")" = 700 ] || refuse "$ROOT not owned by us with mode 0700"
[ "$(realpath -e "$ROOT")" = "$ROOT" ] || refuse "$ROOT is not canonical"
for f in "$CLI_BIN:$CLI_SHA" "$GW_BIN:$GW_SHA"; do
  [ -f "${f%%:*}" ] && [ ! -L "${f%%:*}" ] && [ -x "${f%%:*}" ] || refuse "${f%%:*} missing, a symlink or not executable"
  [ "$(sha256sum "${f%%:*}" | cut -d' ' -f1)" = "${f##*:}" ] || refuse "sha256 mismatch: ${f%%:*}"
done
[ ! -e "$E" ] && [ ! -L "$E" ] || refuse "$E already exists (single attempt: never reuse)"
[ ! -e "$EVID" ] || refuse "$EVID already exists"
[ "${#E}" -le 60 ] || refuse "run path too long for sockets (sun_path)"
[[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || refuse "bad PORT"
[ "$PORT" != 17670 ] || refuse "PORT 17670 is the default gateway port; use another"
[ -z "$("$SS" -Htln "sport = :$PORT" 2>/dev/null)" ] || refuse "port $PORT is already listening"
[ -S "/run/user/$UID_/bus" ] || refuse "no user D-Bus at /run/user/$UID_/bus (needed for the systemd cgroup manager)"
CLI_REAL=$(realpath -e "$CLI_BIN")
GW_REAL=$(realpath -e "$GW_BIN")
PROCFS=/proc # client detection reads processes here (tests/clients-test.sh points it at a fake tree)

# Sed-escaped strings for redact (ERE; '#' is the sed delimiter).
# shellcheck disable=SC2001 # needs a bracket-expression class; ${var//..//..} cannot express it
rx() { sed 's/[][\.*^$#+?(){}|]/\\&/g' <<<"$1"; }
RX_HOME=$(rx "$HOME")
RX_USER=$(rx "$USER_")
HOST_SED=()
[ -n "$HOST_" ] && HOST_SED=(-e "s#$(rx "$HOST_")#HOST#g")

# ------------------------------------------------------------------- state
# Every global the cleanup trap reads is initialised here, before anything can fail.
RESULTS=$E/results.tsv
TIMELINE=$E/timeline.log
PIDS=()   # "label:pid:starttime" for every process we must verify gone at exit
SWEPT=()  # stragglers found (and signalled) by the sweep
LAST_TRACK=
WD_ENTRY=
PS_PID=
PS_ENTRY=
PSL_ENTRY=
GWPID=
GWSTART=
GW_COUNT=0
HERDR_PID=
HERDR_START=
GUARD_OK=0
CLEANING=0
OWN_E=0
MAIN_DONE=0
RC=0
SBX_ID=
CID=
WPID=
HPIDC=
HSTARTC=
CPID=
CSTART=
CNONCE=
CREATE_PID=
CREATE_START=
PANE=
PSHELL=
ATT=
declare -A PANE_CLIENT=() # pane id -> "cli:start ssh:start proxy:start" of the client attached in it
PLANNED="A1 A6 A7a A5a A5b A7b" # run 4 order; cleanup records NOT-RUN for any without a row
CLS=CLEAN
EVBAD=0
ROOT_GONE=unknown
CL_LOG=$E/cleanup.txt # becomes $EVID/cleanup-final.txt for the post-removal verification
CLS_INTERMEDIATE=
declare -A REF1=() REF0=()
BASE_FILES=(openshell-config.txt openshell-state.txt ssh-meta.txt listeners.txt podman-default.txt systemd-units.txt)

# ------------------------------------------------------------ environment
# Allowlisted environment for EVERYTHING we launch. No SSH_AUTH_SOCK, no
# GNUPGHOME, no DBUS_SESSION_BUS_ADDRESS (except the podman service), no
# OPENSHELL_* or HERDR_* from the controller.
CENV_VARS=("HOME=$E/home" "USER=$USER_" "LOGNAME=$USER_" "PATH=$E/wrap:/usr/bin:/bin" "LANG=C.UTF-8"
  "TERM=xterm-256color" "SHELL=/usr/bin/bash" "XDG_CONFIG_HOME=$E/config" "XDG_STATE_HOME=$E/state"
  "XDG_DATA_HOME=$E/data" "XDG_RUNTIME_DIR=$E/run" "OPENSHELL_SYSTEM_GATEWAY_DIR=$E/etc-openshell")
cenv() { env -i "${CENV_VARS[@]}" "$@"; }
tcenv() { local t=$1; shift; timeout -k 5 "$t" env -i "${CENV_VARS[@]}" "$@"; } # bounded
Hraw() { tcenv 30 "$HERDR_BIN" "$@"; }
H() { # every herdr call except read-only ones: refuse unless the guard verified our socket
  if [ "$GUARD_OK" != 1 ]; then echo "GUARD not verified; refusing herdr $*" >&2; return 99; fi
  Hraw "$@"
}
# Owner-approved correction (retry): the driver gives its containers a 10 s healthconfig interval, and
# rootless Podman would add systemd healthcheck timers through $XDG_RUNTIME_DIR/systemd/private, which
# the isolated runtime dir does not have. Only the dedicated service and our own podman calls get this.
PENV=("DISABLE_HC_SYSTEMD=true")
P() { tcenv "${PT:-120}" "${PENV[@]}" "$PODMAN" --url "unix://$E/podman.sock" "$@"; } # the dedicated service only
O() { tcenv "${OT:-60}" "$E/wrap/openshell" -g "$GW" "$@"; }             # through the guard wrapper
# Read-only listing of the owner's DEFAULT store, for the protected baseline only.
PD() { timeout -k 5 60 env -u SSH_AUTH_SOCK "$PODMAN" "$@"; }

guard() {
  local sock
  GUARD_OK=0
  sock=$(Hraw session list --json 2>/dev/null | "$JQ" -r '.sessions[]|select(.default)|.socket_path')
  case "$sock" in
  "$E"/*) GUARD_OK=1 ;;
  *) echo "GUARD: herdr socket '$sock' is outside $E; aborting" >&2; return 1 ;;
  esac
}

# ------------------------------------------------------------------ helpers
log() { printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$*" | tee -a "$TIMELINE"; }

# poll <timeout-s> <interval-s> <cmd...>: every wait in this script is bounded
poll() {
  local end=$((SECONDS + $1)) iv=$2
  shift 2
  while :; do
    "$@" && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep "$iv"
  done
}
wait_for() { local t=$1; shift; poll "$t" 0.2 "$@"; }

proc_start() { # field 22 of /proc/<pid>/stat; empty if there is no such process
  local s a
  case ${1:-} in '' | *[!0-9]*) return 0 ;; esac
  read -r s 2>/dev/null <"/proc/$1/stat" || return 0
  read -ra a <<<"${s##*) }" # strip "pid (comm) " so a comm with spaces cannot shift fields
  echo "${a[19]:-}"
}
ppid_of() {
  local s a
  case ${1:-} in '' | *[!0-9]*) return 0 ;; esac
  read -r s 2>/dev/null <"/proc/$1/stat" || return 0
  read -ra a <<<"${s##*) }"
  echo "${a[1]:-}"
}
proc_comm() { local c; case ${1:-} in '' | *[!0-9]*) return 0 ;; esac; read -r c 2>/dev/null <"/proc/$1/comm" && echo "$c"; }
proc_cmd() { case ${1:-} in '' | *[!0-9]*) return 0 ;; esac; tr '\0' ' ' 2>/dev/null <"/proc/$1/cmdline"; }
# proc_env_has <pid> <KEY=VAL>...: any exact line present in the process environment
proc_env_has() {
  local pid=$1 a=() w
  shift
  for w in "$@"; do a+=(-e "$w"); done
  tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ" | grep -xF "${a[@]}" >/dev/null
}
alive_same() { [ -n "${2:-}" ] && [ "$(proc_start "${1:-}")" = "$2" ]; } # pid, starttime
gone() { # pid, starttime: gone, or the pid was recycled
  local s
  s=$(proc_start "${1:-}")
  [ -z "$s" ] || [ "$s" != "${2:-}" ]
}

track() { # track <label> <pid>: remember pid+starttime; sets LAST_TRACK
  local e
  LAST_TRACK="$1:$2:$(proc_start "$2")"
  for e in "${PIDS[@]}"; do [ "$e" = "$LAST_TRACK" ] && return 0; done
  PIDS+=("$LAST_TRACK")
}
# sig <signal> <label:pid:start>: the ONLY way this script signals a process.
# Refuses unless /proc/<pid>/stat field 22 still equals the recorded start time.
sig() {
  local s=$1 label pid st
  IFS=: read -r label pid st <<<"$2"
  case $pid in '' | *[!0-9]*) return 1 ;; esac
  [ -n "$st" ] && [ "$pid" -gt 1 ] && [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ] || return 1
  alive_same "$pid" "$st" || return 1
  kill -"$s" "$pid" 2>/dev/null
}

record() { # record <id> <PASS|FAIL|INFO|class> <detail>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RESULTS"
  log "RESULT $1 $2 $3"
}
step() { # step <name>: log and enforce the 30-minute budget
  log "STEP $1 (t+${SECONDS}s)"
  if [ "$SECONDS" -gt "$BUDGET" ]; then stop "budget of ${BUDGET}s exceeded before $1"; fi
}
stop() { # stop <reason>: PLAN stop condition; the EXIT trap runs the cleanup
  printf 'STOP\tSTOP\t%s\n' "$1" >>"$RESULTS"
  log "STOP $1"
  [ "$RC" = 0 ] && RC=1
  exit "$RC"
}

kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n '1p'; } # kv <file> <key>

# redact: everything copied to evidence passes through this filter
redact() {
  sed -E \
    -e "s#$RX_HOME#~#g" \
    "${HOST_SED[@]}" \
    -e "s#ghcr\.io/$RX_USER/#@@KEEPGHCR@@/#g" \
    -e "s#$RX_USER#USER#g" \
    -e "s#@@KEEPGHCR@@/#ghcr.io/$USER_/#g" \
    -e 's#--token[ =][^ ]*#--token REDACTED#g' \
    -e 's#token=[^ &"]*#token=REDACTED#g' \
    -e 's#eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*#REDACTED_JWT#g' \
    -e 's#[Bb]earer [A-Za-z0-9._~+/=-]{8,}#Bearer REDACTED#g' \
    -e 's#\b127\.([0-9]+\.[0-9]+\.[0-9]+)\b#@@L\1@@#g' \
    -e 's#\b0\.0\.0\.0\b#@@Z@@#g' \
    -e 's#\b([0-9]{1,3}\.){3}[0-9]{1,3}\b#IP_REDACTED#g' \
    -e 's#@@L([0-9]+\.[0-9]+\.[0-9]+)@@#127.\1#g' \
    -e 's#@@Z@@#0.0.0.0#g'
}

# contained <path> [self]: absolute, canonical (realpath -e == literal), under
# $ROOT (or equal to it with "self"), no symlink component, owned by us.
contained() {
  local p=${1:-} q
  case $p in /*) ;; *) return 1 ;; esac
  case "$p/" in */../* | */./* | *//*) return 1 ;; esac
  [ "$(realpath -e -- "$p" 2>/dev/null)" = "$p" ] || return 1
  case $p in
  "$ROOT"/*) ;;
  "$ROOT") [ "${2:-}" = self ] || return 1 ;;
  *) return 1 ;;
  esac
  q=$p
  while [ -n "$q" ] && [ "$q" != / ]; do
    [ -L "$q" ] && return 1
    q=${q%/*}
  done
  [ "$(stat -c %u -- "$p" 2>/dev/null)" = "$UID_" ]
}

# --------------------------------------------------------- process queries
# descendants <pid>: all descendants (children, grandchildren, ...) one per line
descendants() {
  cat /proc/[0-9]*/stat 2>/dev/null |
    sed -n 's/^\([0-9]*\) (.*) [A-Za-z] \([0-9]*\) .*/\1 \2/p' |
    awk -v root="$1" '{ kids[$2] = kids[$2] " " $1 }
      END { n = split(kids[root], q, " "); i = 1
        while (i <= n) { print q[i]; m = split(kids[q[i]], t, " "); for (j = 1; j <= m; j++) q[++n] = t[j]; i++ } }'
}
ancestors() { local p=$1; while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do echo "$p"; p=$(ppid_of "$p"); done; }
exe_pids() { find /proc -mindepth 2 -maxdepth 2 -name exe -lname "$1" 2>/dev/null | sed -n 's#^/proc/\([0-9]*\)/exe$#\1#p'; }
# Client detection (correction after run 1123-072024; FIND-080 as revised). In v0.1.9,
# `sandbox connect` is sandbox_connect_supervised() -> run_main_attach_supervised() (ssh.rs):
# the CLI stays up as a supervisor and SPAWNS ssh as its child (exec_or_wait()'s exec-replace
# is not on this path). PATH finds wrap/ssh, which execs /usr/bin/ssh -F $E/ssh_config; ssh
# runs ProxyCommand `$CLI_REAL ssh-proxy --gateway ... --token ...` as `$SHELL -c 'exec ...'`,
# so the proxy is ssh's child. One attached client is that whole chain:
#   cli (`-g GW sandbox connect GW`) -> transport ssh (`-s sandbox openshell-main`) -> proxy (`ssh-proxy`)
# The run-1123 predicate globbed argv with *" sandbox "*" connect "*, which never matches the
# adjacent words, so it counted 0 whatever ran. The marked region is tested by tests/clients-test.sh.
# >>> client-detection
# proc_table: one line per process of ours whose exe is the run's CLI or /usr/bin/ssh:
#   pid TAB ppid TAB start TAB exe TAB runenv(0/1) TAB argv (joined by \x1f)
# environ is only read, and argv only kept, when argv names this run ($E/ or $GW); otherwise
# argv is recorded as "-", so unrelated ssh/openshell processes are counted but never described.
proc_table() {
  local d exe s st=() a=() j env
  for d in "$PROCFS"/[0-9]*; do
    [ -O "$d" ] || continue
    exe=$(readlink "$d/exe" 2>/dev/null) || continue
    case $exe in "$CLI_REAL" | /usr/bin/ssh) ;; *) continue ;; esac
    read -r s 2>/dev/null <"$d/stat" || continue
    read -ra st <<<"${s##*) }"
    mapfile -d '' -t a 2>/dev/null <"$d/cmdline" || continue
    j=$(IFS=$'\x1f'; echo "${a[*]}")
    j=${j//[$'\t\n']/ }
    env=0
    case $j in
    *"$E/"* | *"$GW"*) tr '\0' '\n' 2>/dev/null <"$d/environ" | grep -xF "XDG_CONFIG_HOME=$E/config" >/dev/null && env=1 ;;
    *) j=- ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${d##*/}" "${st[1]:-}" "${st[19]:-}" "$exe" "$env" "$j"
  done
}
# client_classify: proc_table on stdin -> "<class> <pid> <start> <ppid>" per process, then
# "attached <cli> <start> <ssh> <start> <proxy> <start>" per complete chain. Classes:
#   cli        exe = run CLI, run env, argv exactly `-g GW sandbox connect GW`
#   transport  /usr/bin/ssh, run env, `-F $E/ssh_config` first, ends `-s sandbox openshell-main`,
#              ProxyCommand = `$CLI_REAL ssh-proxy --gateway https://127.0.0.1:PORT ... --sandbox GW ...`
#   proxy      exe = run CLI, run env, `ssh-proxy`, --gateway https://127.0.0.1:PORT, --sandbox GW
#   run-ssh    any other ssh with `-F $E/ssh_config` (never expected; counted as a client process)
#   other      everything else: the create CLI, a CLI without the run env, unrelated ssh/openshell
client_classify() {
  awk -F '\t' -v E="$E" -v GW="$GW" -v PORT="$PORT" -v CLI="$CLI_REAL" '
    function gw_ok(v) { return v == "https://127.0.0.1:" PORT || index(v, "https://127.0.0.1:" PORT "/") == 1 }
    function pc_ok(v,   u, c) { # v: the ProxyCommand value after "--gateway " (url possibly single-quoted)
      sub(/^\047/, "", v); u = "https://127.0.0.1:" PORT
      if (index(v, u) != 1) return 0
      c = substr(v, length(u) + 1, 1)
      return c == "\047" || c == "/" || c == " "
    }
    function cls(exe, env, j,   a, n, i, gw, sb, rc, pfx) {
      if (j == "-") return "other"
      n = split(j, a, "\037")
      if (exe == CLI) {
        if (env != 1) return "other"
        if (n == 6 && a[2] == "-g" && a[3] == GW && a[4] == "sandbox" && a[5] == "connect" && a[6] == GW) return "cli"
        if (n >= 2 && a[2] == "ssh-proxy") {
          gw = 0; sb = 0
          for (i = 3; i < n; i++) {
            if (a[i] == "--gateway" && gw_ok(a[i + 1])) gw = 1
            if (a[i] == "--sandbox" && a[i + 1] == GW) sb = 1
          }
          if (gw && sb) return "proxy"
        }
        return "other"
      }
      rc = 0
      for (i = 2; i < n; i++) if (a[i] == "-F" && a[i + 1] == E "/ssh_config") rc = 1
      if (!rc) return "other"
      if (env == 1 && n >= 6 && a[2] == "-F" && a[3] == E "/ssh_config" && a[n - 2] == "-s" && a[n - 1] == "sandbox" && a[n] == "openshell-main") {
        pfx = "ProxyCommand=" CLI " ssh-proxy --gateway "
        for (i = 4; i < n - 2; i++)
          if (index(a[i], pfx) == 1 && pc_ok(substr(a[i], length(pfx) + 1)) && index(a[i], " --sandbox " GW " ") > 0) return "transport"
      }
      return "run-ssh"
    }
    NF >= 6 { c = cls($4, $5, $6); print c, $1, $3, $2; k[$1] = c; par[$1] = $2; st[$1] = $3; if (c == "proxy") px[++np] = $1 }
    END {
      for (i = 1; i <= np; i++) {
        x = px[i]; s = par[x]; p = par[s]
        if (k[s] == "transport" && k[p] == "cli") print "attached", p, st[p], s, st[s], x, st[x]
      }
    }'
}
client_snap() { proc_table | client_classify; } # one consistent scan
client_counts() {
  client_snap | awk '{ n[$1]++ } END { printf "attached=%d cli=%d transport=%d proxy=%d run-ssh=%d other=%d", n["attached"], n["cli"], n["transport"], n["proxy"], n["run-ssh"], n["other"] }'
}
clients_pids() { client_snap | awk '$1 == "cli" { print $2 }'; }                    # supervising CLIs, attached or not
ssh_pids() { client_snap | awk '$1 == "transport" || $1 == "run-ssh" { print $2 }'; } # any ssh using the run's ssh_config
proxy_pids() { client_snap | awk '$1 == "proxy" { print $2 }'; }
clients() { client_snap | grep -c '^attached '; } # complete cli -> ssh -> proxy chains
client_procs() { client_snap | grep -c -E '^(cli|transport|proxy|run-ssh) '; }
clients_eq() { [ "$(clients)" -eq "$1" ]; }
clients_ge() { [ "$(clients)" -ge "$1" ]; }
no_client_procs() { [ "$(client_procs)" -eq 0 ]; } # "no connect/ssh process remains": cli, ssh and proxy all gone
clients_detail() { log "clients: $(client_counts)"; }
# A pane's client is recorded as "cli:start ssh:start proxy:start" (ATT, PANE_CLIENT[pane]).
att_alive() { # every process of the chain is alive with its recorded start time
  local e n=0
  for e in $1; do alive_same "${e%%:*}" "${e#*:}" || return 1; n=$((n + 1)); done
  [ "$n" = 3 ]
}
att_gone() { # every process of the chain is gone (or its pid recycled); unknown chains are not gone
  local e n=0
  for e in $1; do gone "${e%%:*}" "${e#*:}" || return 1; n=$((n + 1)); done
  [ "$n" = 3 ]
}
att_ssh() { local a=(); read -ra a <<<"$1"; echo "${a[1]%%:*}"; }
# <<< client-detection

# unix_peers <pid>: socket paths the process is connected to (best effort)
unix_peers() {
  local f l inodes ssout
  inodes=$(for f in /proc/"$1"/fd/*; do
    l=$(readlink "$f" 2>/dev/null)
    case $l in socket:\[*\]) l=${l#socket:[}; echo "${l%]}" ;; esac
  done | tr '\n' ',')
  ssout=$("$SS" -xan 2>/dev/null)
  awk -v inodes="$inodes" 'BEGIN { n = split(inodes, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") mine[a[i]] = 1 }
    { loc[$6] = $5; peer[$6] = $8 }
    END { for (i in mine) {
        if (loc[i] != "" && loc[i] != "*") print loc[i]
        p = peer[i]; if (p != "" && p != "0" && (p in loc) && loc[p] != "*") print loc[p] } }' <<<"$ssout" | sort -u
}

snap_pids() { # pids worth a process snapshot
  local e p
  for e in "${PIDS[@]}"; do p=${e#*:}; echo "${p%%:*}"; done
  clients_pids
  ssh_pids
  proxy_pids
  exe_pids "$CLI_REAL"
  [ -n "$WPID" ] && { echo "$WPID"; ppid_of "$WPID"; }
  [ -n "$HPIDC" ] && echo "$HPIDC"
  [ -n "$HERDR_PID" ] && ps -o pid= --ppid "$HERDR_PID" 2>/dev/null
}
snap() { # snap <name>: process-tree snapshot, redacted
  local f=$E/snaps/$1.txt l=() p
  while read -r p; do [ -n "$p" ] && [ -d "/proc/$p" ] && l+=("$p"); done < <(snap_pids | sort -un)
  {
    echo "# $1 $(date -u +%FT%TZ)"
    if [ "${#l[@]}" -gt 0 ]; then ps -ww -o pid,ppid,sid,pgid,uid,lstart,args -p "$(IFS=,; echo "${l[*]}")" 2>&1; fi
    if [ -n "$HERDR_PID" ] && [ -d "/proc/$HERDR_PID" ]; then
      echo "# children of herdr server $HERDR_PID"
      ps -ww -o pid,ppid,sid,pgid,uid,lstart,args --ppid "$HERDR_PID" 2>&1
    fi
    echo "# clients: $(client_counts)"
  } 2>&1 | redact >"$f"
}

# ------------------------------------------------------- protected baselines
# baseline <dir>: metadata only (never contents) of everything this run must not change.
# bl_one <name>: one listing on stdout (also used after the run root is gone, for the final check)
bl_one() {
  local pf='%P\t%y\t%s\t%T@\t%m\n' u
  case $1 in
  openshell-config.txt) find "$HOME/.config/openshell" -printf "$pf" 2>&1 | LC_ALL=C sort ;;
  openshell-state.txt)
    { find "$HOME/.local/state/openshell" -printf "$pf" 2>&1; find "$HOME/.local/share/openshell" -printf "$pf" 2>&1; } |
      LC_ALL=C sort ;;
  ssh-meta.txt) find "$HOME/.ssh" -printf "$pf" 2>&1 | LC_ALL=C sort ;;
  listeners.txt) "$SS" -Htlnu 2>&1 | awk '{print $1,$5}' | LC_ALL=C sort ;;
  podman-default.txt)
    echo '## ps'; PD ps -a --format '{{.ID}} {{.Names}} {{.State}}' 2>&1 | LC_ALL=C sort
    echo '## volumes'; PD volume ls -q 2>&1 | LC_ALL=C sort
    echo '## networks'; PD network ls --format '{{.ID}} {{.Name}}' 2>&1 | LC_ALL=C sort
    echo '## secrets'; PD secret ls --format '{{.ID}} {{.Name}}' 2>&1 | LC_ALL=C sort
    echo '## images'; PD images -q --no-trunc 2>&1 | LC_ALL=C sort
    ;;
  systemd-units.txt) # transient-scope residue from the systemd cgroup manager would show up here
    u=$(timeout -k 5 30 systemctl --user list-units --all --no-legend --plain 'libpod*' 'podman*' 2>&1 | awk '{print $1}' | LC_ALL=C sort)
    printf '%s\n' "$u"
    ;;
  esac
}
baseline() {
  local d=$1 f
  mkdir -p "$d"
  for f in "${BASE_FILES[@]}"; do bl_one "$f" >"$d/$f"; done
  (cd "$d" && sha256sum -- *.txt >SHA256SUMS)
}

# ------------------------------------------------------------------ cleanup
cl_note() { printf '%s\n' "$*" | tee -a "$CL_LOG"; }
cl_residue() { CLS=RESIDUE; cl_note "RESIDUE: $*"; }

cl_sig_wait() { # cl_sig_wait <label:pid:start> <term-wait-s>: SIGTERM, wait, SIGKILL (verified pids only)
  local e=$1 w=$2 pid st
  IFS=: read -r _ pid st <<<"$e"
  alive_same "$pid" "$st" || return 0
  cl_note "SIGTERM ${e%%:*} pid=$pid"
  sig TERM "$e"
  if ! poll "$w" 0.5 gone "$pid" "$st"; then
    cl_note "SIGKILL ${e%%:*} pid=$pid (still alive after ${w}s)"
    sig KILL "$e"
  fi
}

cl_herdr() {
  local e pid st
  if [ -n "$HERDR_PID" ] && alive_same "$HERDR_PID" "$HERDR_START"; then
    if guard; then H server stop >/dev/null 2>&1; fi
    poll 8 0.5 gone "$HERDR_PID" "$HERDR_START"
  fi
  # only tracked herdr servers whose start time AND environment still match
  for e in "${PIDS[@]}"; do
    case ${e%%:*} in herdr-server-*) ;; *) continue ;; esac
    IFS=: read -r _ pid st <<<"$e"
    alive_same "$pid" "$st" || continue
    proc_env_has "$pid" "XDG_CONFIG_HOME=$E/config" || { cl_note "herdr pid=$pid environment mismatch; not signalled"; continue; }
    cl_sig_wait "$e" 5
  done
}

prestop_capture() { # bounded (every call has its own timeout); read-only; nothing is signalled or deleted
  local p n=0
  mkdir -p "$E/obs" "$E/panes" "$E/snaps" 2>/dev/null
  log "pre-stop capture"
  if [ "$GUARD_OK" = 1 ] && [ -n "$HERDR_PID" ] && alive_same "$HERDR_PID" "$HERDR_START"; then
    for p in $(pane_ids 2>/dev/null); do n=$((n + 1)); [ "$n" -le 4 ] || break; pane_capture "$p" "stop-$p"; done
  fi
  snap 99-stop 2>/dev/null
  { echo "# pre-stop $(date -u +%FT%TZ): $(client_counts 2>/dev/null)"; client_snap 2>/dev/null | awk '$1 != "other"'; } 2>&1 | redact >"$E/obs/stop-clients.txt"
  [ -S "$E/podman.sock" ] && PT=30 P ps -a --format '{{.ID}} {{.Names}} {{.State}} {{.Status}}' >"$E/obs/stop-containers.txt" 2>&1
  [ -n "$GWPID" ] && alive_same "$GWPID" "$GWSTART" && OT=30 sbx_json stop >/dev/null 2>&1
  return 0
}
cl_sandbox() { # remove the sandbox through the gateway if both still exist
  [ -n "$GWPID" ] && alive_same "$GWPID" "$GWSTART" || return 0
  [ -x "$E/wrap/openshell" ] || return 0
  OT=30 sbx_json cl-probe >/dev/null 2>&1 || return 0
  cl_note "sandbox still exists; emergency deletion through the gateway by the cleanup trap (not A7b)"
  record C-delete INFO "emergency deletion by the cleanup trap, not an explicit A7b deletion (phase before: $(sbx_phase cl-probe))"
  OT=60 O sandbox delete "$GW" >>"$E/obs/cleanup-delete.out" 2>&1
  poll 60 2 sbx_gone || cl_residue "sandbox $GW still present after delete"
}
sbx_gone() { ! OT=30 sbx_json cl-gone >/dev/null 2>&1; }

cl_gateway() {
  local e
  for e in "${PIDS[@]}"; do
    case ${e%%:*} in gateway-*) cl_sig_wait "$e" 90 ;; esac
  done
}

cl_store() { # empty the dedicated store (only after re-verifying it IS the dedicated one)
  local gr
  [ -S "$E/podman.sock" ] || return 0 # the service never started (or already gone)
  gr=$(PT=30 P info -f json 2>/dev/null | "$JQ" -r '.store.graphRoot' 2>/dev/null)
  if [ "$gr" != "$E/podman/root" ]; then cl_note "store check failed (graphRoot='$gr'); not touching the store"; return 0; fi
  {
    echo "# before $(date -u +%FT%TZ)"
    PT=30 P ps -a --format '{{.ID}} {{.Names}} {{.State}}'; PT=30 P volume ls -q; PT=30 P secret ls -q; PT=30 P network ls --format '{{.Name}}'
  } >"$E/obs/cleanup-store-before.txt" 2>&1
  { # only things inside the verified dedicated store; the network is this run's own
    PT=180 P rm -f -t 0 --all
    PT=120 P volume rm -f --all
    PT=60 P secret rm --all
    PT=60 P network rm -f "$GW"
  } >>"$E/obs/cleanup-store.out" 2>&1
  {
    echo "# after $(date -u +%FT%TZ)"
    PT=30 P ps -a -q; PT=30 P volume ls -q; PT=30 P secret ls -q; PT=30 P network ls --format '{{.Name}}'
  } >"$E/obs/cleanup-store-after.txt" 2>&1
}

cl_service() {
  [ -n "$PSL_ENTRY" ] && cl_sig_wait "$PSL_ENTRY" 15
  [ -n "$PS_ENTRY" ] && cl_sig_wait "$PS_ENTRY" 15
}

# sweep <phase>: SIGTERM then SIGKILL anything of ours that still carries this
# run's XDG markers (covers rootless pause process, conmon, aardvark-dns, pasta,
# stray openshell/ssh clients), or a known helper binary whose argv names $E.
sweep() {
  local d p st comm cmd hit anc=" $$ " q found=() e
  q=$(ppid_of $$)
  while [ -n "$q" ] && [ "$q" -gt 1 ] 2>/dev/null; do anc+="$q "; q=$(ppid_of "$q"); done
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    case $anc in *" $p "*) continue ;; esac
    [ -O "$d" ] || continue
    hit=
    if proc_env_has "$p" "XDG_RUNTIME_DIR=$E/run" "XDG_CONFIG_HOME=$E/config"; then
      hit=environ
    else
      cmd=$(proc_cmd "$p")
      case $cmd in
      *"$E/"* | *"$E "*)
        case $(proc_comm "$p") in
        conmon | crun | aardvark-dns | netavark | pasta* | passt* | slirp4netns | rootlessport* | catatonit | podman | openshell* | ssh) hit=cmd ;;
        esac
        ;;
      esac
    fi
    [ -n "$hit" ] || continue
    st=$(proc_start "$p")
    comm=$(proc_comm "$p")
    [ -n "$st" ] || continue
    found+=("sweep-${comm//[^A-Za-z0-9._-]/_}:$p:$st") # label must not contain ':'
    cl_note "SWEPT[$1] pid=$p start=$st comm=$comm via=$hit"
  done
  for e in "${found[@]}"; do sig TERM "$e"; done
  [ "${#found[@]}" -gt 0 ] && sleep 2
  for e in "${found[@]}"; do sig KILL "$e"; SWEPT+=("$e"); done
}

cl_store_rm() { # remove the dedicated store from inside its user namespace (files are subuid-owned)
  local d args=()
  for d in "$E/podman/root" "$E/podman/runroot"; do
    [ -e "$d" ] || continue
    if contained "$d"; then args+=("$d"); else cl_residue "store path not contained: $d"; fi
  done
  [ "${#args[@]}" -gt 0 ] || return 0
  tcenv 300 "${PENV[@]}" "$PODMAN" --root "$E/podman/root" --runroot "$E/podman/runroot" unshare rm -rf --one-file-system -- "${args[@]}" >>"$E/obs/cleanup-store.out" 2>&1
  for d in "${args[@]}"; do [ -e "$d" ] && cl_residue "store path still present: $d"; done
}

cl_verify() {
  local e label pid st bad=0
  for e in "${PIDS[@]}" "${SWEPT[@]}"; do
    IFS=: read -r label pid st <<<"$e"
    [ -n "$pid" ] || continue
    if [ -z "$st" ]; then echo "unverifiable (no start time was recorded): $label pid=$pid" >>"$E/cleanup.txt"; continue; fi
    if ! gone "$pid" "$st"; then sig KILL "$e"; fi
    if poll 5 0.5 gone "$pid" "$st"; then
      echo "verified gone: $label pid=$pid" >>"$E/cleanup.txt"
    else
      cl_note "STILL ALIVE: $label pid=$pid"
      bad=1
    fi
  done
  [ "$bad" = 1 ] && CLS=RESIDUE
  return 0
}

# ------------------------------------------------------------------ evidence
# evcopy <src> <dest relative to $EVID>: redacted copy; never keys/certs/db
evcopy() {
  local src=$1 dst=$EVID/$2
  [ -f "$src" ] || return 0
  case $src in
  "$E"/tls/* | "$E"/config/openshell/* | "$E"/state/* | *.key | *.pem | *.crt | *.db | *.db-wal | *.db-shm) return 0 ;;
  "$E"/obs/B1/* | "$E"/B2/*) return 0 ;; # raw baseline listings of owner state never leave the run root
  esac
  if grep 'PRIVATE KEY' "$src" >/dev/null 2>&1; then echo "DROPPED (PRIVATE KEY): $2" >>"$E/cleanup.txt"; return 0; fi
  mkdir -p "$(dirname "$dst")"
  redact <"$src" >"$dst"
}
evcopy_dir() { # evcopy_dir <srcdir> <dest-prefix>
  local f
  [ -d "$1" ] || return 0
  while IFS= read -r -d '' f; do evcopy "$f" "$2/${f#"$1"/}"; done < <(find "$1" -type f -print0 2>/dev/null)
}

write_versions() {
  {
    echo "run-id: $RUN"
    echo "date-utc: $(date -u +%FT%TZ)"
    echo "port: $PORT"
    echo "openshell: $(tcenv 10 "$E/wrap/openshell" --version 2>&1)"
    echo "openshell-gateway: $(tcenv 10 "$GW_BIN" --version 2>&1)"
    echo "herdr: $(tcenv 10 "$HERDR_BIN" --version 2>&1)"
    echo "podman client: $("$PODMAN" --version 2>&1)"
    echo "podman service (info): $(kv "$E/obs/p3-podman.txt" version)"
    echo "cgroup manager: $(kv "$E/obs/p3-podman.txt" cgroupManager) cgroup version: $(kv "$E/obs/p3-podman.txt" cgroupVersion)"
    echo "bash: ${BASH_VERSION}"
    echo "kernel: $(uname -sr)"
    echo "openshell sha256: $CLI_SHA"
    echo "openshell-gateway sha256: $GW_SHA"
    echo "herdr sha256: $(sha256sum "$(readlink -f "$HERDR_BIN")" | cut -d' ' -f1)"
    echo "demo.sh sha256: $(sha256sum "$HERE/demo.sh" | cut -d' ' -f1)"
    echo "counter.sh sha256 (repo copy, EXP-006): $(sha256sum "$HERE/../../exp-006/local/counter.sh" 2>/dev/null | cut -d' ' -f1)"
    echo "workload image (pinned): $WORKLOAD"
    echo "runtime image (pinned): $RT_IMG"
    echo "supervisor image (pinned): $SUP_IMG"
    echo "images as pulled:"
    cat "$E/obs/pulled-images.txt" 2>/dev/null
  } >"$E/versions.txt" 2>&1
}

collect_evidence() {
  mkdir -p "$EVID" || return 0
  [ -f "$E/versions.txt" ] || write_versions
  evcopy "$E/versions.txt" versions.txt
  evcopy "$E/timeline.log" timeline.log
  evcopy "$E/results.tsv" results.tsv
  evcopy "$E/setup-lineage.txt" setup-lineage.txt
  local f
  for f in "$E"/server-env-keys*.txt; do evcopy "$f" "$(basename "$f")"; done
  for f in cli-version gw-version create-help connect-help gateway-add-help gw-generate-certs-help gw-config-help images; do
    evcopy "$ROOT/p2/$f.txt" "p2/$f.txt"
  done
  for f in "$ROOT"/p2/att-*.txt "$ROOT/p2/attestation-diag.txt"; do evcopy "$f" "p2/$(basename "$f")"; done
  mkdir -p "$EVID/p2"
  { # provenance lines only (control characters stripped)
    grep -h -e 'SOURCE_SHA' -e 'refs/tags/v0.1.9' "$ROOT"/p2/job-*.log 2>/dev/null | tr -d '\033' | cut -c1-300
  } 2>/dev/null | redact >"$EVID/p2/provenance.txt" 2>/dev/null
  evcopy_dir "$E/out" out
  evcopy_dir "$E/obs" obs
  evcopy_dir "$E/panes" panes
  evcopy_dir "$E/snaps" snaps
  for f in wrap/ssh wrap/openshell ssh_config gateway.toml config/containers/containers.conf config/containers/storage.conf \
    config/herdr/config.toml pane-shell pane-bashrc; do
    evcopy "$E/$f" "cfg/$f"
  done
  mkdir -p "$EVID/logs"
  tail -n 1500 "$E/logs/gateway.log" 2>/dev/null | redact >"$EVID/logs/gateway.log"
  tail -n 200 "$E/logs/podman-service.log" 2>/dev/null | redact >"$EVID/logs/podman-service.log"
  tail -n 100 "$E/logs/herdr-stdout.log" 2>/dev/null | redact >"$EVID/logs/herdr-stdout.log"
}

# evidence_scan: fail loudly (and withhold the file) if anything sensitive survived redaction
evidence_scan() {
  local f pat hit
  [ -d "$EVID" ] || return 0
  for pat in 'PRIVATE KEY' 'eyJ' '--token[ =][^R]'; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      EVBAD=1; cl_note "EVIDENCE SCAN HIT '$pat' in ${f#"$EVID"/}; file withheld"
      echo "WITHHELD: matched sensitive pattern" >"$f"
    done < <(grep -rlE -e "$pat" "$EVID" 2>/dev/null)
  done
  for hit in "$HOME" "$HOST_"; do
    [ -n "$hit" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      EVBAD=1; cl_note "EVIDENCE SCAN HIT (home/host name) in ${f#"$EVID"/}; file withheld"
      echo "WITHHELD: matched sensitive pattern" >"$f"
    done < <(grep -rlF -e "$hit" "$EVID" 2>/dev/null)
  done
}

# ffield: names/addresses only (never sizes, mtimes, modes)
ffield() {
  case $1 in
  listeners.txt) cat ;;
  *) awk -F'\t' '{ if (NF > 1) print $1; else { split($0, a, " "); print a[1] } }' ;;
  esac
}
norm() { grep -v -e '^## ' -e '^exit=' "${1:-/dev/stdin}" | LC_ALL=C sort; } # B0 carries '## dir' and 'exit=' lines
# Pre-registered: the protected listener baseline is the TCP listener set; UDP sockets (mDNS, VPN,
# ephemeral client ports) churn on their own, so a UDP-only change is reported as INFO, not RESIDUE.
lfilter() { case $1 in listeners.txt) grep '^tcp' ;; *) cat ;; esac; }

# cl_classify: B2 vs B1 (all files) and vs B0 (four files); CLEAN / RESIDUE / UNVERIFIED
cl_classify() {
  local f a b n pub=$E/cleanup-diff-public.txt priv
  baseline "$E/B2" 2>/dev/null
  : >"$E/cleanup-diff.txt"; : >"$pub"
  for f in "${BASE_FILES[@]}"; do
    a=$E/obs/B1/$f; b=$E/B2/$f
    if [ ! -f "$a" ] || [ ! -f "$b" ]; then
      [ "$CLS" = CLEAN ] && CLS=UNVERIFIED; cl_note "B2-vs-B1 $f: could not compare"; continue
    fi
    case $f in openshell-config.txt | openshell-state.txt | ssh-meta.txt) priv=1 ;; *) priv=0 ;; esac
    if [ "$(lfilter "$f" <"$a")" = "$(lfilter "$f" <"$b")" ]; then
      cl_note "B2-vs-B1 $f: identical"
      cmp -s "$a" "$b" || cl_note "INFO B2-vs-B1 $f: UDP listener set changed (not classified)"
    else
      n=$(diff <(ffield "$f" <"$a") <(ffield "$f" <"$b") | grep -c '^[<>]')
      cl_residue "B2-vs-B1 $f differs ($n name-level lines)"
      { echo "## B1 vs B2 $f"; diff <(ffield "$f" <"$a") <(ffield "$f" <"$b"); } >>"$E/cleanup-diff.txt"
      if [ "$priv" = 1 ]; then echo "## $f: $n name-level difference(s); names withheld from evidence (owner-private)" >>"$pub"
      else { echo "## $f"; diff <(ffield "$f" <"$a") <(ffield "$f" <"$b"); } >>"$pub"; fi
    fi
  done
  for f in openshell-config.txt openshell-state.txt ssh-meta.txt listeners.txt; do
    a=$ROOT/baseline-pre/$f; b=$E/B2/$f
    if [ ! -f "$a" ] || [ ! -f "$b" ]; then
      [ "$CLS" = CLEAN ] && CLS=UNVERIFIED; cl_note "B2-vs-B0 $f: could not compare"; continue
    fi
    if [ "$(norm "$a" | lfilter "$f")" = "$(norm "$b" | lfilter "$f")" ]; then
      cl_note "B2-vs-B0 $f: identical"
    else
      cl_residue "B2-vs-B0 $f differs"
      echo "## B0 vs B2 $f: differs (names not recorded here)" >>"$pub"
      { echo "## B0 vs B2 $f"; diff <(norm "$a" | ffield "$f") <(norm "$b" | ffield "$f"); } >>"$E/cleanup-diff.txt"
    fi
  done
  # owner-private name-level diffs go to the terminal only, never to evidence
  if [ -s "$E/cleanup-diff.txt" ]; then echo "--- cleanup-diff (terminal only) ---"; redact <"$E/cleanup-diff.txt"; fi
}

evidence_baselines() {
  local d
  mkdir -p "$EVID/baselines"
  # hashes and line counts only; raw listings (owner state metadata) are never copied
  for d in obs/B1 B2; do
    [ -f "$E/$d/SHA256SUMS" ] && redact <"$E/$d/SHA256SUMS" >"$EVID/baselines/$(basename "$d")-SHA256SUMS"
    wc -l "$E/$d"/*.txt 2>/dev/null | redact >"$EVID/baselines/$(basename "$d")-linecounts.txt"
  done
  [ -f "$ROOT/baseline-pre/SHA256SUMS" ] && redact <"$ROOT/baseline-pre/SHA256SUMS" >"$EVID/baselines/B0-SHA256SUMS"
  [ -f "$E/cleanup-diff-public.txt" ] && redact <"$E/cleanup-diff-public.txt" >"$EVID/baselines/first-field-diff.txt"
}

print_summary() {
  local id res detail fails=0
  echo
  printf '%-14s %-10s %s\n' TEST RESULT DETAIL
  while IFS=$'\t' read -r id res detail; do
    printf '%-14s %-10s %s\n' "$id" "$res" "$detail"
    case $res in FAIL | STOP) fails=$((fails + 1)) ;; esac
  done <"$RESULTS"
  echo
  echo "failures: $fails  cleanup: $CLS  evidence: $EVID"
}

cleanup() {
  local rc=$? fails id
  set +u # cleanup must tolerate any missing state
  [ "$CLEANING" = 1 ] && return 0
  CLEANING=1
  trap - EXIT
  # signals during cleanup are noted, not fatal (a caught trap, unlike SIG_IGN, is not inherited by children)
  trap 'echo "signal received during cleanup; continuing" >&2' INT TERM HUP
  [ "$OWN_E" = 1 ] || exit "$rc"
  log "cleanup start (exit=$rc)"
  # 1) watchdog; after a stop, a best-effort capture of the live state; then Herdr via its own socket
  [ -n "$WD_ENTRY" ] && sig TERM "$WD_ENTRY"
  [ "$MAIN_DONE" = 1 ] || prestop_capture
  cl_herdr
  # 2-3) sandbox via the gateway (if still possible), then the gateway
  save_out_final
  cl_sandbox
  cl_gateway
  # 4-5) dedicated store, then the Podman service
  cl_store
  cl_service
  sweep pre-store
  # 6) store removal (containment-checked), then the straggler sweep
  cl_store_rm
  sweep final
  # 7) positive verification
  cl_verify
  # 8) port closed
  if [ -n "$("$SS" -Htln "sport = :$PORT" 2>/dev/null)" ]; then cl_residue "port $PORT still listening"; else cl_note "port $PORT closed"; fi
  # 9) evidence, 10) baseline classification
  collect_evidence
  cl_classify
  [ "$CLS" = CLEAN ] && cl_note "cleanup verified: all recorded and swept PIDs gone, port closed, baselines identical"
  cl_note "CLASSIFICATION: $CLS"
  # exit code policy: 2 refusal (earlier), 1 any FAIL/STOP, 3 cleanup not CLEAN, 0 otherwise
  fails=$(awk -F'\t' '$2 == "FAIL" || $2 == "STOP"' "$RESULTS" 2>/dev/null | wc -l)
  # every planned step ends with a row: a missing result is recorded as NOT-RUN, never read as PASS
  for id in $PLANNED; do
    awk -F'\t' -v i="$id" '$1 == i {f = 1} END {exit !f}' "$RESULTS" 2>/dev/null ||
      record "$id" NOT-RUN "no result recorded ($([ "$MAIN_DONE" = 1 ] && echo 'the step recorded nothing' || echo 'not reached: the run stopped earlier'))"
  done
  if [ "$MAIN_DONE" = 1 ]; then
    for id in A1 A6 A7a A7b; do
      awk -F'\t' -v i="$id" '$1 == i && $2 == "PASS" {f = 1} END {exit !f}' "$RESULTS" 2>/dev/null || fails=$((fails + 1))
    done
  fi
  [ "$rc" = 0 ] && [ "$fails" -gt 0 ] && rc=1
  evidence_baselines
  evcopy "$E/results.tsv" results.tsv
  evcopy "$E/cleanup.txt" cleanup.txt
  evidence_scan
  [ "$EVBAD" = 1 ] && [ "$rc" = 0 ] && rc=1
  print_summary
  # 11) remove the run root (evidence is already copied out; reference hashes are kept in memory)
  ref_hashes
  CLS_INTERMEDIATE=$CLS
  cl_remove_root
  # 12) the classification is the verified final state; intermediate notes stay in cleanup.txt
  cl_final
  evidence_scan
  [ "$EVBAD" = 1 ] && [ "$rc" = 0 ] && rc=1
  {
    echo "classification: $CLS (verified final state after run-root removal; cleanup-final.txt)"
    echo "intermediate classification: $CLS_INTERMEDIATE (before run-root removal; cleanup.txt keeps its notes)"
    echo "run root removed: $ROOT_GONE"
    echo "exit: $rc"
  } >"$EVID/final-status.txt" 2>/dev/null
  echo "cleanup: $CLS (intermediate: $CLS_INTERMEDIATE; run root removed: $ROOT_GONE)"
  [ "$CLS" != CLEAN ] && [ "$rc" = 0 ] && rc=3
  exit "$rc"
}

# ref_hashes: B1 (all files) and B0 (four files) reference hashes, comparable after the run root is gone
ref_hashes() {
  local f
  for f in "${BASE_FILES[@]}"; do
    [ -f "$E/obs/B1/$f" ] && REF1[$f]=$(lfilter "$f" <"$E/obs/B1/$f" | sha256sum | cut -d' ' -f1)
  done
  for f in openshell-config.txt openshell-state.txt ssh-meta.txt listeners.txt; do
    [ -f "$ROOT/baseline-pre/$f" ] && REF0[$f]=$(norm "$ROOT/baseline-pre/$f" | lfilter "$f" | sha256sum | cut -d' ' -f1)
  done
}

# cl_final: positive, detection-only verification after run-root removal (nothing is signalled or
# deleted here). RESIDUE if anything of the run remains or a protected baseline differs, UNVERIFIED
# if a check could not be made, otherwise CLEAN. Sets CLS.
cl_final() {
  local fin=CLEAN unv=0 e label pid st n=0 d anc=" $$ " q f h t
  CL_LOG=$EVID/cleanup-final.txt
  mkdir -p "$EVID" 2>/dev/null || { CLS=UNVERIFIED; return 0; }
  : >"$CL_LOG"
  cl_note "# final-state verification $(date -u +%FT%TZ); intermediate classification: $CLS_INTERMEDIATE"
  cl_note "intermediate RESIDUE notes kept in cleanup.txt: $(grep -c '^RESIDUE' "$EVID/cleanup.txt" 2>/dev/null)"
  if [ -e "$ROOT" ] || [ -L "$ROOT" ]; then fin=RESIDUE; cl_note "RESIDUE: run root still present"; else cl_note "run root absent"; fi
  for e in "${PIDS[@]}" "${SWEPT[@]}"; do
    IFS=: read -r label pid st <<<"$e"
    [ -n "$pid" ] && [ -n "$st" ] || continue
    if gone "$pid" "$st"; then n=$((n + 1)); else fin=RESIDUE; cl_note "RESIDUE: still alive: $label pid=$pid"; fi
  done
  cl_note "recorded and swept processes verified gone: $n"
  # any other process of ours that still carries this run's markers (the sweep's criteria, on $ROOT)
  q=$(ppid_of $$)
  while [ -n "$q" ] && [ "$q" -gt 1 ] 2>/dev/null; do anc+="$q "; q=$(ppid_of "$q"); done
  n=0
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    case $anc in *" $pid "*) continue ;; esac
    [ -O "$d" ] || continue
    if proc_env_has "$pid" "XDG_RUNTIME_DIR=$E/run" "XDG_CONFIG_HOME=$E/config"; then
      n=$((n + 1)); cl_note "RESIDUE: pid=$pid comm=$(proc_comm "$pid") has this run's environment"
    else
      case $(proc_cmd "$pid") in
      *"$ROOT/"* | *"$ROOT "*)
        case $(proc_comm "$pid") in
        conmon | crun | aardvark-dns | netavark | pasta* | passt* | slirp4netns | rootlessport* | catatonit | podman | openshell* | ssh | herdr)
          n=$((n + 1)); cl_note "RESIDUE: pid=$pid comm=$(proc_comm "$pid") names the run root" ;;
        esac
        ;;
      esac
    fi
  done
  if [ "$n" = 0 ]; then cl_note "no process carries this run's markers"; else fin=RESIDUE; fi
  n=$("$SS" -xan 2>/dev/null | grep -cF "$ROOT/")
  if [ "$n" = 0 ]; then cl_note "no unix socket under the run root"; else fin=RESIDUE; cl_note "RESIDUE: $n unix socket(s) under the run root"; fi
  if [ -n "$("$SS" -Htln "sport = :$PORT" 2>/dev/null)" ]; then fin=RESIDUE; cl_note "RESIDUE: port $PORT listening"; else cl_note "port $PORT closed"; fi
  n=$(grep -lF -e "$ROOT/" -e "${ROOT#/tmp}/" /proc/[0-9]*/mountinfo 2>/dev/null | wc -l) # tmpfs-relative roots too
  if [ "$n" = 0 ]; then cl_note "no mount under the run root in any readable mount namespace"
  else fin=RESIDUE; cl_note "RESIDUE: $n mount namespace(s) with a mount under the run root"; fi
  # protected baselines, recomputed now against the in-memory B1/B0 reference hashes
  for f in "${BASE_FILES[@]}"; do
    if [ -z "${REF1[$f]:-}" ]; then unv=1; cl_note "final-vs-B1 $f: no reference (UNVERIFIED)"; continue; fi
    h=$(bl_one "$f" | lfilter "$f" | sha256sum | cut -d' ' -f1)
    if [ "$h" = "${REF1[$f]}" ]; then cl_note "final-vs-B1 $f: identical"; else fin=RESIDUE; cl_note "RESIDUE: final-vs-B1 $f differs"; fi
  done
  for f in openshell-config.txt openshell-state.txt ssh-meta.txt listeners.txt; do
    if [ -z "${REF0[$f]:-}" ]; then unv=1; cl_note "final-vs-B0 $f: no reference (UNVERIFIED)"; continue; fi
    h=$(bl_one "$f" | norm | lfilter "$f" | sha256sum | cut -d' ' -f1)
    if [ "$h" = "${REF0[$f]}" ]; then cl_note "final-vs-B0 $f: identical"; else fin=RESIDUE; cl_note "RESIDUE: final-vs-B0 $f differs"; fi
  done
  [ "$fin" = CLEAN ] && [ "$unv" = 1 ] && fin=UNVERIFIED
  CLS=$fin
  cl_note "FINAL CLASSIFICATION: $CLS"
  t=$(redact <"$CL_LOG") && printf '%s\n' "$t" >"$CL_LOG"
}

cl_remove_root() {
  if contained "$ROOT" self; then
    rm -rf --one-file-system -- "$ROOT"
    if [ -e "$ROOT" ] && contained "$ROOT" self; then
      # subuid-owned leftovers: retry once from inside a user namespace, only under $ROOT
      mkdir -p "$E/run" "$E/podman/root" "$E/podman/runroot" 2>/dev/null
      if contained "$ROOT" self; then
        tcenv 300 "${PENV[@]}" "$PODMAN" --root "$E/podman/root" --runroot "$E/podman/runroot" unshare rm -rf --one-file-system -- "$ROOT" >/dev/null 2>&1
        [ -e "$ROOT" ] && contained "$ROOT" self && rm -rf --one-file-system -- "$ROOT"
        sweep post-root # `podman unshare` may have started a fresh pause process
        local e; for e in "${SWEPT[@]}"; do poll 5 0.5 gone "$(cut -d: -f2 <<<"$e")" "$(cut -d: -f3 <<<"$e")" || { ROOT_GONE=no; CLS=RESIDUE; echo "STILL ALIVE after root removal: $e" >&2; }; done
      fi
    fi
  else
    echo "run root NOT removed: containment check failed for $ROOT" >&2
  fi
  if [ -e "$ROOT" ]; then ROOT_GONE=no; else ROOT_GONE=yes; fi
  rmdir "$SCRATCH" 2>/dev/null || true # only succeeds if empty
}


# ----------------------------------------------------------- counter access
# cread <relpath>: print a file from the counter's outdir WITHOUT touching the
# sandbox's process set (no podman exec, no sandbox exec). Methods in order:
#  1 /proc/<counter host pid>/root/...   2 plain read of the workspace volume
#  3 the same path read from inside the store's user namespace (podman unshare).
cread_note() { # record the first method that works (and any later change)
  local f=$E/obs/cread-method.txt
  [ "$(tail -n 1 "$f" 2>/dev/null)" = "method $1" ] || echo "method $1 ($(date -u +%FT%TZ))" >>"$f"
}
volmp() { # mountpoint of the sandbox workspace volume (cached on disk: callers run in subshells)
  local c=$E/volmp.cache mp
  [ -n "$SBX_ID" ] || return 1
  if [ "$(cut -d' ' -f1 "$c" 2>/dev/null)" = "$SBX_ID" ]; then cut -d' ' -f2- "$c"; return 0; fi
  local wc
  wc=$(PT=30 P ps -a --filter "label=openshell.ai/sandbox-id=$SBX_ID" --filter "label=openshell.ai/isolation-role=sandbox" --format '{{.ID}}' 2>/dev/null | sed -n '1p')
  [ -n "$wc" ] && mp=$(PT=30 P inspect -f '{{range .Mounts}}{{if eq .Destination "/sandbox"}}{{.Source}}{{end}}{{end}}' "$wc" 2>/dev/null)
  [ -n "$mp" ] || mp=$(PT=30 P volume inspect "openshell-sandbox-$SBX_ID-workspace" -f '{{.Mountpoint}}' 2>/dev/null) || return 1
  [ -n "$mp" ] || return 1
  echo "$SBX_ID $mp" >"$c"
  echo "$mp"
}
cread() {
  local rel=$1 mp
  if [ -n "$HPIDC" ] && alive_same "$HPIDC" "$HSTARTC" && cat "/proc/$HPIDC/root$OUTDIR/$rel" 2>/dev/null; then cread_note 1; return 0; fi
  mp=$(volmp) || return 1
  if cat "$mp/out/$rel" 2>/dev/null; then cread_note 2; return 0; fi
  if tcenv 30 "${PENV[@]}" "$PODMAN" --root "$E/podman/root" --runroot "$E/podman/runroot" unshare cat "$mp/out/$rel" 2>/dev/null; then cread_note 3; return 0; fi
  return 1
}
clog() { cread counter.log; }
last_n() { clog | grep ' COUNT n=' | tail -n 1 | sed 's/.*n=//'; }
ack_line() { clog | grep " ACK $1 pid=" | tail -n 1; }
ack_present() { [ -n "$(ack_line "$1")" ]; }
ackf() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; } # <line> <field>
counter_past() { local n; n=$(last_n); [ "${n:-0}" -ge "$1" ] 2>/dev/null; }
save_out() { # save_out <label>: identity + 60-line counter.log tail, taken via cread
  cread identity >"$E/out/identity-$1.txt" 2>/dev/null
  cread counter.log 2>/dev/null | tail -n 60 >"$E/out/counter-$1.log"
}
save_out_final() { # full log, while the store is still alive (also called early in cleanup)
  [ -s "$E/out/counter-final-full.log" ] && return 0
  [ -n "$SBX_ID" ] && [ -S "$E/podman.sock" ] || return 0
  cread counter.log 2>/dev/null >"$E/out/counter-final-full.log"
}

# ------------------------------------------------- openshell / host identity
sbx_json() { # sbx_json <label>: save `sandbox get -o json`; sets SBX_ID when it parses
  local f=$E/obs/$1-sandbox.json id
  O sandbox get "$GW" -o json >"$f" 2>"$E/obs/$1-sandbox.err" || return 1
  id=$("$JQ" -r '.id // .sandbox.id // empty' "$f" 2>/dev/null)
  [ -n "$id" ] || return 1
  SBX_ID=$id
}
sbx_phase() { "$JQ" -r '.phase // .status.phase // ""' "$E/obs/$1-sandbox.json" 2>/dev/null; }
sbx_ready() { sbx_json poll && [ "$(sbx_phase poll)" = Ready ]; }

find_counter_pid() { # find_counter_pid <container main pid>: the unique counter.sh descendant
  local p par c pc found=()
  while read -r p; do
    [ -n "$p" ] || continue
    c=$(proc_cmd "$p")
    case $c in *"/usr/local/bin/counter.sh"*) ;; *) continue ;; esac
    par=$(ppid_of "$p")
    pc=$(proc_cmd "$par")
    # a forked subshell of the counter has the counter as its parent: skip those
    if [ "$par" != "$1" ]; then case $pc in *"/usr/local/bin/counter.sh"*) continue ;; esac; fi
    found+=("$p")
  done < <(descendants "$1")
  [ "${#found[@]}" -eq 1 ] || return 1
  echo "${found[0]}"
}
find_workload() { # sets CID WPID HPIDC HSTARTC for the sandbox's workload container
  local cids=() w h
  [ -n "$SBX_ID" ] || return 1
  mapfile -t cids < <(P ps --filter status=running --filter "label=openshell.ai/sandbox-id=$SBX_ID" --filter "label=openshell.ai/isolation-role=sandbox" --format '{{.ID}}' 2>/dev/null)
  [ "${#cids[@]}" -eq 1 ] && [ -n "${cids[0]}" ] || return 1
  w=$(P inspect -f '{{.State.Pid}}' "${cids[0]}" 2>/dev/null)
  case $w in '' | *[!0-9]* | 0) return 1 ;; esac
  h=$(find_counter_pid "$w") || return 1
  CID=${cids[0]}; WPID=$w; HPIDC=$h; HSTARTC=$(proc_start "$h")
  track "container-main-$w" "$w"
  track "counter-$h" "$h"
  [ -n "$HSTARTC" ]
}

# ident <label>: identity (i) counter, (ii) openshell, (iii) host -> obs/<label>-identity.txt
ident() {
  local label=$1 f=$E/obs/$1-identity.txt idtxt j=$E/obs/$1-sandbox.json
  local pid start nonce nspid fd0 hstart btime clk hms ms
  sbx_json "$label" || { echo "ident $label: sandbox get failed" >&2; : >"$f"; return 1; }
  CID=; WPID=; HPIDC=; HSTARTC= # never report a stale host pid
  find_workload || echo "ident $label: workload/counter host pid not found" >&2
  idtxt=$(cread identity)
  pid=$(sed -n 's/^pid=//p' <<<"$idtxt")
  start=$(sed -n 's/^start=//p' <<<"$idtxt")
  nonce=$(sed -n 's/^nonce=//p' <<<"$idtxt")
  nspid=; fd0=; hstart=; hms=; ms=
  if [ -n "$HPIDC" ]; then
    nspid=$(awk '/^NSpid:/ {print $NF}' "/proc/$HPIDC/status" 2>/dev/null)
    fd0=$(readlink "/proc/$HPIDC/fd/0" 2>/dev/null || echo unreadable)
    hstart=$(proc_start "$HPIDC")
    btime=$(awk '/^btime/ {print $2}' /proc/stat)
    clk=$(getconf CLK_TCK)
    [ -n "$hstart" ] && hms=$((btime * 1000 + hstart * 1000 / clk))
  fi
  ms=$("$JQ" -r '.main_process_started_at_ms // .status.main_process_started_at_ms // ""' "$j")
  {
    echo "label=$label"
    echo "utc=$(date -u +%FT%TZ)"
    echo "pid=$pid"
    echo "start=$start"
    echo "nonce=$nonce"
    echo "n=$(last_n)"
    echo "sandbox_id=$SBX_ID"
    echo "phase=$("$JQ" -r '.phase // .status.phase // ""' "$j")"
    echo "instance_id=$("$JQ" -r '.main_process_instance_id // .status.main_process_instance_id // ""' "$j")"
    echo "started_at_ms=$ms"
    echo "restart_count=$("$JQ" -r '.restart_count // .status.restart_count // ""' "$j")"
    echo "cid=$CID"
    echo "wpid=$WPID"
    echo "hpid=$HPIDC"
    echo "hstart=$hstart"
    echo "nspid=$nspid"
    echo "fd0=$fd0"
    echo "hstart_ms=$hms"
    echo "delta_ms=$([ -n "$hms" ] && [ -n "$ms" ] && echo $((hms - ms)))"
  } >"$f"
  [ -n "$pid" ] && [ -n "$start" ] && [ -n "$nonce" ] && [ -n "$HPIDC" ] && [ -n "$hstart" ]
}
ident_consistent() { # nspid == counter pid, host start time == counter's own start time
  local f=$E/obs/$1-identity.txt
  [ -n "$(kv "$f" pid)" ] && [ "$(kv "$f" nspid)" = "$(kv "$f" pid)" ] && [ "$(kv "$f" hstart)" = "$(kv "$f" start)" ]
}
ident_wait() { poll "$2" 2 ident_try "$1"; }
ident_try() { ident "$1" 2>/dev/null && ident_consistent "$1"; }
IDENT_KEYS="pid start nonce instance_id started_at_ms hpid hstart"
same_ident() { # same_ident <a> <b>: pid start nonce instance_id started_at_ms hpid hstart all equal
  local k va vb
  for k in $IDENT_KEYS; do
    va=$(kv "$E/obs/$1-identity.txt" "$k")
    vb=$(kv "$E/obs/$2-identity.txt" "$k")
    [ -n "$va" ] && [ "$va" = "$vb" ] || return 1
  done
}
ident_changed() { # true only if some key was collected on both sides and differs (A1-A4 stop condition)
  local k va vb
  for k in $IDENT_KEYS; do
    va=$(kv "$E/obs/$1-identity.txt" "$k")
    vb=$(kv "$E/obs/$2-identity.txt" "$k")
    if [ -n "$va" ] && [ -n "$vb" ] && [ "$va" != "$vb" ]; then return 0; fi
  done
  return 1
}
has_identity() { [ -n "$(cread identity)" ]; }
load_counter_id() { CPID=$(kv "$E/obs/$1-identity.txt" pid); CSTART=$(kv "$E/obs/$1-identity.txt" start); CNONCE=$(kv "$E/obs/$1-identity.txt" nonce); }

# ----------------------------------------------------------------- panes
pane_ids() { H pane list | "$JQ" -r '.result.panes[].pane_id'; }
pane_shell_known() { # pane_shell_known <pane> -> sets PSHELL (the pane's shell pid, from herdr)
  PSHELL=$(H pane process-info --pane "$1" 2>/dev/null | "$JQ" -r '.result.process_info.shell_pid // empty' 2>/dev/null)
  [[ $PSHELL =~ ^[0-9]+$ ]]
}
new_attach() { # new_attach <shell-pid> <attached cli pids before>: a NEW complete chain whose cli descends from the pane's shell; sets ATT
  local c cs s ss x xs
  while read -r _ c cs s ss x xs; do
    case " $2 " in *" $c "*) continue ;; esac
    ancestors "$c" | grep -xF "$1" >/dev/null || continue
    ATT="$c:$cs $s:$ss $x:$xs"
    return 0
  done < <(client_snap | grep '^attached ')
  return 1
}
pane_attach() { # pane_attach <label> -> sets PANE, ATT; a NEW pane whose `openshell sandbox connect` chain is up
  local label=$1 plist base before
  plist=$(pane_ids)
  if [ -z "$plist" ]; then
    PANE=$(H workspace create --cwd "$E" --label demo --no-focus | "$JQ" -r '.result.root_pane.pane_id')
  else
    base=$(sed -n '1p' <<<"$plist")
    PANE=$(H pane split "$base" --direction right --cwd "$E" --no-focus | "$JQ" -r '.result.pane.pane_id')
  fi
  [ -n "$PANE" ] && [ "$PANE" != null ] || { echo "could not create pane" >&2; return 1; }
  PSHELL=
  ATT=
  poll 5 0.5 pane_shell_known "$PANE" || { echo "no shell pid for $PANE" >&2; attach_diag "$label"; return 1; }
  before=$(client_snap | awk '$1 == "attached" { print $2 }' | tr '\n' ' ')
  H pane run "$PANE" "$E/wrap/openshell -g $GW sandbox connect $GW" >/dev/null
  if ! wait_for 20 new_attach "$PSHELL" "$before"; then
    echo "no new cli -> ssh -> proxy chain under $PANE's shell $PSHELL ($(client_counts))" >&2
    attach_diag "$label"
    return 1
  fi
  PANE_CLIENT[$PANE]=$ATT
  log "pane $PANE ($label): attached cli/ssh/proxy=$ATT under shell $PSHELL ($(client_counts))"
}
# attach_diag <label>: appended to obs/attach-<label>.txt, redacted. Run-scoped processes only
# (unrelated ones are counted, never described); ssh/proxy argv carry --token, which redact masks.
attach_diag() {
  local p tree=()
  if [[ ${PSHELL:-} =~ ^[0-9]+$ ]]; then mapfile -t tree < <({ echo "$PSHELL"; descendants "$PSHELL"; }); fi
  {
    echo "# attach diagnostics $1: pane=$PANE shell=${PSHELL:-unknown} $(date -u +%FT%TZ)"
    echo "## counts: $(client_counts)"
    echo "## run-scoped client processes (class pid start ppid) and chains"
    client_snap | awk '$1 != "other"'
    echo "## pane process-info"
    H pane process-info --pane "$PANE" 2>&1 | "$JQ" -c '.result.process_info|{shell_pid,fg:[.foreground_processes[]|.cmdline]}' 2>&1
    if [ "${#tree[@]}" -gt 0 ]; then
      echo "## process tree under the pane shell: exe paths, then ps"
      for p in "${tree[@]}"; do echo "$p ppid=$(ppid_of "$p") start=$(proc_start "$p") exe=$(readlink "/proc/$p/exe" 2>/dev/null)"; done
      ps -ww -o pid,ppid,pgid,lstart,args -p "$(IFS=,; echo "${tree[*]}")" 2>&1
    fi
    echo "## gateway SSH-session / relay log lines (last 20)"
    grep -E 'CreateSshSession|ForwardTcp|relay' "$E/logs/gateway.log" 2>/dev/null | tail -n 20
    echo "## pane visible text"
    H pane read "$PANE" --source visible --lines 40 2>&1
    echo "## pane recent text (last 80 of 300 lines)"
    H pane read "$PANE" --source recent --lines 300 2>&1 | tail -n 80
  } 2>&1 | redact >>"$E/obs/attach-$1.txt"
}
close_all_panes() {
  local p plist=()
  mapfile -t plist < <(pane_ids)
  for p in "${plist[@]}"; do [ -n "$p" ] && H pane close "$p" >/dev/null 2>&1; done
  wait_for 15 no_client_procs
}
type_line() { H pane send-text "$1" "$2" >/dev/null; H pane send-keys "$1" Enter >/dev/null; } # <pane> <text>
# >>> pane-ack
# Pane checks that tolerate terminal wrapping (run 3: A4b's ACK wrapped onto three rows of a
# 27-column pane and the exact-line grep failed). Raw captures are kept as read.
#
# ack_rows_match <capture> <expected>: the complete expected line is in the capture, either as one
# whole row, or as exactly the rows a terminal of width W shows when it soft-wraps that line from
# column 0: every row but the last is the next W characters, right-trimmed as captures are (a wrap
# just after a space loses the space). W comes from the candidate first row (its length, or one
# more for a trimmed space), never from other output. Other text between or around the rows, a
# partial line, or any other identity cannot match. Prints "line" or "wrapped:<W>:<rows>".
ack_rows_match() {
  [ -n "${2:-}" ] && [ -r "${1:-}" ] || return 1
  awk -v e="$2" -v minw=8 '
    { sub(/\r$/, ""); sub(/[ \t]+$/, ""); r[NR] = $0 }
    END {
      le = length(e)
      for (i = 1; i <= NR; i++) {
        if (r[i] == e) { print "line"; exit 0 }
        l = length(r[i])
        if (l < minw || l >= le || substr(e, 1, l) != r[i]) continue
        for (w = l; w <= l + 1; w++) {
          ok = 1; k = 0
          for (p = 1; p <= le; p += w) {
            c = substr(e, p, w); sub(/ +$/, "", c)
            if (i + k > NR || r[i + k] != c) { ok = 0; break }
            k++
          }
          if (ok && k > 1) { print "wrapped:" w ":" k; exit 0 }
        }
      }
      exit 1
    }' "$1"
}
# text_rows_seen <capture> <text>: <text> as a substring of one row, or as a whole wrapped line
text_rows_seen() { [ -n "${2:-}" ] && [ -r "${1:-}" ] || return 1; grep -F -- "$2" "$1" >/dev/null 2>&1 || ack_rows_match "$1" "$2" >/dev/null; }
PANE_SOURCES="unwrapped recent visible"
pane_cap() { case $2 in visible) echo "$E/panes/$1.txt" ;; *) echo "$E/panes/$1-$2.txt" ;; esac; } # <tag> <source>
# pane_capture <pane> <tag>: visible (panes/<tag>.txt, as in runs 1-3), recent scrollback, and
# Herdr 0.9.5's recent-unwrapped (soft wraps joined by its terminal emulator). Overwritten per poll.
pane_capture() {
  H pane read "$1" --source visible --lines 40 >"$(pane_cap "$2" visible)" 2>&1
  H pane read "$1" --source recent --lines 300 >"$(pane_cap "$2" recent)" 2>&1
  H pane read "$1" --source recent-unwrapped --lines 300 >"$(pane_cap "$2" unwrapped)" 2>&1
  return 0 # a failed read leaves an error text in that capture, which cannot match; the others still count
}
# caps_ack <tag> <expected>: per-source result lines for the saved captures; true if any matched
caps_ack() {
  local s m hit=1
  for s in $PANE_SOURCES; do
    if m=$(ack_rows_match "$(pane_cap "$1" "$s")" "$2"); then echo "source=$s match=$m"; hit=0; else echo "source=$s match=none"; fi
  done
  return "$hit"
}
caps_text() { local s; for s in $PANE_SOURCES; do text_rows_seen "$(pane_cap "$1" "$s")" "$2" && return 0; done; return 1; } # <tag> <text>
pane_ack_seen() { pane_capture "$1" "$2" && caps_ack "$2" "$3" >/dev/null; }    # <pane> <tag> <expected>
pane_text_seen() { pane_capture "$1" "$2" && caps_text "$2" "$3"; }              # <pane> <tag> <text>
# ack_expected <word>: the complete ACK the counter prints for the CURRENT identity (CPID CSTART
# CNONCE) with the log's n. Empty if the identity is not loaded or the log has no such ACK.
ack_expected() {
  local n
  [ -n "$CPID" ] && [ -n "$CSTART" ] && [ -n "$CNONCE" ] || return 1
  n=$(ackf "$(ack_line "$1")" n)
  [[ $n =~ ^[0-9]+$ ]] || return 1
  echo "ACK $1 pid=$CPID start=$CSTART nonce=$CNONCE n=$n"
}
mark() { # mark <pane> <word> [log-wait-s]: type "mark <word>"; wait for the ACK in the log (rc 1), then the complete ACK in the pane (rc 2)
  local pane=$1 w=$2 exp
  type_line "$pane" "mark $w"
  wait_for "${3:-15}" ack_present "$w" || return 1
  exp=$(ack_expected "$w") || { pane_capture "$pane" "$w"; return 2; }
  poll 10 0.5 pane_ack_seen "$pane" "$w" "$exp" || return 2
  return 0
}
# verify_ack <word> <min-n-exclusive> -> sets ACKN. The log's ACK line is exactly the expected ACK for
# the current identity with n > min, and the saved captures of the pane show that complete ACK.
# Per-source results go to obs/ack-<word>.txt.
verify_ack() {
  local line exp rc=0 res
  ACKN=
  line=$(ack_line "$1")
  exp=$(ack_expected "$1") || rc=1
  ACKN=$(ackf "$line" n)
  [ "$rc" = 0 ] && [ "${line#* * }" = "$exp" ] && [ "$ACKN" -gt "$2" ] 2>/dev/null || rc=1
  res=$(caps_ack "$1" "$exp") || rc=1
  { echo "word=$1 expected=${exp:-<none: identity not loaded or no ACK in the log>} min_n_exclusive=$2"
    echo "log: ${line:-<none>}"
    echo "$res"
    echo "verify=$([ "$rc" = 0 ] && echo pass || echo fail)"; } | redact >"$E/obs/ack-$1.txt"
  return "$rc"
}
# <<< pane-ack
ticks_min() { grep -o 'tick n=[0-9]*' | sed 's/.*=//' | sort -n | sed -n '1p'; }
ticks_last() { grep -o 'tick n=[0-9]*' | tail -n 1 | sed 's/.*=//'; }

# ------------------------------------------------------------- herdr server
start_herdr() { # start_herdr <label>: headless server as a pod entrypoint would run it
  setsid env -i "${CENV_VARS[@]}" "$HERDR_BIN" server >>"$E/logs/herdr-stdout.log" 2>&1 </dev/null &
  HERDR_PID=$!
  wait_for 15 Hraw status server >/dev/null 2>&1 || { echo "herdr server did not start" >&2; return 1; }
  guard || return 1
  # $! must really be the server: exec chain setsid->env->herdr keeps the PID.
  proc_cmd "$HERDR_PID" | grep 'herdr.* server' >/dev/null || { echo "recorded PID $HERDR_PID is not herdr server" >&2; return 1; }
  proc_env_has "$HERDR_PID" "XDG_CONFIG_HOME=$E/config" || { echo "PID $HERDR_PID is not our server" >&2; return 1; }
  track "herdr-server-$1" "$HERDR_PID"
  HERDR_START=$(proc_start "$HERDR_PID")
  tr '\0' '\n' <"/proc/$HERDR_PID/environ" | cut -d= -f1 | sort >"$E/server-env-keys-$1.txt"
  if grep -E '^(HERDR_(SOCKET_PATH|SESSION|PANE_ID|ENV|TAB_ID|WORKSPACE_ID|BIN_PATH)$|SSH_AUTH_SOCK|TMUX$|CLAUDE|OPENSHELL_GATEWAY|DBUS_SESSION_BUS_ADDRESS|GNUPGHOME)' "$E/server-env-keys-$1.txt" >/dev/null; then
    echo "controller variables leaked into herdr server" >&2; return 1
  fi
  log "herdr server ($1) pid=$HERDR_PID start=$HERDR_START"
}
stop_herdr_clean() { guard || return 1; H server stop >/dev/null; }

# --------------------------------------------------------------- gateway
GWENV=("OPENSHELL_PODMAN_SOCKET=$E/podman.sock" "OPENSHELL_SANDBOX_RUNTIME_IMAGE=$RT_IMG"
  "OPENSHELL_SUPERVISOR_IMAGE=$SUP_IMG" "OPENSHELL_LOCAL_TLS_DIR=$E/tls")
GWARGS=(--name "$GW" --bind-address 127.0.0.1 --port "$PORT" --compute-driver podman
  --db-url "sqlite:$E/state/gw.db?mode=rwc" --config "$E/gateway.toml"
  --tls-cert "$E/tls/server/tls.crt" --tls-key "$E/tls/server/tls.key" --tls-client-ca "$E/tls/ca.crt")

exe_is() { [ "$(readlink "/proc/$1/exe" 2>/dev/null)" = "$2" ]; } # the exec chain setsid->env->binary keeps the pid
gw_listening() { # exactly one listener on the port, 127.0.0.1:$PORT, owned by our gateway pid
  local out
  out=$("$SS" -Htlnp "sport = :$PORT" 2>/dev/null) || return 1
  [ "$(grep -c . <<<"$out")" = 1 ] || return 1
  [ "$(awk '{print $4}' <<<"$out")" = "127.0.0.1:$PORT" ] || return 1
  grep "pid=$GWPID," <<<"$out" >/dev/null
}
start_gateway() { # start_gateway <label>
  local i
  case "${GWARGS[*]} ${GWENV[*]}" in *disable-tls* | *DISABLE_TLS*) log "refusing: --disable-tls is never allowed"; return 1 ;; esac
  (umask 022; exec setsid env -i "${CENV_VARS[@]}" "${GWENV[@]}" "$GW_BIN" "${GWARGS[@]}") >>"$E/logs/gateway.log" 2>&1 </dev/null &
  GWPID=$!
  track "$1" "$GWPID"
  GWSTART=$(proc_start "$GWPID")
  wait_for 5 exe_is "$GWPID" "$GW_REAL" || { log "recorded PID $GWPID is not the gateway binary"; return 1; }
  proc_env_has "$GWPID" "XDG_RUNTIME_DIR=$E/run" || { log "gateway $GWPID lacks the run environment"; return 1; }
  case $(proc_cmd "$GWPID") in *disable-tls*) log "gateway argv contains disable-tls"; return 1 ;; esac
  for ((i = 0; i < 300; i++)); do
    gw_listening && { log "gateway ($1) pid=$GWPID start=$GWSTART listening on 127.0.0.1:$PORT"; return 0; }
    alive_same "$GWPID" "$GWSTART" || { log "gateway ($1) exited early"; return 1; }
    sleep 0.2
  done
  log "gateway ($1) did not listen exclusively on 127.0.0.1:$PORT within 60s"
  return 1
}
gw_registry_ok() { # the wrapper's own guard conditions, evaluated here too
  # shellcheck disable=SC2016 # $gw/$ep are jq variables (--arg), not shell expansions
  "$JQ" -e --arg gw "$GW" --arg ep "https://127.0.0.1:$PORT" '
    type == "array" and ([.[] | select(.name == $gw and .endpoint == $ep and .source == "user")] | length) == 1
    and ([.[] | select(.source == "system")] | length) == 0' "$1" >/dev/null 2>&1
}

# =============================================================== P3 (gate)
p3() { # p3 <item> <function>: every P3 item must pass or the run stops
  if "$2"; then echo "PASS $1" >>"$E/obs/p3-checks.txt"; log "P3 PASS $1"
  else echo "FAIL $1" >>"$E/obs/p3-checks.txt"; record "P3-$1" FAIL "P3 gate failed"; stop "P3 $1"; fi
}
p_empty() { local out; out=$(P "$@") || return 1; [ -z "$out" ]; }

p3_tools() { # herdr must be the 0.9.5 that the `pane read --source` semantics were checked against
  tcenv 10 "$HERDR_BIN" --version 2>&1 | grep '0\.9\.5' >/dev/null && [ -x "$E/wrap/openshell" ] && [ -x "$E/wrap/ssh" ]
}
p3_baseline() { baseline "$E/obs/B1" && [ -f "$E/obs/B1/SHA256SUMS" ]; }
p3_conf() {
  # Pre-registered: systemd cgroup manager over the user bus (the OpenShell Podman driver sets
  # CPU/memory/pids limits by default); store, socket and runtime dir stay isolated.
  printf '[engine]\ncgroup_manager = "systemd"\nevents_logger = "file"\n' >"$E/config/containers/containers.conf"
  printf '[storage]\ndriver = "overlay"\ngraphroot = "%s"\nrunroot = "%s"\n' "$E/podman/root" "$E/podman/runroot" >"$E/config/containers/storage.conf"
}
p3_service() {
  # umask 022: volumes and layers must stay usable by the container's (subuid) user; $E itself is 0700
  (umask 022; exec setsid env -i "${CENV_VARS[@]}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus" "${PENV[@]}" "$PODMAN" \
    --root "$E/podman/root" --runroot "$E/podman/runroot" system service --time=0 "unix://$E/podman.sock") \
    >>"$E/logs/podman-service.log" 2>&1 </dev/null &
  PS_PID=$!
  track podman-service "$PS_PID"
  PS_ENTRY=$LAST_TRACK
  wait_for 5 exe_is "$PS_PID" "$(realpath -e "$PODMAN")" || return 1
  proc_env_has "$PS_PID" "XDG_RUNTIME_DIR=$E/run" || return 1
  proc_env_has "$PS_PID" "${PENV[@]}" || return 1
  wait_for 15 test -S "$E/podman.sock"
}
p3_store() {
  local f=$E/obs/p3-podman.txt
  PT=60 P info -f json >"$E/info-raw.json" 2>"$E/obs/p3-info.err" || return 1
  {
    echo "graphRoot=$("$JQ" -r '.store.graphRoot' "$E/info-raw.json")"
    echo "runRoot=$("$JQ" -r '.store.runRoot' "$E/info-raw.json")"
    echo "rootless=$("$JQ" -r '.host.security.rootless' "$E/info-raw.json")"
    echo "cgroupManager=$("$JQ" -r '.host.cgroupManager' "$E/info-raw.json")"
    echo "cgroupVersion=$("$JQ" -r '.host.cgroupVersion' "$E/info-raw.json")"
    echo "ociRuntime=$("$JQ" -r '.host.ociRuntime.name' "$E/info-raw.json")"
    echo "networkBackend=$("$JQ" -r '.host.networkBackend' "$E/info-raw.json")"
    echo "version=$("$JQ" -r '.version.Version' "$E/info-raw.json")"
  } >"$f"
  [ "$(kv "$f" graphRoot)" = "$E/podman/root" ] && [ "$(kv "$f" runRoot)" = "$E/podman/runroot" ] &&
    [ "$(kv "$f" rootless)" = true ] && [ "$(kv "$f" cgroupVersion)" = v2 ] || return 1
  p_empty ps -a -q && p_empty volume ls -q && p_empty secret ls -q && p_empty images -q || return 1
  [ "$(P network ls --format '{{.Name}}' 2>/dev/null)" = podman ] || return 1
  {
    echo "owner default-store counts (from B1; the dedicated socket must not see them):"
    awk '/^## / {s = $2; next} NF {c[s]++} END {for (k in c) print "  " k ": " c[k]}' "$E/obs/B1/podman-default.txt"
    echo "dedicated store: containers=0 volumes=0 secrets=0 images=0 networks=podman"
  } >"$E/obs/p3-store-isolation.txt"
}
p3_socket() {
  local line pid
  line=$("$SS" -xlpn 2>/dev/null | grep -F " $E/podman.sock ")
  pid=$(sed -n 's/.*pid=\([0-9]*\),.*/\1/p' <<<"$line" | sed -n '1p')
  echo "listener: ${line:-none}" >"$E/obs/p3-socket.txt"
  [ -n "$pid" ] || return 1
  # rootless podman re-executes in its user namespace: the listener may be a child of the launched pid
  if [ "$pid" != "$PS_PID" ] && ! descendants "$PS_PID" | grep -x "$pid" >/dev/null; then return 1; fi
  proc_env_has "$pid" "XDG_RUNTIME_DIR=$E/run" || return 1
  # the effective service environment (the listener may be the re-executed child) must carry the correction
  proc_env_has "$pid" "${PENV[@]}" || return 1
  echo "effective service env: $(tr '\0' '\n' <"/proc/$pid/environ" | grep -xF "${PENV[0]}")" >"$E/obs/p3-service-env.txt"
  if [ "$pid" != "$PS_PID" ]; then track podman-service-listener "$pid"; PSL_ENTRY=$LAST_TRACK; fi
  { echo "listener pid=$pid (launched pid=$PS_PID)"; echo "peers:"; unix_peers "$pid"; } >>"$E/obs/p3-socket.txt"
  ! unix_peers "$pid" | grep -F "/run/user/$UID_/podman/podman.sock" >/dev/null
}
p3_pull() {
  local ref dig out
  [ ! -e "$E/run/containers/auth.json" ] || return 1
  for ref in "$WORKLOAD" "$RT_IMG" "$SUP_IMG"; do
    PT=900 P pull "$ref" >>"$E/obs/p3-pull.out" 2>&1 || return 1
    out=$(P image inspect -f '{{.Id}} {{.Digest}} {{json .RepoDigests}}' "$ref" 2>&1) || return 1
    echo "$ref -> $out" >>"$E/obs/pulled-images.txt"
    dig=${ref##*@}
    grep -F "$dig" <<<"$out" >/dev/null || return 1
  done
  [ ! -e "$E/run/containers/auth.json" ]
}
p3_probe() { # protects the single A1 attempt: the driver applies cgroup limits by default
  PT=180 P run --rm --name "exp008-probe-$RUN" --memory 256m --cpus 1 --pids-limit 100 --network none \
    --entrypoint /bin/true "$WORKLOAD" >"$E/obs/p3-probe.out" 2>&1 || return 1
  p_empty ps -a -q
}
# Healthcheck probe (owner-required for the retry). A disposable container created through the dedicated
# socket with the driver's exact workload healthconfig (container.rs:1379-1394, test overridden to NONE at
# :1674) and the driver's libpod API version (client.rs:21). It must create and start with no systemd
# healthcheck timer and no change to the owner's user unit files; its health status is recorded for the gate.
HC_NAME=exp008-hcprobe-$RUN
HC_FILE=$E/obs/p3-hc-health.txt
api() { # api <METHOD> <path> [curl args]: libpod REST on the dedicated socket; prints the body, then "http=<code>"
  local m=$1 path=$2
  shift 2
  tcenv 60 "$CURL" -q -sS --max-time 50 --unix-socket "$E/podman.sock" -X "$m" -H 'Content-Type: application/json' \
    -w '\nhttp=%{http_code}\n' "$@" "http://d/v5.0.0$path"
}
user_units() { timeout -k 5 30 systemctl --user list-units --all --no-legend --plain 2>/dev/null | awk '{print $1}' | LC_ALL=C sort; }
unit_files_sum() { find "$HOME/.config/systemd/user" -printf '%P\t%y\t%s\t%T@\n' 2>&1 | LC_ALL=C sort | sha256sum | cut -d' ' -f1; }
hc_state() { # hc_state <tag> <cid>
  local j
  j=$(P inspect -f '{{json .State}}' "$2" 2>>"$E/obs/p3-hc-probe.txt") || return 1
  {
    echo "state_$1=$("$JQ" -c '{Status, Running, Health}' <<<"$j")"
    echo "status_$1=$("$JQ" -r '.Health.Status // "absent"' <<<"$j")" # Health is omitted when HasHealthCheck() is false
    echo "running_$1=$("$JQ" -r '.Running' <<<"$j")"
  } >>"$HC_FILE"
}
p3_hc_probe() {
  local f=$E/obs/p3-hc-probe.txt slog=$E/obs/p3-hc-service-log.txt spec cid l0 u0 u1 uf0 tr0 tr1 bad=0
  # shellcheck disable=SC2016 # jq variables
  spec=$("$JQ" -cn --arg n "$HC_NAME" --arg i "$WORKLOAD" '{name: $n, image: $i, entrypoint: ["/bin/sleep"], command: ["40"],
    netns: {nsmode: "none"}, image_pull_policy: "never",
    healthconfig: {test: ["NONE"], Interval: 10000000000, Timeout: 2000000000, Retries: 10, StartPeriod: 5000000000}}') || return 1
  l0=$(wc -l <"$E/logs/podman-service.log")
  u0=$(user_units)
  uf0=$(unit_files_sum)
  tr0=$(find "/run/user/$UID_/systemd/transient" -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
  { echo "# create spec"; echo "$spec"; echo "# create"; api POST /libpod/containers/create -d "$spec"; } >"$f" 2>&1
  [ "$(tail -n 1 "$f")" = http=201 ] || return 1
  cid=$(sed -e '1,/^# create$/d' -e '/^http=/d' "$f" | "$JQ" -r '.Id // empty' 2>/dev/null) # body may be multi-line
  [[ $cid =~ ^[0-9a-f]{64}$ ]] || return 1
  echo "cid=$cid" >"$HC_FILE"
  echo "config_healthcheck=$(P inspect -f '{{json .Config.Healthcheck}}' "$cid" 2>&1)" >>"$HC_FILE"
  { echo "# start"; api POST "/libpod/containers/$cid/start"; } >>"$f" 2>&1
  [ "$(tail -n 1 "$f")" = http=204 ] || bad=1
  if [ "$bad" = 0 ]; then
    sleep 1; hc_state 1s "$cid" || bad=1
    sleep 11; hc_state 12s "$cid" || bad=1 # past the 5 s start period and one 10 s interval
    [ "$(kv "$HC_FILE" running_12s)" = true ] || bad=1
  fi
  u1=$(user_units)
  tr1=$(find "/run/user/$UID_/systemd/transient" -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
  # removal is attempted whatever happened above (the probe must never be left behind)
  { echo "# delete"; api DELETE "/libpod/containers/$cid?force=true&timeout=0&v=true"; } >>"$f" 2>&1
  case $(tail -n 1 "$f") in http=200 | http=204) ;; *) bad=1 ;; esac
  tail -n +"$((l0 + 1))" "$E/logs/podman-service.log" >"$slog" 2>/dev/null
  {
    # healthcheck timers/services are named after the container id; the systemd cgroup scope
    # (libpod-<cid>.scope, pre-registered correction 5) is reported separately and must be gone after removal
    echo "hc_units_during=$(grep -F "$cid" <<<"$u1" | grep -vc '^libpod-.*\.scope$')"
    echo "scope_units_during=$(grep -F "$cid" <<<"$u1" | grep -c '^libpod-.*\.scope$')"
    echo "new_user_units_during=$(comm -13 <(printf '%s\n' "$u0") <(printf '%s\n' "$u1") | grep -c .)"
    echo "transient_files_with_cid=$(comm -13 <(printf '%s\n' "$tr0") <(printf '%s\n' "$tr1") | grep -F "$cid" | grep -vc '^libpod-.*\.scope$')"
    echo "transient_scope_files_during=$(comm -13 <(printf '%s\n' "$tr0") <(printf '%s\n' "$tr1") | grep -F "$cid" | grep -c '^libpod-.*\.scope$')"
    echo "service_log_hc_lines=$(grep -ciE 'healthcheck|health check|\.timer|unable to get systemd' "$slog")"
    echo "service_log_lines=$(grep -c . "$slog")"
    echo "run_systemd_dir_exists=$([ -e "$E/run/systemd" ] && echo yes || echo no)"
  } >>"$HC_FILE"
  [ "$bad" = 0 ] || return 1
  # pre-registered from the source review: "unhealthy" maps to HealthCheckFailed (sticky Error phase), and
  # nothing should change the status of a NONE healthcheck; either one stops the run before A1
  [ "$(kv "$HC_FILE" status_1s)" = "$(kv "$HC_FILE" status_12s)" ] && [ "$(kv "$HC_FILE" status_12s)" != unhealthy ] || return 1
  [ "$(kv "$HC_FILE" hc_units_during)" = 0 ] && [ "$(kv "$HC_FILE" transient_files_with_cid)" = 0 ] &&
    [ "$(kv "$HC_FILE" service_log_hc_lines)" = 0 ] && [ "$(kv "$HC_FILE" run_systemd_dir_exists)" = no ] || return 1
  # nothing of the probe remains: container, volumes, cgroup scope; owner unit files unchanged
  p_empty ps -a -q && p_empty volume ls -q || return 1
  # shellcheck disable=SC2016 # expanded by eval, inside this function's scope
  poll 15 1 eval '! user_units | grep -F "$cid" >/dev/null' || return 1
  [ "$(unit_files_sum)" = "$uf0" ] || return 1
  echo "after_removal=containers:0 volumes:0 units_with_cid:0 user_unit_files:unchanged" >>"$HC_FILE"
}
# Owner-required: the observed health status is assessed against OpenShell's Ready logic BEFORE A1.
# The harness waits (bounded) for the orchestrator's decision in $ROOT/hc-gate: exactly "proceed" or "stop".
p3_hc_gate() {
  local g=$ROOT/hc-gate d
  cp "$HC_FILE" "$ROOT/hc-gate.request" || return 1
  log "HC-GATE waiting up to 600s for $g (status_1s=$(kv "$HC_FILE" status_1s) status_12s=$(kv "$HC_FILE" status_12s))"
  poll 600 2 test -s "$g" || { echo "decision=timeout" >>"$HC_FILE"; return 1; }
  [ -f "$g" ] && [ ! -L "$g" ] && [ "$(stat -c %u "$g")" = "$UID_" ] || { echo "decision=invalid-file" >>"$HC_FILE"; return 1; }
  d=$(head -c 16 "$g" | tr -cd '[:lower:]')
  echo "decision=$d (t+${SECONDS}s)" >>"$HC_FILE"
  log "HC-GATE decision: $d"
  [ "$d" = proceed ]
}
p3_tls() {
  tcenv 60 "$GW_BIN" generate-certs --output-dir "$E/tls" >"$E/obs/p3-certs.out" 2>&1 || return 1
  { echo "tls dir (names only):"; find "$E/tls" -printf '%P\t%y\n' | LC_ALL=C sort
    echo "under config (names only):"; find "$E/config" -printf '%P\t%y\n' | LC_ALL=C sort; } >"$E/obs/p3-tls-names.txt"
  # layout: ca.crt ca.key server/tls.{crt,key} client/tls.{crt,key} jwt/{signing.pem,public.pem,kid}
  local f
  for f in ca.crt server/tls.crt server/tls.key client/tls.crt client/tls.key; do [ -s "$E/tls/$f" ] || return 1; done
  [ -d "$E/tls/jwt" ] && [ -n "$(find "$E/tls/jwt" -type f)" ]
}
p3_toml() {
  printf '[openshell]\nversion = 2\n[openshell.drivers.podman]\nnetwork_name = "%s"\n[openshell.drivers.podman.resource_admission]\nenabled = false\n' "$GW" >"$E/gateway.toml"
}
p3_preflight() { # no --disable-tls, ever
  case "${GWARGS[*]}" in *disable-tls*) return 1 ;; esac
  tcenv 60 "${GWENV[@]}" "$GW_BIN" config preflight -- "${GWARGS[@]}" >"$E/obs/p3-preflight.out" 2>&1
}
p3_gateway() { start_gateway "gateway-$((++GW_COUNT))"; }
p3_register() {
  tcenv 30 "OPENSHELL_LOCAL_TLS_DIR=$E/tls" "$E/wrap/openshell" gateway add "https://127.0.0.1:$PORT" --local --name "$GW" >"$E/obs/p3-gateway-add.out" 2>&1 || return 1
  tcenv 30 "$E/wrap/openshell" gateway list -o json >"$E/obs/gateway-list.json" 2>"$E/obs/gateway-list.err" || return 1
  gw_registry_ok "$E/obs/gateway-list.json" || return 1
  O status -o json >"$E/obs/status-a.json" 2>"$E/obs/status-a.err" # mTLS round trip
}
p3_mtls_negative() { # informational only
  tcenv 10 "$CURL" -q -sS --max-time 5 --cacert "$E/tls/ca.crt" -o /dev/null -w 'http=%{http_code}\n' "https://127.0.0.1:$PORT/" >"$E/obs/p3-mtls-negative.txt" 2>&1
  echo "curl exit=$? (informational: expect handshake/auth failure without a client certificate)" >>"$E/obs/p3-mtls-negative.txt"
  return 0
}
p3_ssh() {
  local f=$E/obs/ssh-G.txt
  tcenv 10 "$E/wrap/ssh" -G sandbox >"$f" 2>&1 || return 1
  grep -x 'identityagent none' "$f" >/dev/null && grep -x 'identitiesonly yes' "$f" >/dev/null &&
    grep -x 'identityfile none' "$f" >/dev/null && [ "$(grep '^identityfile ' "$f" | grep -vcx 'identityfile none')" = 0 ] &&
    grep -x 'userknownhostsfile /dev/null' "$f" >/dev/null
}
p3_herdr() {
  cat >"$E/config/herdr/config.toml" <<EOF
onboarding = false

[update]
version_check = false
manifest_check = false

[terminal]
default_shell = "$E/pane-shell"
shell_mode = "non_login"
EOF
  cat >"$E/pane-shell" <<EOF
#!/bin/sh
exec /usr/bin/bash --noprofile --rcfile "$E/pane-bashrc" -i "\$@"
EOF
  chmod +x "$E/pane-shell"
  cat >"$E/pane-bashrc" <<EOF
export HISTFILE=/dev/null
PS1='\$ '
unset PROMPT_COMMAND
EOF
  start_herdr initial && p3_pane_env
}
# A pane shell must see exactly the run's HOME/XDG/PATH, or the guard wrapper would refuse the
# one A1 `connect` (no sandbox exists yet, so finding this out now costs nothing).
p3_pane_env() {
  local pane f=$E/obs/pane-env-check.txt
  pane=$(H workspace create --cwd "$E" --label envcheck --no-focus | "$JQ" -r '.result.root_pane.pane_id')
  [ -n "$pane" ] && [ "$pane" != null ] || return 1
  H pane run "$pane" "{ printenv HOME XDG_CONFIG_HOME OPENSHELL_SYSTEM_GATEWAY_DIR PATH; command -v openshell; command -v ssh; } >$f.tmp 2>&1; mv $f.tmp $f" >/dev/null || return 1
  wait_for 10 test -s "$f" || return 1
  H pane close "$pane" >/dev/null 2>&1
  # PATH itself is recorded but not required verbatim (Herdr may extend it); what matters is resolution
  [ "$(sed -n '1p;2p;3p;5p;6p' "$f")" = "$E/home
$E/config
$E/etc-openshell
$E/wrap/openshell
$E/wrap/ssh" ] && case "$(sed -n '4p' "$f")" in "$E/wrap:"*) true ;; *) false ;; esac
}

# ============================================== layout, traps, wrappers (first mutation)
# Traps: signals become a non-zero exit so the EXIT trap (cleanup) runs exactly once.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap cleanup EXIT

mkdir -m 0700 "$E" || refuse "cannot create $E"
OWN_E=1 # from here on the cleanup may remove $ROOT
for d in home config state data run etc-openshell wrap tls podman/root podman/runroot logs out panes snaps obs config/herdr config/containers; do
  mkdir -p "$E/$d" || stop "cannot create $E/$d"
done
chmod -R go-rwx "$E"
: >"$RESULTS"
: >"$TIMELINE"
log "run $RUN root=$ROOT port=$PORT gateway=$GW budget=${BUDGET}s"

# Watchdog: SIGTERM ourselves after the budget (cleanup then runs). Its sleep is killed with it.
WD_PARENT=$$
(
  sleep "$BUDGET" &
  sp=$!
  trap 'kill "$sp" 2>/dev/null; exit 0' TERM
  wait "$sp" && kill -TERM "$WD_PARENT"
) >/dev/null 2>&1 &
track watchdog $!
WD_ENTRY=$LAST_TRACK

# -------------------------------------------------------------- wrappers
cat >"$E/ssh_config" <<EOF
Host *
    IdentityAgent none
    IdentitiesOnly yes
    IdentityFile none
    PKCS11Provider none
    ForwardAgent no
    ForwardX11 no
    GSSAPIAuthentication no
    HostbasedAuthentication no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UserKnownHostsFile /dev/null
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking no
    UpdateHostKeys no
    VerifyHostKeyDNS no
EOF
# ssh wrapper: `openshell sandbox connect` runs `ssh` found via PATH. OpenSSH
# reads the passwd home's ~/.ssh/config (not $HOME's), so force an empty config.
cat >"$E/wrap/ssh" <<EOF
#!/usr/bin/bash
exec /usr/bin/ssh -F "$E/ssh_config" -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile=none -o PKCS11Provider=none -o ForwardAgent=no "\$@"
EOF
# openshell guard wrapper: E, PORT, GW and the real binary are baked in at write time.
cat <<'EOF' | sed -e "s#@E@#$E#g" -e "s#@PORT@#$PORT#g" -e "s#@GW@#$GW#g" -e "s#@REAL@#$CLI_REAL#g" >"$E/wrap/openshell"
#!/usr/bin/bash
# EXP-008 openshell guard (generated by demo.sh). Refuses anything not addressed
# to this run's loopback gateway or not running with this run's isolated config.
set -u
set -o pipefail
E='@E@'
PORT='@PORT@'
GW='@GW@'
REAL='@REAL@'
JQ=/usr/bin/jq
PRINTENV=/usr/bin/printenv
die() { echo "openshell-guard: REFUSED: $*" >&2; exit 99; }
[ "${XDG_CONFIG_HOME:-}" = "$E/config" ] || die "XDG_CONFIG_HOME is not the run's"
[ "${HOME:-}" = "$E/home" ] || die "HOME is not the run's"
[ "${OPENSHELL_SYSTEM_GATEWAY_DIR:-}" = "$E/etc-openshell" ] || die "OPENSHELL_SYSTEM_GATEWAY_DIR is not the run's"
for v in OPENSHELL_GATEWAY_ENDPOINT OPENSHELL_GATEWAY OPENSHELL_GATEWAY_INSECURE; do
  if "$PRINTENV" "$v" >/dev/null 2>&1; then die "$v is set"; fi
done
if "$PRINTENV" OPENSHELL_LOCAL_TLS_DIR >/dev/null 2>&1; then
  [ "$("$PRINTENV" OPENSHELL_LOCAL_TLS_DIR)" = "$E/tls" ] || die "OPENSHELL_LOCAL_TLS_DIR is not the run's"
fi
[ "$#" -ge 1 ] || die "no arguments"
registry_ok() { # exactly our gateway registered as a user gateway, no system gateways
  "$REAL" gateway list -o json 2>/dev/null | "$JQ" -e --arg gw "$GW" --arg ep "https://127.0.0.1:$PORT" '
    type == "array"
    and ([.[] | select(.name == $gw and .endpoint == $ep and .source == "user")] | length) == 1
    and ([.[] | select(.source == "system")] | length) == 0' >/dev/null
}
if [ "$#" -eq 1 ]; then
  case "$1" in --version | -V | --help | -h) exec "$REAL" "$1" ;; esac
fi
if [ "$#" -eq 4 ] && [ "$1" = gateway ] && [ "$2" = list ] && [ "$3" = -o ] && [ "$4" = json ]; then exec "$REAL" "$@"; fi
if [ "$#" -eq 6 ] && [ "$1" = gateway ] && [ "$2" = add ] && [ "$3" = "https://127.0.0.1:$PORT" ] \
  && [ "$4" = --local ] && [ "$5" = --name ] && [ "$6" = "$GW" ]; then exec "$REAL" "$@"; fi
if [ "$1" = ssh-proxy ]; then
  # normally ssh's ProxyCommand execs the real binary directly; allow this only if it comes through here
  url=
  prev=
  for a in "$@"; do
    case "$prev" in -g | --gateway) url=$a ;; esac
    case "$a" in --gateway=*) url=${a#--gateway=} ;; esac
    prev=$a
  done
  case "$url" in "https://127.0.0.1:$PORT" | "https://127.0.0.1:$PORT/"*) ;; *) die "ssh-proxy gateway '$url' is not this run's" ;; esac
  registry_ok || die "gateway registry does not match this run"
  exec "$REAL" "$@"
fi
[ "$1" = -g ] && [ "${2:-}" = "$GW" ] || die "every other call must start with -g $GW"
[ "${3:-}" != gateway ] || die "gateway subcommands are not allowed here"
if [ "${3:-}" = sandbox ] && [ "${4:-}" = exec ]; then die "sandbox exec is not allowed in EXP-008"; fi
for a in "${@:3}"; do
  [ "$a" = -- ] && break
  case "$a" in --gateway-endpoint | --gateway-endpoint=* | --gateway-insecure | --gateway | --gateway=* | -g | -g?*) die "gateway override flag '$a'" ;; esac
done
registry_ok || die "gateway registry does not match this run (need $GW at https://127.0.0.1:$PORT, user source, no system gateways)"
exec "$REAL" "$@"
EOF
chmod 0700 "$E/wrap/ssh" "$E/wrap/openshell"

step P3
log "run $RUN: herdr=$(tcenv 10 "$HERDR_BIN" --version 2>&1)"
{
  echo "controller (this script) pid=$$ ppid=$PPID"
} >"$E/setup-lineage.txt"
p3 tools p3_tools
p3 baseline-B1 p3_baseline
p3 containers-conf p3_conf
p3 podman-service p3_service
p3 podman-store-isolation p3_store
p3 podman-socket p3_socket
p3 pinned-images p3_pull
p3 cgroup-limits-probe p3_probe
p3 healthcheck-probe p3_hc_probe
p3 healthcheck-readiness-gate p3_hc_gate
p3 tls-certs p3_tls
p3 gateway-toml p3_toml
p3 gateway-preflight p3_preflight
p3 gateway-start p3_gateway
p3 gateway-register p3_register
p3 mtls-negative p3_mtls_negative
p3 ssh-no-agent p3_ssh
p3 herdr-start p3_herdr
{
  echo "podman service pid=$PS_PID ppid=$(ppid_of "$PS_PID")"
  echo "gateway pid=$GWPID ppid=$(ppid_of "$GWPID")"
  echo "herdr server pid=$HERDR_PID ppid=$(ppid_of "$HERDR_PID")"
} >>"$E/setup-lineage.txt"
write_versions
record P3 PASS "isolation gate: dedicated store+socket, loopback mTLS gateway, ssh without agent, herdr under $E"
snap 00-initial

# ====================================================================== A1
run_a1() {
  local out=$E/obs/create.out err=$E/obs/create.err n_ack why='' sp i rc bad=0 p d centry chain=() others=()
  step A1
  # create in the background so its pid+start can be recorded (A7a needs them)
  env -i "${CENV_VARS[@]}" "$E/wrap/openshell" -g "$GW" sandbox create --detach --tty --name "$GW" --from "$WORKLOAD" \
    --label "exp008.run=$RUN" -- /usr/local/bin/counter.sh "$OUTDIR" >"$out" 2>"$err" </dev/null &
  CREATE_PID=$!
  track create-cli "$CREATE_PID"
  centry=$LAST_TRACK
  CREATE_START=$(proc_start "$CREATE_PID")
  log "create CLI pid=$CREATE_PID start=$CREATE_START"
  for ((i = 0; i < 420; i++)); do
    alive_same "$CREATE_PID" "$CREATE_START" || break
    sleep 1
  done
  if alive_same "$CREATE_PID" "$CREATE_START"; then
    sig TERM "$centry"
    record A1 FAIL "create CLI still running after 420s"; stop "A1 create did not return"
  fi
  wait "$CREATE_PID"
  i=$?
  [ "$i" = 0 ] || { record A1 FAIL "create exited $i: $(tr '\n' ' ' <"$err" | cut -c1-300)"; stop "A1 create failed"; }
  poll 300 2 sbx_ready || { record A1 FAIL "sandbox not Ready within 300s (phase=$(sbx_phase poll))"; stop "A1 not Ready"; }
  log "sandbox Ready id=$SBX_ID"
  poll 60 2 find_workload || { record A1 FAIL "workload container / counter host pid not found"; stop "A1 no counter process"; }
  wait_for 30 has_identity ||
    { record A1 FAIL "no counter identity within 30s (is $OUTDIR writable? phase=$(sbx_phase poll)); /tmp/out fallback is not authorised"; stop "A1 no identity"; }
  ident_wait a1 30 || { record A1 FAIL "identity inconsistent: $(tr '\n' ' ' <"$E/obs/a1-identity.txt")"; stop "A1 identity consistency"; }
  load_counter_id a1
  CUR_ID=a1
  save_out a1
  log "fd0 of the counter: $(kv "$E/obs/a1-identity.txt" fd0)"
  # attach the first pane. The ACK is the primary evidence; the process chain corroborates it.
  # If the chain is not found, still type `mark a1` and record whether it ACKs before stopping.
  if ! pane_attach a1; then
    rc=0
    mark "$PANE" a1 || rc=$?
    { echo "## after typing 'mark a1': mark rc=$rc (0: ACK in log and pane; 1: no ACK in log; 2: ACK in log only)"
      echo "ack line: $(ack_line a1)"; } | redact >>"$E/obs/attach-a1.txt"
    attach_diag a1
    snap 01-a1-attach-failed
    record A1 FAIL "attach not corroborated by process accounting ($(client_counts)); mark a1 rc=$rc$([ "$rc" = 0 ] && echo ' (ACK seen: process model wrong, later client assertions unreliable)'); see obs/attach-a1.txt"
    stop "A1 attach"
  fi
  clients_detail
  snap 01-a1-attached
  # the counter chain (hpid -> wpid -> conmon -> ...) must have no herdr/ssh/CLI ancestor
  mapfile -t chain < <(ancestors "$HPIDC")
  mapfile -t others < <({ echo "$HERDR_PID"; echo "$CREATE_PID"; clients_pids; ssh_pids; proxy_pids; })
  for p in "${chain[@]}"; do echo "$p $(proc_comm "$p")"; done >"$E/snaps/a1-counter-chain.txt"
  for p in "${chain[@]}"; do
    for d in "${others[@]}"; do [ "$p" = "$d" ] && bad=1; done
    case $(proc_comm "$p") in herdr* | ssh | openshell) bad=1 ;; esac
  done
  echo "chain-check: $([ "$bad" = 0 ] && echo no-herdr-ssh-cli-ancestor || echo UNEXPECTED-ANCESTOR)" >>"$E/snaps/a1-counter-chain.txt"
  echo "counter chain: $(tr '\n' ';' <"$E/snaps/a1-counter-chain.txt")" >>"$E/setup-lineage.txt"
  [ "$bad" = 0 ] || why="$why;counter has a herdr/ssh/cli ancestor"
  sp=$(att_ssh "$ATT") # this pane's transport ssh
  if [ -n "$sp" ]; then
    { echo "ssh pid=$sp peers:"; unix_peers "$sp"; } >"$E/obs/a1-ssh-peers.txt"
    if unix_peers "$sp" | grep -E -e "/run/user/$UID_/" -e 'agent' -e 'gnupg' >/dev/null; then why="$why;ssh has an agent-like unix peer"; fi
  fi
  mark "$PANE" a1 || why="$why;mark a1 rc=$?"
  verify_ack a1 0 || why="$why;ACK identity mismatch: $(ack_line a1)"
  att_alive "$ATT" || why="$why;the pane's cli/ssh/proxy ($ATT) did not stay up through the ACK"
  n_ack=$ACKN
  save_out a1-acked
  if [ -z "$why" ]; then
    record A1 PASS "ACK in log and pane: pid=$CPID start=$CSTART nonce=$CNONCE n=$n_ack; instance=$(kv "$E/obs/a1-identity.txt" instance_id) hpid=$HPIDC hstart=$(kv "$E/obs/a1-identity.txt" hstart) cread=$(tail -n 1 "$E/obs/cread-method.txt"); client cli/ssh/proxy=$ATT"
  else
    record A1 FAIL "${why#;}"
    stop "A1: no verified identity and working attachment; later steps need both"
  fi
}

# ====================================================================== A2
# A2, A3 and A4a/b are not called in run 4 (covered by run 3's evidence); kept as reviewed.
N_A2=0
run_a2() {
  local n0 why=''
  step A2
  n0=$(last_n)
  H pane close "$PANE" >/dev/null
  wait_for 10 att_gone "${PANE_CLIENT[$PANE]:-}" || why="$why;the pane's cli/ssh/proxy (${PANE_CLIENT[$PANE]:-unknown}) still present"
  wait_for 10 no_client_procs || why="$why;connect/ssh/proxy processes still present ($(client_counts))"
  clients_detail
  sbx_json a2 && [ "$(sbx_phase a2)" = Ready ] || why="$why;phase not Ready"
  ident_wait a2 30 || why="$why;identity not collectable"
  same_ident a1 a2 || why="$why;identity changed"
  wait_for 15 counter_past $((${n0:-0} + 5)) || why="$why;n did not advance by 5 (n0=$n0 now=$(last_n))"
  N_A2=$(last_n)
  save_out a2
  snap 02-a2-detached
  if [ -z "$why" ]; then record A2 PASS "pane closed, no cli/ssh/proxy left, phase Ready, identity unchanged, n $n0 -> $N_A2 with no client"
  else record A2 FAIL "${why#;}"; fi
  if ident_changed a1 a2; then stop "A2 identity change in A1-A4"; fi
}

# ====================================================================== A3
replay_seen() { # a tick older than the pre-connect n is visible in the new pane (replay)
  local k
  H pane read "$PANE" --source visible --lines 40 >"$E/panes/a3-visible.txt" 2>&1
  H pane read "$PANE" --source recent --lines 300 >"$E/panes/a3-recent.txt" 2>&1
  k=$(cat "$E/panes/a3-visible.txt" "$E/panes/a3-recent.txt" | ticks_min)
  A3_K=${k:-}
  [ -n "$k" ] && [ "$k" -le "$A3_N" ]
}
A3_K=
A3_N=0
run_a3() {
  local why=''
  step A3
  A3_N=$(last_n)
  pane_attach a3 || { record A3 FAIL "could not attach a pane"; stop "A3 attach"; } # authorization section 4
  wait_for 10 replay_seen || why="$why;no replayed tick (min K=${A3_K:-none} > n at connect $A3_N)"
  mark "$PANE" a3 || why="$why;mark a3 rc=$?"
  ident_wait a3 30 || why="$why;identity not collectable"
  same_ident a1 a3 || why="$why;identity changed"
  load_counter_id a3
  verify_ack a3 "${N_A2:-0}" || why="$why;ACK mismatch or n not > n(A2)=$N_A2: $(ack_line a3)"
  save_out a3
  snap 03-a3-reattached
  if [ -z "$why" ]; then record A3 PASS "replay visible (min tick K=$A3_K <= n at connect $A3_N); ACK n=$ACKN > n(A2)=$N_A2; same identity"
  else record A3 FAIL "${why#;}"; fi
  if ident_changed a1 a3; then stop "A3 identity change in A1-A4"; fi
}

# ==================================================================== A4a/b
# Client lifecycle (owner adjustment before run 3, 2026-11-23): client processes that outlive the
# Herdr server are recorded, not failed. A4 passes on PLAN's criteria only: same identity, counter
# progress while Herdr is down, and a new pane's ACK. Survivors are never signalled here (cleanup
# handles tracked pids). The run stops if a survivor may have blocked the new pane, or is still
# present after A4, because later steps count client processes. "Zero clients" is claimed only
# when two scans, with counter progress between them, found no client process.
fd0_of() { case ${1:-} in '' | *[!0-9]*) return 0 ;; esac; readlink "/proc/$1/fd/0" 2>/dev/null; }
gw_estab() { "$SS" -Htnp state established "( dport = :$PORT )" 2>/dev/null | grep -c "pid=$1,"; } # <pid>: its TCP sessions to the gateway
pts_masters() { # pts_masters <n>: "<count> [pid:comm ...]" of our processes holding the ptmx master of /dev/pts/<n> (fdinfo tty-index)
  local f i p n=0 seen=0 idx=0 who=''
  while read -r f; do
    seen=1
    i=$(sed -n 's/^tty-index:[[:space:]]*//p' "${f%/fd/*}/fdinfo/${f##*/}" 2>/dev/null)
    [ -n "$i" ] && idx=1
    if [ "$i" = "$1" ]; then p=${f#/proc/}; p=${p%%/*}; n=$((n + 1)); who="$who $p:$(proc_comm "$p")"; fi
  done < <(find /proc/[0-9]*/fd -maxdepth 1 -user "$UID_" \( -lname /dev/ptmx -o -lname /dev/pts/ptmx \) 2>/dev/null)
  if [ "$seen" = 0 ] || [ "$idx" = 1 ]; then echo "$n [${who# }]"; else echo "unknown []"; fi
}
pts_report() { case ${1:-} in /dev/pts/[0-9]*) echo "exists=$([ -e "$1" ] && echo yes || echo no) ptmx-master-holders=$(pts_masters "${1#/dev/pts/}")" ;; *) echo "not a pty" ;; esac; }
a4_clients_obs() { # a4_clients_obs <id> <tag> <original chain>: one scan appended to obs/a4<id>-clients.txt; sets A4_LEFT
  local snapout cls p st pp role kid orig=" $3 "
  snapout=$(client_snap)
  A4_LEFT=$(grep -c -E '^(cli|transport|proxy|run-ssh) ' <<<"$snapout")
  {
    echo "# $2 $(date -u +%FT%TZ) t+${SECONDS}s n=$(last_n)"
    awk '{ n[$1]++ } END { printf "counts: attached=%d cli=%d transport=%d proxy=%d run-ssh=%d other=%d\n", n["attached"], n["cli"], n["transport"], n["proxy"], n["run-ssh"], n["other"] }' <<<"$snapout"
    while read -r cls p st pp; do
      case $cls in
      cli)
        kid=$(awk -v p="$p" '$1 == "transport" && $4 == p { print $2 }' <<<"$snapout" | tr '\n' ' ')
        if [ -n "$kid" ]; then role="supervising CLI with transport child ${kid% }"; else role="disconnected supervising CLI (no transport child)"; fi ;;
      transport)
        kid=$(awk -v p="$p" '$1 == "proxy" && $4 == p { print $2 }' <<<"$snapout" | sed -n '1p')
        if [ -n "$kid" ]; then role="SSH transport with proxy $kid (proxy TCP sessions to the gateway: $(gw_estab "$kid"))"; else role="SSH transport without a proxy child"; fi ;;
      proxy) role="proxy, parent $(awk -v q="$pp" '$2 == q { print $1 }' <<<"$snapout" | sed -n '1p'), TCP sessions to the gateway: $(gw_estab "$p")" ;;
      run-ssh) role="ssh using the run's ssh_config outside any chain" ;;
      *) continue ;;
      esac
      echo "$cls pid=$p start=$st ppid=$pp original=$(case $orig in *" $p:$st "*) echo yes ;; *) echo no ;; esac) state=$(sed -n 's/^State:[[:space:]]*//p' "/proc/$p/status" 2>/dev/null) fd0=$(fd0_of "$p") role: $role"
    done <<<"$snapout"
    grep '^attached ' <<<"$snapout"
  } 2>&1 | redact >>"$E/obs/a4$1-clients.txt"
}
a4_orig_input() { # a4_orig_input <original chain>: can the original connection still take input?
  local e alive=() pts cap=unknown trn=no px=no m
  [ -n "$1" ] || { echo "original connection: unknown (no recorded chain)"; return; }
  for e in $1; do alive_same "${e%%:*}" "${e#*:}" && alive+=("$e"); done
  if [ "${#alive[@]}" = 0 ]; then echo "original connection: ended (cli, ssh and proxy all gone); capable of input: no"; return; fi
  read -r _ e _ <<<"$1"; alive_same "${e%%:*}" "${e#*:}" && trn=yes
  e=${1##* }; alive_same "${e%%:*}" "${e#*:}" && px=yes
  pts=$(fd0_of "${alive[0]%%:*}")
  m=$(pts_report "$pts")
  if [ "$trn" = no ] || [ "$px" = no ]; then cap="no (transport or proxy gone)"
  else case $m in *"holders=0 "*) cap="no (no process holds its terminal's master)" ;; *holders=[1-9]*) cap="possibly (heuristic: transport and proxy alive and a master holder of its terminal exists; holders named above; not demonstrated by typing)" ;; esac; fi
  echo "original connection: alive ${alive[*]}; transport alive=$trn proxy alive=$px; terminal ${pts:-none} $m; capable of input: $cap"
}
a4_strays() { client_snap | awk -v keep=" $1 " '$1 ~ /^(cli|transport|proxy|run-ssh)$/ && index(keep, " " $2 ":" $3 " ") == 0 { print $1 ":" $2 ":" $3 }'; } # outside chain <1>
a4_no_strays() { [ -z "$(a4_strays "$1")" ]; }
a4_track() { local p; for p in $(clients_pids) $(ssh_pids) $(proxy_pids); do track "stray-$p" "$p"; done; } # for cleanup's verified signals
restart_test() { # restart_test <a|b> <clean|kill>
  local id=$1 mode=$2 label=A4$1 n_stop n_gone n_down old old_start why='' rp rpanes=() orig obs t0 left_down left_up zero ro=no mrc=0 ackok=1 left_end=0 note=''
  step "$label"
  [ "$(clients)" -ge 1 ] || pane_attach "$label-pre" || { record "$label" FAIL "could not attach the pre-restart pane"; stop "$label attach"; }
  orig=${PANE_CLIENT[$PANE]:-}
  obs=$E/obs/a4$id-clients.txt
  n_stop=$(last_n)
  old=$HERDR_PID
  old_start=$HERDR_START
  snap "04$id-before-restart"
  pane_ids | "$JQ" -R . | "$JQ" -sc . >"$E/obs/a4$id-panes-before.json"
  { echo "# before $mode stop $(date -u +%FT%TZ): pane $PANE original chain (cli ssh proxy) ${orig:-unknown} alive=$(att_alive "$orig" && echo yes || echo no)"
    echo "control: original cli fd0=$(fd0_of "${orig%%:*}") $(pts_report "$(fd0_of "${orig%%:*}")") (expected >= 1 holder: the herdr server)"; } 2>&1 | redact >>"$obs"
  if [ "$mode" = clean ]; then
    stop_herdr_clean || { record "$label" FAIL "server stop failed"; stop "$label herdr server stop failed"; }
  else
    # SIGKILL exactly the recorded pid, after re-verifying start time and environment
    if ! { proc_env_has "$old" "XDG_CONFIG_HOME=$E/config" && alive_same "$old" "$old_start"; }; then
      record "$label" FAIL "refusing to kill unverified pid $old"; stop "$label unverified herdr pid"
    fi
    sig KILL "herdr-server:$old:$old_start"
  fi
  GUARD_OK=0
  wait_for 10 gone "$old" "$old_start" || why="$why;old server pid $old still alive"
  # client lifecycle: an observation (scan 1), not an A4 criterion
  t0=$SECONDS
  wait_for 10 no_client_procs
  a4_clients_obs "$id" "scan 1: herdr server gone, after up to 10s for clients to end (waited $((SECONDS - t0))s)" "$orig"
  left_down=$A4_LEFT
  a4_orig_input "$orig" 2>&1 | redact >>"$obs"
  [ "$left_down" = 0 ] || a4_track
  n_gone=$(last_n)
  # PLAN criterion: the counter keeps progressing while Herdr is down
  wait_for 15 counter_past $((${n_stop:-0} + 3)) || why="$why;counter did not advance by 3 while herdr down"
  wait_for 15 counter_past $((${n_gone:-0} + 2)) # progress between the two client scans
  n_down=$(last_n)
  save_out "a4$id-down"
  a4_clients_obs "$id" "scan 2: herdr still down, after counter progress" "$orig"
  left_up=$A4_LEFT
  a4_orig_input "$orig" 2>&1 | redact >>"$obs"
  [ "$left_up" = 0 ] || a4_track
  if [ "$left_down" = 0 ] && [ "$left_up" = 0 ] && [ "${n_down:-0}" -gt "${n_gone:-0}" ] 2>/dev/null; then
    zero="verified zero (two scans, n $n_gone -> $n_down between them)"
  else
    zero="not verified zero (client processes at scans: $left_down, $left_up; n $n_gone -> $n_down)"
  fi
  echo "clients while herdr down: $zero" >>"$obs"
  snap "04$id-herdr-down"
  start_herdr "restart-$id" || { record "$label" FAIL "herdr did not restart${why:+ ($why)}"; stop "$label herdr restart failed"; }
  snap "04$id-herdr-restarted"
  {
    echo "pane ids before stop: $(cat "$E/obs/a4$id-panes-before.json")"
    echo "connect clients after herdr restart (before new pane): $(client_counts)"
    mapfile -t rpanes < <(pane_ids)
    for rp in "${rpanes[@]}"; do
      echo "--- restored pane $rp process-info:"
      H pane process-info --pane "$rp" | "$JQ" -c '.result.process_info|{shell_pid,fg:[.foreground_processes[]|.cmdline]}'
      echo "--- restored pane $rp visible text (non-empty lines):"
      H pane read "$rp" --source visible --lines 40 | grep -v '^$' | sed -n '1,8p'
    done
  } 2>&1 | redact >"$E/obs/restored-$id.txt"
  if ! pane_attach "$label"; then
    a4_clients_obs "$id" "new pane did not attach" "$orig"
    record "$label" FAIL "$mode:${why};new pane could not attach; client processes at herdr-down scans: $left_down, $left_up (obs/a4$id-clients.txt)"
    stop "$label attach"
  fi
  load_counter_id a1
  mark "$PANE" "a4$id" || { mrc=$?; ackok=0; why="$why;mark a4$id rc=$mrc"; }
  H pane read "$PANE" --source recent --lines 300 >"$E/panes/a4$id-new-recent.txt" 2>&1
  grep 'attached read-only' "$E/panes/a4$id-new-recent.txt" >/dev/null && ro=yes
  echo "new pane $PANE chain $ATT; 'attached read-only' notice: $ro; mark rc=$mrc" | redact >>"$obs"
  ident_wait "a4$id" 30 || why="$why;identity not collectable"
  same_ident a1 "a4$id" || why="$why;identity changed"
  verify_ack "a4$id" "$n_stop" || { ackok=0; why="$why;ACK mismatch: $(ack_line "a4$id")"; }
  save_out "a4$id"
  snap "04$id-reattached"
  # survivors outside the new pane's chain: wait (no signal) for them to end on their own;
  # 75 s covers the CLI's 60 s reconnect window (FIND-080)
  if ! a4_no_strays "$ATT"; then
    t0=$SECONDS
    if wait_for 75 a4_no_strays "$ATT"; then note="survivors ended on their own $((SECONDS - t0))s after the reattach"; else left_end=1; fi
  fi
  a4_clients_obs "$id" "end of $label${note:+ ($note)}" "$orig"
  if [ -z "$why" ]; then
    record "$label" PASS "$mode: old server $old gone; identity unchanged, n $n_stop -> $n_down while herdr down; clients while down: $zero; new server $HERDR_PID; ACK n=$ACKN${note:+; $note}"
  else
    record "$label" FAIL "$mode:${why}; clients while down: $zero"
  fi
  if ident_changed a1 "a4$id"; then stop "$label identity change in A1-A4"; fi
  if [ "$((left_down + left_up))" -gt 0 ] && { [ "$ro" = yes ] || [ "$ackok" = 0 ]; }; then
    stop "$label: a client that survived Herdr may have blocked the new pane (read-only notice=$ro, mark rc=$mrc); not terminated"
  fi
  [ "$left_end" = 0 ] || stop "$label: client processes outside the new pane's chain still present 75s after the reattach ($(a4_strays "$ATT" | tr '\n' ' ')); later steps count client processes; not terminated"
  [ "$ackok" = 1 ] || stop "$label: the new pane's ACK did not satisfy the primary criterion (mark rc=$mrc)"
}

# ============================================================ run 4 sequence
# Owner-approved order for the fourth (last) attempt: A1, A6, A7a, A5a, A5b, A7b. A2-A4 are covered
# by run 3 and not repeated (their functions above are kept but not called). CUR_ID names the
# identity file of the main-process incarnation later steps must see: a1 until a gateway restart
# is classified with a consistent identity, then a5a, then a5b. A restarted process is never
# treated as continuity; before any gateway restart, any identity change stops the run.
CUR_ID=
A5A_USABLE=no
A5A_WHY='not run'
# v0.1.9 notice texts (crates/openshell-supervisor-process/src/ssh.rs:862 with the error text of its
# test at :2219, and :1024; crates/openshell-cli/src/ssh.rs:627). The read-only notice is longer than a
# half-width pane: it counts if its key phrase is on one row, or the whole line matches wrap-aware.
NOTICE_RO='attached read-only'
NOTICE_RO_LINE='openshell: canonical main process already has an input owner; attached read-only; retry input after the owner disconnects; press Ctrl-C or Ctrl-D to exit'
NOTICE_INPUT='openshell: input enabled'
NOTICE_RECONNECT='Connection to sandbox lost; reconnecting'
A6_N1=0
a6_owner_ready() { # <pane>: a tick newer than A6_N1 is visible and no read-only notice
  local t
  pane_capture "$1" a6-owner-ready
  t=$(ticks_last <"$(pane_cap a6-owner-ready visible)")
  [ -n "$t" ] && [ "$t" -gt "$A6_N1" ] 2>/dev/null && ! caps_text a6-owner-ready "$NOTICE_RO" && ! caps_text a6-owner-ready "$NOTICE_RO_LINE"
}
a6_ro_seen() { pane_capture "$1" "$2" && { caps_text "$2" "$NOTICE_RO" || caps_text "$2" "$NOTICE_RO_LINE"; }; } # <pane> <tag>
# ident_settle <label> <timeout-s>: a consistent identity that is still the same 15 s later. After a
# gateway restart, the persisted phase can read Ready before startup recovery restarts the
# containers (v0.1.9 compute/mod.rs:4133-4137, driver-podman/src/driver.rs:2071-2078), so one
# sample taken at Ready could still be the old process. Each superseded sample is kept.
ident_settle() {
  local end=$((SECONDS + $2)) i=0
  ident_wait "$1" 90 || return 1
  while :; do
    cp "$E/obs/$1-identity.txt" "$E/obs/$1-settle$i-identity.txt"
    sleep 15
    ident_wait "$1" 60 || return 1
    same_ident "$1-settle$i" "$1" && { echo "settled after $((i + 1)) comparison(s)" >"$E/obs/$1-settle.txt"; return 0; }
    log "identity $1 changed while settling (sample $i superseded)"
    i=$((i + 1))
    [ "$SECONDS" -lt "$end" ] || { echo "not settled within $2s ($i change(s))" >"$E/obs/$1-settle.txt"; return 1; }
  done
}

# ====================================================================== A6
# With the original main process and a healthy gateway. Pane 1 attaches first and owns input; pane 2
# is a read-only viewer. Negative: the viewer's "mark a6ro" never reaches the counter, not even after
# the owner leaves. Positive: the owner's "mark a6w" ACKs while the viewer is attached; after pane 1
# is closed (the owner's client ends, releasing input), the viewer's "mark a6ro2" ACKs in pane 2.
run_a6() {
  local p1 p2 why='' n0 tries=1 mrc=0 exp t s notices=$E/obs/a6-notices.txt
  step A6
  close_all_panes || { record A6 FAIL "A1's client did not end before A6 ($(client_counts))"; stop "A6: a client outside A6's panes may own input"; }
  ident_wait a6-pre 30 || { record A6 FAIL "identity not collectable before A6"; stop "A6 identity"; }
  same_ident "$CUR_ID" a6-pre || { record A6 FAIL "identity changed since $CUR_ID with no gateway restart"; stop "A6 identity change before any gateway restart"; }
  if [ "$(kv "$E/obs/a6-pre-identity.txt" phase)" != Ready ] || ! alive_same "$GWPID" "$GWSTART"; then
    record A6 FAIL "gateway or sandbox not healthy before A6 (phase=$(kv "$E/obs/a6-pre-identity.txt" phase))"; stop "A6 health"
  fi
  load_counter_id "$CUR_ID"
  n0=$(last_n)
  pane_attach a6-owner || { record A6 FAIL "pane 1 could not attach"; stop "A6 attach"; }
  p1=$PANE
  # pane 1 must hold the input lease before pane 2 attaches: the host chain exists before the
  # supervisor has processed the attachment, so wait for live output in pane 1 (a tick newer than
  # the n at its attach) with no read-only notice
  A6_N1=$(last_n)
  poll 15 1 a6_owner_ready "$p1" || { record A6 FAIL "pane 1 showed no live output, or a read-only notice, within 15s of attaching"; stop "A6 owner not established"; }
  pane_attach a6-viewer || { record A6 FAIL "pane 2 could not attach"; stop "A6 attach"; }
  p2=$PANE
  clients_eq 2 || why="$why;not exactly two chains with both panes attached ($(client_counts))"
  poll 15 1 a6_ro_seen "$p2" a6-viewer-attach || why="$why;no '$NOTICE_RO' notice in pane 2"
  # negative: the viewer types while read-only
  type_line "$p2" "mark a6ro"
  sleep 5
  if ack_present a6ro; then why="$why;the read-only viewer's input reached the counter (ACK a6ro)"; fi
  # the owner has input while the viewer is attached
  mark "$p1" a6w || why="$why;owner mark a6w rc=$?"
  verify_ack a6w "${n0:-0}" || why="$why;owner ACK a6w check failed: $(ack_line a6w)"
  if exp=$(ack_expected a6w); then pane_capture "$p2" a6w-viewer; fi
  echo "viewer pane shows the owner's ACK a6w (output reaches the viewer; not a pass criterion): $(caps_ack a6w-viewer "${exp:-}" >/dev/null && echo yes || echo no)" >>"$notices"
  # the owner releases: its pane is closed and its whole chain ends
  H pane close "$p1" >/dev/null
  wait_for 15 att_gone "${PANE_CLIENT[$p1]:-}" || why="$why;pane 1's cli/ssh/proxy (${PANE_CLIENT[$p1]:-unknown}) still present"
  wait_for 15 clients_eq 1 || why="$why;clients != 1 after closing pane 1 ($(client_counts))"
  att_alive "${PANE_CLIENT[$p2]:-}" || why="$why;pane 2's chain did not survive pane 1's close"
  sleep 2
  if ack_present a6ro; then why="$why;the viewer's discarded input reached the counter after the owner left"; fi
  # positive: the viewer gains input on its next keystroke. A second attempt only if the first left no ACK in the log.
  mark "$p2" a6ro2 5 || mrc=$?
  if [ "$mrc" = 1 ]; then
    for s in $PANE_SOURCES; do cp "$(pane_cap a6ro2 "$s")" "$(pane_cap a6ro2-attempt1 "$s")" 2>/dev/null; done
    tries=2; mrc=0; sleep 1; mark "$p2" a6ro2 15 || mrc=$?
  fi
  [ "$mrc" = 0 ] || why="$why;viewer mark a6ro2 rc=$mrc after $tries attempt(s)"
  verify_ack a6ro2 "${n0:-0}" || why="$why;viewer ACK a6ro2 check failed: $(ack_line a6ro2)"
  poll 10 1 pane_text_seen "$p2" a6-viewer-final "$NOTICE_INPUT" || why="$why;no '$NOTICE_INPUT' notice in pane 2"
  ident_wait a6 30 || why="$why;identity not collectable"
  same_ident "$CUR_ID" a6 || why="$why;identity changed during A6"
  if ack_present a6ro; then why="$why;ACK a6ro present at the end of A6"; fi
  {
    echo "attempts for the viewer's mark a6ro2: $tries"
    for t in a6-viewer-attach a6-viewer-final; do
      for s in $PANE_SOURCES; do grep -h -i -e 'openshell' -e 'read-only' -e 'input' -e 'connection' "$(pane_cap "$t" "$s")" 2>/dev/null | sed "s/^/$t $s: /"; done
    done
  } 2>&1 | redact >>"$notices"
  save_out a6
  snap 06-a6
  PANE=$p2
  if [ -z "$why" ]; then record A6 PASS "'$NOTICE_RO' in pane 2; no ACK a6ro while read-only or after; owner ACK a6w with pane 2 attached; after pane 1 closed, pane 2 ACK a6ro2 (attempts=$tries) and '$NOTICE_INPUT'; same identity ($CUR_ID)"
  else record A6 FAIL "${why#;}"; fi
  if ident_changed "$CUR_ID" a6; then stop "A6 identity change before any gateway restart"; fi
}

# ====================================================================== A7a
# The creating CLI exited at create time (A1 waited for it); the same main process keeps running
# with no client of any kind attached.
run_a7a() {
  local why='' n0
  step A7a
  close_all_panes || why="$why;client processes remain after closing all panes ($(client_counts))"
  if [ -z "$CREATE_PID" ] || [ -z "$CREATE_START" ]; then why="$why;create CLI pid/start unknown"
  elif ! gone "$CREATE_PID" "$CREATE_START"; then why="$why;create CLI pid $CREATE_PID still alive"; fi
  ident_wait a7a 30 || why="$why;identity not collectable"
  same_ident "$CUR_ID" a7a || why="$why;identity changed (not the process A1 created)"
  [ "$(kv "$E/obs/a7a-identity.txt" phase)" = Ready ] || why="$why;phase not Ready"
  n0=$(last_n)
  wait_for 10 counter_past $((${n0:-0} + 3)) || why="$why;n did not advance by 3 with no client (n0=$n0 now=$(last_n))"
  save_out a7a
  snap 07a
  if [ -z "$why" ]; then record A7a PASS "create CLI pid $CREATE_PID gone (exited 0 at create); no client; phase Ready; same identity ($CUR_ID); n $n0 -> $(last_n)"
  else record A7a FAIL "${why#;}"; fi
  if ident_changed "$CUR_ID" a7a; then stop "A7a identity change before any gateway restart"; fi
}

# ==================================================================== A5a/b
a5_sample() { # a5_sample <id> <tag>: containers, counter host pid, last n (via cread; works while down)
  {
    echo "# $1 $2 $(date -u +%FT%TZ)"
    echo "containers (names state role):"
    PT=30 P ps -a --format json 2>&1 | "$JQ" -r '.[] | "\((.Names // []) | join(",")) \(.State) \(.Labels["openshell.ai/isolation-role"] // "-")"' 2>&1
    echo "counter host pid $HPIDC alive with the same start time: $(alive_same "$HPIDC" "$HSTARTC" && echo yes || echo no)"
    echo "counter last n (cread): $(last_n)"
    echo "cread method: $(tail -n 1 "$E/obs/cread-method.txt" 2>/dev/null)"
  } >"$E/obs/$1-sample-$2.txt" 2>&1
}
a5_gap() { # counter-log gap(s): n resets mark a replaced counter
  clog | awk '/ COUNT n=/ { n = substr($4, 3) + 0
    if (NR > 1 && n <= pn) printf "reset: old last n=%d at %s, new first n=%d at %s, gap=%.2fs\n", pn, pe, n, $1, $1 - pe
    pn = n; pe = $1 }'
}
# a5_classify <id> <pre> <post> <consistent yes|no> -> prints survived|restarted|inconclusive (details in obs).
# survived: all identity keys equal. restarted: the keys were collected on both sides and some differ.
# inconclusive: a key is missing, or the post identity's sources did not agree (ident_wait failed).
a5_classify() {
  local id=$1 pre=$2 post=$3 cls k
  if [ "$4" != yes ]; then cls=inconclusive
  elif same_ident "$pre" "$post"; then cls=survived
  else
    cls=inconclusive # restarted needs every key collected on both sides and a process-level difference
    for k in pid nonce instance_id hpid hstart; do
      [ -n "$(kv "$E/obs/$pre-identity.txt" "$k")" ] && [ -n "$(kv "$E/obs/$post-identity.txt" "$k")" ] || { cls=missing; break; }
    done
    if [ "$cls" != missing ]; then
      for k in pid start nonce instance_id hpid hstart; do
        [ "$(kv "$E/obs/$pre-identity.txt" "$k")" = "$(kv "$E/obs/$post-identity.txt" "$k")" ] || cls=restarted
      done
    fi
    [ "$cls" = restarted ] || cls=inconclusive
  fi
  {
    echo "class=$cls"
    echo "post identity sources consistent: $4"
    for k in pid start nonce instance_id started_at_ms restart_count sandbox_id cid hpid hstart phase; do
      echo "$k: old=$(kv "$E/obs/$pre-identity.txt" "$k") new=$(kv "$E/obs/$post-identity.txt" "$k")"
    done
    a5_gap
  } >"$E/obs/$id-classification.txt"
  echo "$cls"
}
# a5_running <id>: after a failed settle, is the sandbox Ready with exactly one running workload container
# and a counter process? If not, the restart left it unavailable (the persisted phase can read Ready).
a5_running() { sbx_json poll && [ "$(sbx_phase poll)" = Ready ] && find_workload; }
gw_restart_ready() { # start the gateway again and wait for Ready WITHOUT any openshell action (only sandbox get)
  start_gateway "gateway-$((++GW_COUNT))" || return 2
  poll 300 2 sbx_ready
}
a5_unavailable() { # a5_unavailable <id> [reason]: not usable after the restart. Record, then stop: no recreate, no reset.
  local conds err why=${2:-no Ready within 300s after the gateway restart}
  conds=$("$JQ" -c '.conditions // .status.conditions // []' "$E/obs/poll-sandbox.json" 2>/dev/null)
  err=$(tr '\n' ' ' <"$E/obs/poll-sandbox.err" 2>/dev/null | cut -c1-200)
  ident "$1-unavailable" >/dev/null 2>&1
  a5_sample "${1,,}" unavailable
  record "$1" unavailable "$why; last sandbox get: phase=$(sbx_phase poll) conditions=$conds err=$err"
  stop "$1 unavailable after the gateway restart; later steps not run"
}

run_a5a() {
  local t_term dur cls note='' use='' t_gw rr cons=yes rdy
  step A5a
  close_all_panes || note="$note;client processes still present before the stop ($(client_counts))"
  ident_wait a5a-pre 30 || { record A5a FAIL "pre-restart identity not collectable; the gateway was not stopped"; stop "A5a pre-restart identity"; }
  same_ident "$CUR_ID" a5a-pre || { record A5a FAIL "identity changed since $CUR_ID before any gateway restart"; stop "A5a identity change before the gateway restart"; }
  save_out a5a-pre
  snap 05a-before
  # SIGTERM the verified gateway pid; wait for exit (bounded); sample while it is down
  t_term=$SECONDS
  sig TERM "gateway:$GWPID:$GWSTART" || { record A5a FAIL "refusing to signal an unverified gateway pid"; stop "A5a gateway pid"; }
  sleep 2; a5_sample a5a during-shutdown+2s
  if ! poll 180 1 gone "$GWPID" "$GWSTART"; then
    note="$note;gateway did not exit within 180s of SIGTERM; SIGKILL sent (shutdown not graceful)"
    sig KILL "gateway:$GWPID:$GWSTART"
    poll 10 1 gone "$GWPID" "$GWSTART" || { record A5a FAIL "gateway still alive after SIGKILL"; stop "A5a gateway did not exit"; }
  fi
  dur=$((SECONDS - t_term))
  log "A5a: gateway exited ${dur}s after SIGTERM"
  sleep 2; a5_sample a5a down+2s
  sleep 8; a5_sample a5a down+10s
  snap 05a-gateway-down
  t_gw=$SECONDS
  gw_restart_ready; rr=$?
  if [ "$rr" = 2 ]; then record A5a FAIL "gateway did not restart"; stop "A5a gateway restart"; fi
  [ "$rr" = 0 ] || a5_unavailable A5a
  rdy=$((SECONDS - t_gw))
  log "A5a: Ready again ${rdy}s after gateway start (no openshell action taken)"
  ident_settle a5a 120 || cons=no
  if [ "$cons" = no ] && ! poll 30 3 a5_running; then a5_unavailable A5a "identity did not settle within 120s and no Ready sandbox with a running workload and counter"; fi
  cls=$(a5_classify a5a a5a-pre a5a "$cons")
  { echo "gateway_exit_after_sigterm_s=$dur"; echo "ready_after_gateway_start_s=$rdy"; echo "ready_without_action=yes (only sandbox get polled)"; } >>"$E/obs/a5a-classification.txt"
  save_out a5a
  case $cls in
  survived | restarted)
    CUR_ID=a5a
    load_counter_id a5a
    poll 60 2 sbx_ready || use="not Ready after the identity settled (phase=$(sbx_phase poll))"
    if [ -n "$use" ]; then :
    elif pane_attach a5a; then
      mark "$PANE" a5a || use="mark a5a rc=$?"
      [ -n "$use" ] || verify_ack a5a 0 || use="ACK a5a check failed: $(ack_line a5a)"
    else
      use="new pane could not attach"
    fi
    ;;
  *) use="identity $cls after the restart" ;;
  esac
  [ -n "$use" ] || A5A_USABLE=yes
  A5A_WHY=${use:-usable}
  echo "usable_after_restart=$A5A_USABLE${use:+ ($use)}" >>"$E/obs/a5a-classification.txt"
  save_out a5a-acked
  snap 05a-after
  record A5a "$cls" "SIGTERM: $(tr '\n' ' ' <"$E/obs/a5a-classification.txt" | cut -c1-700)${note:+; ${note#;}}"
}

A5B_TICK_DOWN=
A5B_ORIG=
A5B_T_KILL=0
chain_of_cli() { client_snap | awk -v c="$1" '$1 == "attached" && $2 ":" $3 == c { print $2 ":" $3, $4 ":" $5, $6 ":" $7; exit }'; } # <cli:start> -> its complete chain
a5b_cli_alive() { local e=${A5B_ORIG%% *}; [ -n "$e" ] && alive_same "${e%%:*}" "${e#*:}" && echo yes || echo no; } # the pane's supervising CLI
a5b_pane_ticks() { H pane read "$PANE" --source visible --lines 40 2>/dev/null | ticks_last; }
a5b_obs() { # a5b_obs <tag>: client processes and the pane, appended to obs/a5b-clients.txt and panes/a5b-<tag>*
  {
    echo "# $1 t+$((SECONDS - A5B_T_KILL))s after the kill $(date -u +%FT%TZ): $(client_counts)"
    echo "original chain (cli ssh proxy) $A5B_ORIG; cli alive=$(a5b_cli_alive); complete chain under that cli now: $(chain_of_cli "${A5B_ORIG%% *}")"
    client_snap | awk '$1 != "other"'
  } 2>&1 | redact >>"$E/obs/a5b-clients.txt"
  pane_capture "$PANE" "a5b-$1"
}
run_a5b() {
  local n_pre t_gw ready=no auto=no t_auto='' tn now cls note='' rec='' usable=no pane_before ch skip='' cons=yes mrc=0
  step A5b
  if [ "$A5A_USABLE" != yes ]; then record A5b NOT-RUN "not run: sandbox not usable after A5a ($A5A_WHY)"; return 0; fi
  # one attached pane, so supervised client recovery can be observed (A5a's pane if its chain is intact)
  if ! att_alive "${PANE_CLIENT[$PANE]:-}"; then close_all_panes; pane_attach a5b-pre || skip="could not attach a pane"; fi
  [ -n "$skip" ] || ident_wait a5b-pre 30 || skip="pre-kill identity not collectable"
  if [ -z "$skip" ] && ! same_ident "$CUR_ID" a5b-pre; then
    record A5b FAIL "identity changed since $CUR_ID with no gateway restart; A5b not run"; return 0
  fi
  if [ -z "$skip" ]; then
    load_counter_id a5b-pre
    mark "$PANE" a5b0 || skip="pre-kill mark a5b0 rc=$?"
    [ -n "$skip" ] || verify_ack a5b0 0 || skip="pre-kill ACK a5b0 check failed"
  fi
  if [ -n "$skip" ]; then record A5b NOT-RUN "not run: $skip"; return 0; fi
  n_pre=$(last_n)
  pane_before=$PANE
  A5B_ORIG=${PANE_CLIENT[$PANE]:-}
  save_out a5b-pre
  snap 05b-before
  A5B_T_KILL=$SECONDS
  sig KILL "gateway:$GWPID:$GWSTART" || { record A5b FAIL "refusing to signal an unverified gateway pid"; stop "A5b gateway pid"; }
  poll 10 0.5 gone "$GWPID" "$GWSTART" || { record A5b FAIL "gateway still alive 10s after SIGKILL"; stop "A5b gateway did not exit"; }
  sleep 2; a5_sample a5b down+2s; a5b_obs down+2s
  sleep 8; a5_sample a5b down+10s; a5b_obs down+10s
  A5B_TICK_DOWN=$(a5b_pane_ticks)
  snap 05b-gateway-down
  # restart right after the +10 s sample
  t_gw=$SECONDS
  start_gateway "gateway-$((++GW_COUNT))" || { record A5b FAIL "gateway did not restart"; stop "A5b gateway restart"; }
  # wait for Ready (sandbox get only) while watching the SAME pane, up to 75 s after the kill (the
  # CLI's 60 s window plus margin): recovered = the original CLI heads a complete chain again AND
  # the pane shows ticks it did not show while the gateway was down. Input is checked afterwards.
  while :; do
    now=$((SECONDS - A5B_T_KILL))
    if [ "$auto" = no ] && [ "$now" -le 75 ]; then
      ch=$(chain_of_cli "${A5B_ORIG%% *}")
      tn=$(a5b_pane_ticks)
      if [ -n "$ch" ] && [ -n "$tn" ] && [ "$tn" != "$A5B_TICK_DOWN" ]; then
        auto=yes; t_auto=$now; PANE_CLIENT[$PANE]=$ch
        log "A5b: the original CLI heads a chain again at +${now}s ($ch; transport respawned: $([ "$ch" != "$A5B_ORIG" ] && echo yes || echo no)); pane tick n=$tn vs $A5B_TICK_DOWN while down"
      fi
    fi
    if [ "$ready" = no ] && sbx_ready; then ready=yes; log "A5b: Ready $((SECONDS - t_gw))s after gateway start"; fi
    if { [ "$ready" = yes ] || [ $((SECONDS - t_gw)) -ge 300 ]; } && { [ "$auto" = yes ] || [ "$now" -gt 75 ]; }; then break; fi
    sleep 2
  done
  a5b_obs after-window
  echo "reconnect notice ('$NOTICE_RECONNECT') in the pane: $(caps_text a5b-after-window "$NOTICE_RECONNECT" && echo yes || echo no)" >"$E/obs/a5b-reconnect-msg.txt"
  [ "$ready" = yes ] || a5_unavailable A5b
  ident_settle a5b 120 || cons=no
  if [ "$cons" = no ] && ! poll 30 3 a5_running; then a5_unavailable A5b "identity did not settle within 120s and no Ready sandbox with a running workload and counter"; fi
  cls=$(a5_classify a5b a5b-pre a5b "$cons")
  {
    echo "ready_after_gateway_start_s=see timeline; ready_without_action=yes (only sandbox get polled)"
    echo "original supervising CLI alive after the window: $(a5b_cli_alive)"
    echo "auto_reattach=$auto${t_auto:+ (+${t_auto}s after the kill)}"
  } >>"$E/obs/a5b-classification.txt"
  save_out a5b
  case $cls in
  survived | restarted)
    CUR_ID=a5b
    load_counter_id a5b
    if [ "$auto" = yes ]; then
      mark "$PANE" a5b 5 || mrc=$?
      if [ "$mrc" = 1 ]; then mrc=0; sleep 1; mark "$PANE" a5b 15 || mrc=$?; note="$note;mark a5b needed a second attempt"; fi
      if [ "$mrc" = 0 ] && verify_ack a5b 0; then rec="supervised: the original CLI reattached the same pane, which accepted input (ACK a5b) from the $cls main process"; usable=yes
      else note="$note;the reattached pane did not accept input (mark a5b rc=$mrc)"; fi
    fi
    if [ "$usable" = no ]; then
      poll 60 2 sbx_ready || note="$note;not Ready after the identity settled (phase=$(sbx_phase poll))"
      H pane close "$pane_before" >/dev/null 2>&1
      wait_for 15 no_client_procs || note="$note;client processes still present after closing the pane ($(client_counts))"
      if pane_attach a5b2; then
        mrc=0; mark "$PANE" a5b2 || mrc=$?
        if [ "$mrc" = 0 ] && verify_ack a5b2 0; then rec="${rec:-no supervised recovery}; a new pane attached and accepted input (ACK a5b2)"; usable=yes
        else rec="${rec:-no supervised recovery}; a new pane attached but mark a5b2 rc=$mrc"; fi
      else
        rec="${rec:-no supervised recovery}; a new pane could not attach"
      fi
    fi
    ;;
  *) rec="not attempted: identity $cls after the restart" ;;
  esac
  echo "client_recovery=$rec; usable_after_restart=$usable" >>"$E/obs/a5b-classification.txt"
  save_out a5b-acked
  snap 05b-after
  record A5b "$cls" "SIGKILL: n at kill=$n_pre; $(tr '\n' ' ' <"$E/obs/a5b-classification.txt" | cut -c1-800)${note:+; ${note#;}}"
}

# ====================================================================== A7b
# Explicit deletion through the gateway, if the sandbox is still manageable. Deletion by the
# cleanup trap is recorded separately (C-delete) and is never an A7b result.
tracked_gone() { # every counter and container-main pid tracked in this run (all incarnations) is gone
  local e p st n=0
  for e in "${PIDS[@]}"; do
    case ${e%%:*} in counter-* | container-main-*) ;; *) continue ;; esac
    IFS=: read -r _ p st <<<"$e"
    n=$((n + 1))
    [ -n "$st" ] && gone "$p" "$st" || return 1
  done
  [ "$n" -gt 0 ]
}
sbx_absent() { # the gateway answers, and says the sandbox does not exist
  OT=30 O sandbox get "$GW" -o json >"$E/obs/a7b-get.out" 2>"$E/obs/a7b-get.err" && return 1
  grep -F 'sandbox not found' "$E/obs/a7b-get.err" "$E/obs/a7b-get.out" >/dev/null 2>&1
}
run_a7b() {
  local why='' out=$E/obs/a7b-delete.out nets phase rc ecode compl
  step A7b
  if ! { [ -n "$GWPID" ] && alive_same "$GWPID" "$GWSTART" && sbx_json a7b-pre; }; then
    record A7b NOT-RUN "not run: sandbox not manageable through the gateway (obs/a7b-pre-sandbox.err); cleanup deletes it as an emergency step"
    stop "A7b sandbox not manageable"
  fi
  phase=$(sbx_phase a7b-pre)
  ecode=$("$JQ" -r '.exit_code // "null"' "$E/obs/a7b-pre-sandbox.json" 2>/dev/null)
  case $phase in Completed | Error) compl="natural completion before delete (phase $phase, exit_code $ecode)" ;; *) compl="no natural completion (phase $phase, exit_code $ecode)" ;; esac
  close_all_panes || why="$why;client processes remain after closing all panes ($(client_counts))"
  ident a7b-pre >/dev/null 2>&1
  save_out a7b-pre
  save_out_final # the full counter log, before the delete
  rc=0
  OT=120 O sandbox delete "$GW" >"$out" 2>&1 || rc=$?
  log "A7b delete rc=$rc: $(tr '\n' ' ' <"$out")"
  [ "$rc" = 0 ] || why="$why;sandbox delete exited $rc"
  if grep -F 'already deleted' "$out" >/dev/null; then why="$why;delete reported 'already deleted': this was not an explicit deletion"
  elif ! grep -E 'Deleted sandbox|deletion accepted' "$out" >/dev/null; then why="$why;delete output names neither 'Deleted sandbox' nor 'deletion accepted'"; fi
  poll 120 2 sbx_absent || why="$why;sandbox not reported absent 120s after delete"
  wait_for 30 tracked_gone || why="$why;a tracked counter or container main process is still alive"
  poll 60 2 a7_store_empty || why="$why;store not empty after delete"
  {
    echo "containers:"; P ps -a --format '{{.ID}} {{.Names}} {{.State}}'
    echo "managed containers:"; P ps -a --filter label=openshell.managed=true -q
    echo "volumes:"; P volume ls -q
    echo "secrets:"; P secret ls -q
    echo "networks:"; P network ls --format '{{.Name}}'
  } >"$E/obs/a7b-listings.txt" 2>&1
  nets=$(P network ls --format '{{.Name}}' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
  case "$nets" in "podman " | "exp008-$RUN podman ") ;; *) why="$why;unexpected networks: $nets" ;; esac
  if [ -z "$why" ]; then record A7b PASS "explicit deletion (sandbox delete; $compl): $(tr '\n' ' ' <"$out" | cut -c1-120); sandbox absent; all tracked counter/container pids gone; no containers/volumes/secrets; networks: $nets"
  else record A7b FAIL "explicit deletion attempted ($compl): ${why#;}"; fi
}
a7_store_empty() { p_empty ps -a -q && p_empty ps -a --filter label=openshell.managed=true -q && p_empty volume ls -q && p_empty secret ls -q; }

# ---------------------------------------------------------------------- run
run_a1
run_a6
run_a7a
run_a5a
run_a5b
run_a7b
MAIN_DONE=1
exit "$RC" # cleanup (EXIT trap) decides the final exit code from results.tsv and the classification
