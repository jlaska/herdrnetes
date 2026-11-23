#!/usr/bin/env bash
# Offline tests for the client-detection region of demo.sh. Starts no process, uses no network:
# every /proc read goes to a fake tree under a mktemp -d directory, removed on exit.
# Usage: bash experiments/exp-008/local/tests/clients-test.sh
set -u
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
DEMO="$HERE/../demo.sh"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT

die() { echo "FAIL setup: $*" >&2; exit 2; }

# ------------------------------------------------------------ load code under test
[ -r "$DEMO" ] || die "cannot read $DEMO"
[ "$(grep -c -x -F '# >>> client-detection' "$DEMO")" = 1 ] || die "marker '# >>> client-detection' missing"
[ "$(grep -c -x -F '# <<< client-detection' "$DEMO")" = 1 ] || die "marker '# <<< client-detection' missing"
REGION=$(awk '$0 == "# >>> client-detection" { f = 1; next } $0 == "# <<< client-detection" { f = 0 } f' "$DEMO")
[ -n "$REGION" ] || die "client-detection region is empty"

# multi-line function: from its "name() {" line to the first line that is exactly "}"
t_fn() { awk -v n="$1" 'index($0, n "() {") == 1 { f = 1 } f { print } f && $0 == "}" { exit }' "$DEMO"; }
# one-line function
t_oneliner() { awk -v n="$1" 'index($0, n "() {") == 1 { print; exit }' "$DEMO"; }

FN_START=$(t_fn proc_start)
FN_GONE=$(t_fn gone)
FN_ALIVE=$(t_oneliner alive_same)
[ -n "$FN_START" ] || die "proc_start not found in $DEMO"
[ -n "$FN_GONE" ] || die "gone not found in $DEMO"
[ -n "$FN_ALIVE" ] || die "alive_same not found in $DEMO"
[ "$(printf '%s\n' "$FN_START" | tail -n 1)" = "}" ] || die "proc_start is not closed by '}'"
[ "$(printf '%s\n' "$FN_GONE" | tail -n 1)" = "}" ] || die "gone is not closed by '}'"

# rewrite the literal /proc/ to $PROCFS/ in the extracted text only
FNS=$(printf '%s\n' "$FN_START" "$FN_GONE" "$FN_ALIVE" | sed "s|/proc/|\$PROCFS/|g")
printf '%s\n' "$FNS" | grep -q '/proc/' && die "unrewritten /proc/ left in helper text"

E=/tmp/hx8/T1/e
GW=exp008-T1
PORT=23886
CLI_REAL=/tmp/hx8/T1/bin/cli/openshell
PROCFS="$T/proc"
OK_URL="https://127.0.0.1:$PORT"
eval "$FNS"
eval "$REGION"

# ------------------------------------------------------------ fake procfs
PANE_ARGV=(/usr/bin/bash --noprofile --rcfile "$E/pane-bashrc" -i)
CONNECT_ARGV=("$CLI_REAL" -g "$GW" sandbox connect "$GW")

t_reset() { rm -rf "$PROCFS"; mkdir -p "$PROCFS"; }

# t_mk <pid> <ppid> <start> <exe> <run|none> <argv...>: one fake /proc/<pid>
t_mk() {
  local pid=$1 ppid=$2 start=$3 exe=$4 env=$5 d
  shift 5
  d="$PROCFS/$pid"
  mkdir -p "$d"
  ln -s "$exe" "$d/exe"
  printf '%s\0' "$@" >"$d/cmdline"
  # field 22 (starttime) is the 19th field after the ") " that ends comm
  printf '%s (%s) S %s %s %s 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' \
    "$pid" "${exe##*/}" "$ppid" "$pid" "$pid" "$start" >"$d/stat"
  if [ "$env" = run ]; then
    printf 'PATH=/usr/bin\0XDG_CONFIG_HOME=%s/config\0HOME=%s/home\0' "$E" "$E" >"$d/environ"
  else
    printf 'PATH=/usr/bin\0HOME=/home/someone\0' >"$d/environ"
  fi
}

# recorded start time of fake pid N
t_st() { echo $(($1 * 10)); }

# t_transport_argv <gateway-url>: TA = argv of the run's transport ssh, ProxyCommand to that url
t_transport_argv() {
  TA=(/usr/bin/ssh -F "$E/ssh_config" -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile=none
    -o PKCS11Provider=none -o ForwardAgent=no
    -o "ProxyCommand=$CLI_REAL ssh-proxy --gateway '$1' --sandbox $GW --workspace default --token abcDEF-123_456.789 --gateway-name $GW"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ControlMaster=no -o ControlPath=none -o ControlPersist=no
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -tt -o RequestTTY=force -o SetEnv=TERM=xterm-256color
    -s sandbox openshell-main)
}

# t_proxy_argv <gateway-url>: PA = argv of the run's ssh-proxy
t_proxy_argv() {
  PA=("$CLI_REAL" ssh-proxy --gateway "$1" --sandbox "$GW" --workspace default --token abcDEF-123_456.789 --gateway-name "$GW")
}

# t_chain <shell> <cli> <ssh> <proxy> [transport-url] [proxy-url]: pane shell, then cli -> ssh -> proxy
t_chain() {
  local tu=${5:-$OK_URL} pu=${6:-$OK_URL}
  t_mk "$1" 1 "$(t_st "$1")" /usr/bin/bash none "${PANE_ARGV[@]}"
  t_mk "$2" "$1" "$(t_st "$2")" "$CLI_REAL" run "${CONNECT_ARGV[@]}"
  t_transport_argv "$tu"
  t_mk "$3" "$2" "$(t_st "$3")" /usr/bin/ssh run "${TA[@]}"
  t_proxy_argv "$pu"
  t_mk "$4" "$3" "$(t_st "$4")" "$CLI_REAL" run "${PA[@]}"
}

# class of one pid in the current tree
t_class() { client_snap | awk -v p="$1" '$1 != "attached" && $2 == p { print $1 }'; }

# argv field (6th) of one pid as proc_table records it
t_argv_of() { proc_table | awk -F '\t' -v p="$1" '$1 == p { print $6 }'; }

# ------------------------------------------------------------ assertions
ERRS=""
PASS_N=0
FAIL_N=0
# t_check <label> <cmd...>: records a failure unless the command succeeds
t_check() {
  local label=$1
  shift
  "$@" >/dev/null 2>&1 || ERRS+="    - $label"$'\n'
}
# t_eq <label> <expected> <actual>
t_eq() { [ "$2" = "$3" ] || ERRS+="    - $1: expected [$2] got [$3]"$'\n'; }
t_not() { ! "$@"; }
# the run-1123 predicate, verbatim: case " ${a[*]} " in *" sandbox "*" connect "*)
t_old_glob() {
  local a=("$@")
  case " ${a[*]} " in *" sandbox "*" connect "*) return 0 ;; esac
  return 1
}
# t_case <name> <fn>: one case on a fresh tree, one PASS/FAIL line
t_case() {
  ERRS=""
  t_reset
  "$2"
  if [ -z "$ERRS" ]; then
    echo "PASS $1"
    PASS_N=$((PASS_N + 1))
  else
    echo "FAIL $1"
    printf '%s' "$ERRS"
    FAIL_N=$((FAIL_N + 1))
  fi
}

# ------------------------------------------------------------ cases
case_1() { # normal attach: pane shell 100 -> cli 101 -> ssh 102 -> proxy 103
  t_chain 100 101 102 103
  t_eq "fake stat field 22" 1010 "$(awk '{ print $22 }' "$PROCFS/101/stat")"
  t_eq "counts" "attached=1 cli=1 transport=1 proxy=1 run-ssh=0 other=0" "$(client_counts)"
  t_eq "attached line" "attached 101 1010 102 1020 103 1030" "$(client_snap | grep '^attached ')"
  t_check "clients_eq 1" clients_eq 1
  t_check "clients_ge 1" clients_ge 1
  t_check "no_client_procs is false" t_not no_client_procs
  t_check "att_alive" att_alive "101:1010 102:1020 103:1030"
  t_eq "att_ssh" 102 "$(att_ssh "101:1010 102:1020 103:1030")"
  t_eq "clients_pids" 101 "$(clients_pids)"
  t_eq "ssh_pids" 102 "$(ssh_pids)"
  t_eq "proxy_pids" 103 "$(proxy_pids)"
}

case_2() { # run-1123 regression: the exact CLI argv is "cli"; the old glob never matched it
  t_mk 101 100 1010 "$CLI_REAL" run "${CONNECT_ARGV[@]}"
  t_eq "class" "cli 101 1010 100" "$(client_snap)"
  t_eq "counts" "attached=0 cli=1 transport=0 proxy=0 run-ssh=0 other=0" "$(client_counts)"
  t_check "old glob does not match the connect argv" t_not t_old_glob "${CONNECT_ARGV[@]}"
  t_check "clients_eq 0 (no chain)" clients_eq 0
}

case_3() { # two full chains (A6)
  t_chain 100 101 102 103
  t_chain 200 201 202 203
  t_eq "counts" "attached=2 cli=2 transport=2 proxy=2 run-ssh=0 other=0" "$(client_counts)"
  t_check "clients_eq 2" clients_eq 2
  t_check "clients_ge 2" clients_ge 2
  t_check "no_client_procs is false" t_not no_client_procs
  t_check "att_alive chain A" att_alive "101:1010 102:1020 103:1030"
  t_check "att_alive chain B" att_alive "201:2010 202:2020 203:2030"
}

case_4() { # CLI 101 terminated; ssh 102 orphaned to ppid 1; proxy 103 still under ssh
  t_transport_argv "$OK_URL"
  t_mk 102 1 1020 /usr/bin/ssh run "${TA[@]}"
  t_proxy_argv "$OK_URL"
  t_mk 103 102 1030 "$CLI_REAL" run "${PA[@]}"
  t_eq "counts" "attached=0 cli=0 transport=1 proxy=1 run-ssh=0 other=0" "$(client_counts)"
  t_check "no_client_procs is false" t_not no_client_procs
  t_eq "client_procs" 2 "$(client_procs)"
  t_check "att_gone on old chain is false (ssh alive)" t_not att_gone "101:1010 102:1020 103:1030"
}

case_5() { # transport lost while the CLI is in recovery: cli alive, ssh and proxy gone
  t_mk 101 100 1010 "$CLI_REAL" run "${CONNECT_ARGV[@]}"
  t_eq "counts" "attached=0 cli=1 transport=0 proxy=0 run-ssh=0 other=0" "$(client_counts)"
  t_check "no_client_procs is false" t_not no_client_procs
}

case_6() { # fully detached: nothing, or only the pane shell
  t_eq "empty tree counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=0" "$(client_counts)"
  t_mk 100 1 1000 /usr/bin/bash none "${PANE_ARGV[@]}"
  t_eq "pane-only counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=0" "$(client_counts)"
  t_check "no_client_procs" no_client_procs
  t_check "clients_eq 0" clients_eq 0
  t_check "att_gone on recorded chain" att_gone "101:1010 102:1020 103:1030"
  t_check "att_gone with empty chain is false" t_not att_gone ""
  t_check "att_gone with 2 entries is false" t_not att_gone "101:1010 102:1020"
  # recycled pids: same pid numbers, different start times, not clients
  t_mk 101 100 9999 /usr/bin/bash none bash
  t_mk 102 101 9998 /usr/bin/bash none bash
  t_mk 103 102 9997 /usr/bin/bash none bash
  t_check "att_gone with recycled pids is true" att_gone "101:1010 102:1020 103:1030"
  t_check "att_alive with recycled pids is false" t_not att_alive "101:1010 102:1020 103:1030"
  t_eq "recycled pids counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=0" "$(client_counts)"
}

case_7() { # unrelated ssh: always "other", never transport/run-ssh; argv not recorded
  # (a) plain ssh, no run env
  t_mk 301 300 3010 /usr/bin/ssh none /usr/bin/ssh -F /home/someone/.ssh/config git@example.com
  t_eq "a counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=1" "$(client_counts)"
  t_eq "a argv" "-" "$(t_argv_of 301)"
  t_reset
  # (b) owner's own connect to another gateway, parent is a non-run openshell
  t_mk 401 1 4010 /usr/bin/openshell none /usr/bin/openshell connect mybox
  t_mk 402 401 4020 /usr/bin/ssh none /usr/bin/ssh -o "ProxyCommand=/usr/bin/openshell ssh-proxy --gateway 'https://gw.example.com:443' --sandbox mybox --workspace default --token x --gateway-name other" -tt -s sandbox openshell-main
  t_eq "b counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=1" "$(client_counts)"
  t_eq "b argv" "-" "$(t_argv_of 402)"
  t_reset
  # (c) unrelated ssh whose environ is unreadable; argv does not name the run
  t_mk 501 500 5010 /usr/bin/ssh none /usr/bin/ssh -F /home/someone/.ssh/config git@example.com
  chmod 000 "$PROCFS/501/environ"
  t_check "c environ is unreadable (not root)" t_not test -r "$PROCFS/501/environ"
  t_eq "c counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=1" "$(client_counts 2>"$T/err")"
  t_check "c no error output" test ! -s "$T/err"
  t_eq "c argv" "-" "$(t_argv_of 501)"
  t_reset
  # (c2) unrelated ssh whose argv names the run's dir (environ is read), environ unreadable
  t_mk 601 600 6010 /usr/bin/ssh none /usr/bin/ssh -F /home/someone/.ssh/config -o IdentityFile="$E/key" git@example.com
  chmod 000 "$PROCFS/601/environ"
  t_eq "c2 counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=1" "$(client_counts 2>"$T/err")"
  t_check "c2 no error output" test ! -s "$T/err"
}

case_8() { # wrong scope: each is not a client of this run
  # (a) transport-shaped ssh with the run's ssh_config, ProxyCommand to port 9999 -> run-ssh
  t_chain 100 101 102 103 "https://127.0.0.1:9999"
  t_eq "a class of ssh 102" "run-ssh" "$(t_class 102)"
  t_eq "a counts" "attached=0 cli=1 transport=0 proxy=1 run-ssh=1 other=0" "$(client_counts)"
  t_check "a no_client_procs is false" t_not no_client_procs
  t_reset
  # (b) proxy to port 9999 -> other
  t_proxy_argv "https://127.0.0.1:9999"
  t_mk 103 1 1030 "$CLI_REAL" run "${PA[@]}"
  t_eq "b class of proxy 103" "other" "$(t_class 103)"
  t_eq "b counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=1" "$(client_counts)"
  t_reset
  # (c) the create CLI -> other, not cli
  t_mk 101 100 1010 "$CLI_REAL" run "$CLI_REAL" -g "$GW" sandbox create --detach --tty --name "$GW" --from img -- /usr/local/bin/counter.sh /sandbox/out
  t_eq "c class" "other" "$(t_class 101)"
  t_eq "c counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=1" "$(client_counts)"
  t_reset
  # (d) connect to a different sandbox -> other
  t_mk 101 100 1010 "$CLI_REAL" run "$CLI_REAL" -g "$GW" sandbox connect other-box
  t_eq "d class" "other" "$(t_class 101)"
  t_reset
  # (e) the exact connect argv without the run env -> other
  t_mk 101 100 1010 "$CLI_REAL" none "${CONNECT_ARGV[@]}"
  t_eq "e class" "other" "$(t_class 101)"
  t_eq "e counts" "attached=0 cli=0 transport=0 proxy=0 run-ssh=0 other=1" "$(client_counts)"
}

case_9() { # gateway url: a path after the port is accepted; a port prefix collision is rejected
  # proxy url with a path -> accepted as a proxy
  t_chain 100 101 102 103 "$OK_URL" "$OK_URL/x"
  t_eq "path in proxy url: counts" "attached=1 cli=1 transport=1 proxy=1 run-ssh=0 other=0" "$(client_counts)"
  t_reset
  # prefix collision (238860) for the proxy -> other
  t_chain 100 101 102 103 "$OK_URL" "https://127.0.0.1:238860"
  t_eq "collision proxy class" "other" "$(t_class 103)"
  t_eq "collision proxy counts" "attached=0 cli=1 transport=1 proxy=0 run-ssh=0 other=1" "$(client_counts)"
  t_reset
  # prefix collision (238860) for the transport ProxyCommand -> run-ssh, not transport
  t_chain 100 101 102 103 "https://127.0.0.1:238860"
  t_eq "collision transport class" "run-ssh" "$(t_class 102)"
  t_eq "collision transport counts" "attached=0 cli=1 transport=0 proxy=1 run-ssh=1 other=0" "$(client_counts)"
  t_reset
  # extra: a path after the port is also accepted in the transport ProxyCommand
  t_chain 100 101 102 103 "$OK_URL/x"
  t_eq "path in transport url: counts" "attached=1 cli=1 transport=1 proxy=1 run-ssh=0 other=0" "$(client_counts)"
}

t_case "1 normal attach" case_1
t_case "2 run-1123 regression: exact connect argv is cli" case_2
t_case "3 two clients" case_3
t_case "4 CLI terminated, ssh and proxy orphaned" case_4
t_case "5 transport lost while CLI in recovery" case_5
t_case "6 fully detached, recycled pids, unknown chain" case_6
t_case "7 unrelated ssh is other, argv not recorded" case_7
t_case "8 wrong scope is not a client" case_8
t_case "9 gateway url path accepted, port prefix rejected" case_9

echo "cases: $((PASS_N + FAIL_N)) run, $FAIL_N failed"
[ "$FAIL_N" -eq 0 ]
