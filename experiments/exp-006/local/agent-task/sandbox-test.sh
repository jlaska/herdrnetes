#!/usr/bin/env bash
# EXP-006 stage 3: credential-free test of the bwrap sandbox, using the SAME functions agent-demo.sh uses
# (sandbox.sh). No API key, no network, no real secrets: keys and canaries are fake and generated here, and for
# real host paths (~/.ssh, gpg-agent sockets, ...) only existence/connect is probed from INSIDE the sandbox.
# claude runs only as `--version` and once as a network-less TUI smoke test (T12, --unshare-net, no key).
#   experiments/exp-006/local/agent-task/sandbox-test.sh      (exit non-zero if any test fails)
# Output: `TEST <id> PASS|FAIL <detail>`. Extra detail (TUI text, abstract socket names) goes to $SBXTEST_LOG only.
# shellcheck disable=SC2030,SC2031,SC2034 # SBX_EXTRA is read by sandbox.sh; BWRAP is overridden in subshells on purpose
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RAND=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
ROOT=/tmp/hx6t/r$RAND # same layout as a run root
OUT=/tmp/hx6t/o$RAND  # probe outputs, scratch tmux sockets
AHOME=$ROOT/home
CCD=$AHOME/.claude
AXDG=$ROOT/agent-xdg
REPO=$ROOT/repo
PLOG=$REPO/progress.log
SETTINGS=$ROOT/settings.json
CLAUDE_BIN=${CLAUDE_BIN:-$(readlink -f "$(env -i PATH="$PATH" sh -c 'command -v claude')")}
CLAUDE_ID=$(stat -L -c %d:%i "$CLAUDE_BIN" 2>/dev/null)
WANT_VER=${EXP006_CLAUDE_VERSION:-2.1.323 (Claude Code)}
LOG=${SBXTEST_LOG:-${TMPDIR:-/tmp}/exp006-sandbox-test.log}
DIALOG_RX='log ?in|sign ?in|api key|trust|onboarding|theme|select|choose'
PROMPT_RX='\? for shortcuts|^( |│)*(>|❯)'
# shellcheck source=/dev/null
. "$HERE/../sandbox.sh"

FAILS=0
res() { printf 'TEST %s %s %s\n' "$1" "$2" "$3"; [ "$2" = PASS ] || FAILS=$((FAILS + 1)); }
verdict() { if [ -z "$2" ]; then res "$1" PASS "$3"; else res "$1" FAIL "$2"; fi; } # id, problems, detail
tenv() { env -i "PATH=$PATH" "HOME=$HOME" TERM=xterm-256color "$@"; }
hex() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }
: >"$LOG"

cleanup() {
  trap - EXIT INT TERM
  local s
  for s in "$ROOT/tmux.sock" "$OUT"/*.sock; do [ -S "$s" ] && tenv tmux -S "$s" kill-server 2>/dev/null; done
  [ -d "$REPO" ] && sbx_chmod_all 2>/dev/null
  [[ $ROOT =~ ^/tmp/hx6t/[A-Za-z0-9]+$ ]] && rm -rf "$ROOT"
  [[ $OUT =~ ^/tmp/hx6t/[A-Za-z0-9]+$ ]] && rm -rf "$OUT"
  rmdir /tmp/hx6t 2>/dev/null
  exit "${1:-$FAILS}"
}
trap 'cleanup' EXIT INT TERM

# ------------------------------------------------------------------- setup
sbx_preflight || { res PRE FAIL "sandbox preconditions"; exit 1; }
[ -n "$CLAUDE_ID" ] || { res PRE FAIL "claude binary not found"; exit 1; }
mkdir -p /tmp/hx6t
chmod 700 /tmp/hx6t
mkdir -m 700 "$ROOT" "$OUT" || { res PRE FAIL "cannot create test roots"; exit 1; }
KEYDIR=$ROOT/keydir
HC=$ROOT/hostcanary
FAKEKEY=FAKEKEY-$(hex)
SIBLING=SIBLING-$(hex)
CANARY=CANARY-$(hex)
mkdir -p "$KEYDIR" "$HC" "$AHOME" "$AXDG"/{config,state,cache,data,run}
chmod 700 "$AHOME" "$AXDG/run"
echo "$FAKEKEY" >"$KEYDIR/key"
echo "$SIBLING" >"$KEYDIR/sibling"
echo "$CANARY" >"$HC/canary"
chmod 600 "$KEYDIR/key" "$KEYDIR/sibling" "$HC/canary"
echo HOSTFILE >"$ROOT/results.tsv" # must survive untouched
sbx_write_settings "$SETTINGS" withkey
sbx_write_settings "$ROOT/settings-nokey.json" nokey
sbx_seed_home
sbx_init_repo "$HERE/repo" || { res PRE FAIL "task repo"; exit 1; }
sbx_run /usr/bin/true || { res PRE FAIL "sandbox probe failed"; exit 1; }
# A live tmux server on the same socket name the harness uses ($ROOT/tmux.sock): a connect from outside would work.
tenv tmux -S "$ROOT/tmux.sock" -f /dev/null new-session -d -s keep sleep 600
tenv tmux -S "$ROOT/tmux.sock" list-sessions >/dev/null 2>&1 || { res PRE FAIL "scratch tmux"; exit 1; }
HARNESS_CMD=$(tr '\0' ' ' <"/proc/$$/cmdline")
HOSTMARK=$ROOT/git-hook-host-marker
TMPF=/tmp/exp6tmp-$RAND
RUNUSER=/run/user/$UID

EXIST="home=$HOME ssh=$HOME/.ssh gnupg=$HOME/.gnupg ghcfg=$HOME/.config/gh claude=$HOME/.claude claudejson=$HOME/.claude.json slashhome=/home runuser=$RUNUSER keydir=$KEYDIR keyfile=$KEYDIR/key hostcanary=$HC canary=$HC/canary"
HERDR_N=0
for g in "${XDG_RUNTIME_DIR:-$RUNUSER}"/herdr* "$HOME/.config/herdr" "$HOME/.local/state/herdr"; do # existence only
  [ -e "$g" ] && { HERDR_N=$((HERDR_N + 1)); EXIST+=" herdr$HERDR_N=$g"; }
done
CONNECT="gpg=$RUNUSER/gnupg/S.gpg-agent gpgssh=$RUNUSER/gnupg/S.gpg-agent.ssh scd=$RUNUSER/gnupg/S.scdaemon bus=$RUNUSER/bus tmux=$ROOT/tmux.sock herdrsock=$ROOT/herdr/herdr.sock"
WRITES="usr=/usr/exp6w etc=/etc/exp6w opt=/opt/exp6w root=/exp6w res=$ROOT/results.tsv sock=$ROOT/tmux.sock parent=$ROOT/exp6w"

# ------------------------------------------------- adversarial kata.py (import-time probes)
gen_kata() { # <marker for the double-fork sleeper>
  {
    cat "$HERE/repo/kata.py"
    printf '\n# ---- sandbox-test probes (adversarial import-time code; stdout only)\n'
    printf 'EXIST = "%s"\nCONNECT = "%s"\nWRITES = "%s"\n' "$EXIST" "$CONNECT" "$WRITES"
    printf 'KEYDIR = "%s"\nFAKEKEY = "%s"\nSIBLING = "%s"\nREPO = "%s"\nCCD = "%s"\n' "$KEYDIR" "$FAKEKEY" "$SIBLING" "$REPO" "$CCD"
    printf 'CANARY_PATH = "%s/canary"\nHOME_REAL = "%s"\nHARNESS = "%s"\nHOSTMARK = "%s"\nTMPF = "%s"\nMARKER = "%s"\n' \
      "$HC" "$HOME" "$HARNESS_CMD" "$HOSTMARK" "$TMPF" "$1"
    cat <<'PY'
import errno, os, socket, sys


def out(name, val):
    print("PROBE %s %s" % (name, val))
    sys.stdout.flush()


def en(e):
    return errno.errorcode.get(getattr(e, "errno", None) or 0, type(e).__name__)


def conn(p):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(1)
    try:
        s.connect(p)
        return "CONNECTED"
    except Exception as e:
        return "fail:" + en(e)
    finally:
        s.close()


def tryread(p):
    try:
        with open(p, "rb") as f:
            d = f.read(4096)
        return "OK:" + "".join(chr(c) if 32 <= c < 127 else "." for c in d[:200])
    except Exception as e:
        return "fail:" + en(e)


def trywrite(p):
    try:
        os.close(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))
        return "WROTE"
    except Exception as e:
        return "denied:" + en(e)


def relink(p, target):
    try:
        os.unlink(p)
    except OSError:
        pass
    os.symlink(target, p)


# T1 paths, T2 connects
for item in EXIST.split():
    k, p = item.split("=", 1)
    out("exists_" + k, os.path.lexists(p))
for item in CONNECT.split():
    k, p = item.split("=", 1)
    out("conn_" + k, conn(p))
# T3 key
out("key", tryread("/run/exp006/key"))
try:
    out("keydir_listing", ",".join(sorted(os.listdir("/run/exp006"))))
except Exception as e:
    out("keydir_listing", "fail:" + en(e))
out("sibling", os.path.lexists(KEYDIR + "/sibling"))
hits = npid = same = 0
for d in os.listdir("/proc"):
    if not d.isdigit():
        continue
    npid += 1
    for fn in ("cmdline", "environ"):
        try:
            with open("/proc/%s/%s" % (d, fn), "rb") as f:
                c = f.read()
        except Exception:
            continue
        if any(x.encode() in c for x in (KEYDIR, FAKEKEY, SIBLING)):
            hits += 1
        if fn == "cmdline" and c.replace(b"\0", b" ").decode("utf-8", "replace") == HARNESS:
            same += 1
out("key_material_in_proc", hits)
# T6 /proc
out("npids", npid)
out("harness_cmdline_present", same)
try:
    with open("/proc/1/cmdline", "rb") as f:
        out("pid1_argv0", os.path.basename(f.read().split(b"\0")[0].decode()))
except Exception as e:
    out("pid1_argv0", "fail:" + en(e))
# T7 fds (the directory fd used for the listing is excluded)
fds = []
for f in os.listdir("/proc/self/fd"):
    try:
        t = os.readlink("/proc/self/fd/" + f)
    except OSError:
        continue
    if not t.endswith("/fd"):
        fds.append(int(f))
out("fds", ",".join(map(str, sorted(fds))))
# T4 writes
for item in WRITES.split():
    k, p = item.split("=", 1)
    out("write_" + k, trywrite(p))
out("write_repo", trywrite(REPO + "/probe-write"))
out("write_tmp", trywrite(TMPF))
# T5 symlinks planted in the repo and the transcript dir; progress.log replaced by a link to the canary
os.makedirs(CCD + "/projects/p", exist_ok=True)
relink(CCD + "/projects/p/s.jsonl", CANARY_PATH)
for k, t in (("canary", CANARY_PATH), ("ssh", HOME_REAL + "/.ssh"), ("env", "/proc/1/environ"), ("parent", "../..")):
    relink(REPO + "/link-" + k, t)
    out("read_" + k, tryread(REPO + "/link-" + k))
relink(REPO + "/progress.log", CANARY_PATH)
out("read_plog", tryread(REPO + "/progress.log"))
# T9 git exec hooks: all of them touch a marker inside the repo and one on the host
hook = REPO + "/.git/hook.sh"
with open(hook, "w") as f:
    f.write("#!/bin/sh\ntouch %s/hook-ran\ntouch %s\nexit 0\n" % (REPO, HOSTMARK))
os.chmod(hook, 0o755)
with open(REPO + "/.git/config", "w") as f:
    f.write("[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tfsmonitor = %s\n\thooksPath = %s\n[diff]\n\texternal = %s\n"
            % (hook, REPO + "/.git/hooks", hook))
# T14 abstract unix sockets visible through the shared network namespace
ab = []
with open("/proc/net/unix") as f:
    for line in f:
        w = line.split()
        if w and w[-1].startswith("@"):
            ab.append(w[-1])
out("abstract_count", len(ab))
out("abstract_names", ",".join(ab))
# T8 double fork + setsid + a long sleeper whose argv carries MARKER, then exit
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        os.execv("/usr/bin/bash", ["bash", "-c", "sleep 300; : " + MARKER])
    os._exit(0)
out("forked", MARKER)
PY
  } >"$REPO/kata.py"
}

pv() { sed -n "s/^PROBE $2 //p" "$OUT/probe-$1.txt" | head -1; } # path name -> value
marker_gone() { # no host process may carry the marker within 3 s
  local i
  for ((i = 0; i < 30; i++)); do pgrep -f -- "$1" >/dev/null || return 0; sleep 0.1; done
  return 1
}

run_path() { # check = the harness path, agent = the launcher+bwrap args claude gets (fake key, bash -c like the Bash tool)
  local p=$1 mk=EXP6SLP$RAND$1
  gen_kata "$mk"
  case $p in
  check) (exec 7>/dev/null 8<"$HERE/sandbox-test.sh"; agent_check >"$OUT/probe-check.txt" 2>"$OUT/probe-check.err") ;;
  agent)
    sbx_agent_argv "$KEYDIR/key" /usr/bin/bash -c 'python3 check.py --nolog' || return 1
    (exec 7>/dev/null 8<"$HERE/sandbox-test.sh"; timeout -k 2 30 "${AGENT_ARGV[@]}" </dev/null >"$OUT/probe-agent.txt" 2>"$OUT/probe-agent.err")
    ;;
  esac
  marker_gone "$mk" && echo gone >"$OUT/marker-$p" || echo ALIVE >"$OUT/marker-$p"
  pkill -f -- "$mk" 2>/dev/null
  return 0
}
run_path check
run_path agent
for p in check agent; do
  grep -q '^PROBE ' "$OUT/probe-$p.txt" || res PRE FAIL "no probe output on the $p path: $(head -c 300 "$OUT/probe-$p.err")"
  sed "s/^/$p: /" "$OUT/probe-$p.txt" >>"$LOG" # all probe lines (fake key and canary only), local log only
done

# -------------------------------------------------------------------- T1
bad=
for p in check agent; do
  for item in $EXIST; do
    k=${item%%=*}
    v=$(pv "$p" "exists_$k")
    [ "$v" = False ] || bad+="$p:$k=$v "
  done
done
verdict T1 "$bad" "host paths absent inside on both paths: $(wc -w <<<"$EXIST") paths incl. ~/.ssh ~/.gnupg ~/.config/gh ~/.claude /home /run/user keydir hostcanary and $HERDR_N live Herdr candidates"

# -------------------------------------------------------------------- T2
bad=
tenv tmux -S "$ROOT/tmux.sock" list-sessions >/dev/null 2>&1 || bad+="control: live tmux socket not reachable from the host; "
for p in check agent; do
  for item in $CONNECT; do
    k=${item%%=*}
    v=$(pv "$p" "conn_$k")
    case $v in fail:*) ;; *) bad+="$p:$k=$v " ;; esac
  done
done
verdict T2 "$bad" "unix connect fails inside (gpg-agent, gpg ssh, scdaemon, dbus, the LIVE tmux socket, herdr socket path)"

# -------------------------------------------------------------------- T3
bad=
[ "$(pv agent key)" = "OK:$FAKEKEY." ] || bad+="agent key=$(pv agent key) "
[ "$(pv check key)" = "fail:ENOENT" ] || bad+="check has /run/exp006/key: $(pv check key) "
[ "$(pv agent keydir_listing)" = key ] || bad+="agent /run/exp006 listing=$(pv agent keydir_listing) "
for p in check agent; do
  [ "$(pv "$p" sibling)" = False ] || bad+="$p sibling reachable "
  [ "$(pv "$p" key_material_in_proc)" = 0 ] || bad+="$p key material in /proc cmdline/environ: $(pv "$p" key_material_in_proc) "
done
verdict T3 "$bad" "agent reads fake key via /run/exp006/key only; sibling and keydir absent; key path/value in no /proc cmdline or environ; check path has no key"

# -------------------------------------------------------------------- T4
bad=
for p in check agent; do
  for item in $WRITES; do
    k=${item%%=*}
    case $(pv "$p" "write_$k") in denied:*) ;; *) bad+="$p:$k=$(pv "$p" "write_$k") " ;; esac
  done
  [ "$(pv "$p" write_repo)" = WROTE ] || bad+="$p repo write=$(pv "$p" write_repo) "
  [ "$(pv "$p" write_tmp)" = WROTE ] || bad+="$p /tmp write=$(pv "$p" write_tmp) "
done
[ "$(cat "$ROOT/results.tsv")" = HOSTFILE ] || bad+="host results.tsv changed; "
for f in /usr/exp6w /etc/exp6w /opt/exp6w /exp6w "$ROOT/exp6w" "$TMPF"; do [ -e "$f" ] && bad+="host has $f; "; done
[ -S "$ROOT/tmux.sock" ] || bad+="host tmux.sock gone; "
verdict T4 "$bad" "writes to /usr /etc /opt / \$ROOT(results.tsv, tmux.sock) and the repo's parent are denied; repo and /tmp writes work; the /tmp file is absent on the host"

# -------------------------------------------------------------------- T5
bad=
for p in check agent; do
  for k in canary plog; do
    case $(pv "$p" "read_$k") in fail:*) ;; *) bad+="$p read_$k=$(pv "$p" "read_$k") " ;; esac
  done
  case $(pv "$p" read_ssh) in fail:*) ;; *) bad+="$p read_ssh=$(pv "$p" read_ssh) " ;; esac
  case $(pv "$p" read_parent) in fail:*) ;; *) bad+="$p read_parent=$(pv "$p" read_parent) " ;; esac
  v=$(pv "$p" read_env)
  [[ $v == fail:* || $v =~ ^OK:PATH=/usr/bin:/bin\.?$ ]] || bad+="$p read_env=$v "
done
# control: the links are live on the host, so a naive host-side read WOULD leak the canary
[ "$(cat "$REPO/link-canary" 2>/dev/null)" = "$CANARY" ] || bad+="control: link-canary is not live on the host; "
# the harness's own helpers (sandbox.sh) on those same paths
{
  sbx_cat "$REPO/link-canary"
  sbx_cat "$REPO/link-ssh"
  sbx_cat "$REPO/link-env"
  sbx_cat "$REPO/link-parent"
  sbx_cat "$PLOG"
  sbx_sha "$PLOG"
  prog_lines
  prog_after 0
  plog_bad && echo plog_bad
  tj_list
  tj_cat "$CCD/projects/p/s.jsonl"
  agent_has_codeword "$CANARY" && echo CODEWORD-FOUND
  agent_check
  agent_kata_diff
} >"$OUT/t5-host.txt" 2>&1
agent_repo_artifacts "$ROOT"
evid_copy "$ROOT" "$OUT/evid"
n=$(grep -rc "$CANARY" "$OUT/t5-host.txt" "$OUT/evid" "$ROOT/final-check.txt" "$ROOT/progress.log" "$ROOT/kata-final.py" "$ROOT/kata.diff" 2>/dev/null | awk -F: '{s += $NF} END {print s + 0}')
[ "$n" = 0 ] || bad+="CANARY appears $n times in helper output/evidence; "
[ -s "$OUT/evid/final-check.txt" ] && [ -f "$OUT/evid/kata-final.py" ] || bad+="evidence copy is missing final-check.txt/kata-final.py; "
verdict T5 "$bad" "links to canary/~/.ssh//proc/1/environ/../.. and progress.log->canary: unreadable inside; harness helpers (sbx_cat sbx_sha prog_* plog_bad tj_* agent_check agent_kata_diff agent_repo_artifacts evid_copy) never emit the canary"

# -------------------------------------------------------------------- T6
bad=
for p in check agent; do
  [ "$(pv "$p" npids)" -le 10 ] 2>/dev/null || bad+="$p npids=$(pv "$p" npids) "
  [ "$(pv "$p" harness_cmdline_present)" = 0 ] || bad+="$p harness cmdline visible "
  [ "$(pv "$p" pid1_argv0)" = bwrap ] || bad+="$p pid1=$(pv "$p" pid1_argv0) "
done
verdict T6 "$bad" "/proc is the sandbox pid ns: check=$(pv check npids) agent=$(pv agent npids) pids (<=10), harness cmdline absent, pid 1 is bwrap"

# -------------------------------------------------------------------- T7
bad=
for p in check agent; do
  [ "$(pv "$p" fds)" = 0,1,2 ] || bad+="$p fds=$(pv "$p" fds) "
done
verdict T7 "$bad" "with fds 7 and 8 open in the harness (and fd 9 on the key in the launcher) only 0,1,2 exist inside; no fd 9"

# -------------------------------------------------------------------- T8
bad=
for p in check agent; do [ "$(cat "$OUT/marker-$p")" = gone ] || bad+="$p sleeper survived; "; done
# long-running agent-path sandbox in tmux: kill-server must take outer bwrap, init and child down (this is also T10)
S10=$OUT/s10.sock
bad10=
sbx_agent_argv "$KEYDIR/key" /usr/bin/sleep 300 || bad10+="argv; "
tenv tmux -S "$S10" -f /dev/null new-session -d -s s -x 100 -y 20 -c "$REPO" "${AGENT_ARGV[@]}" || bad10+="tmux; "
O10=$(tenv tmux -S "$S10" display-message -p -t s '#{pane_pid}')
SLEEP_ID=$(stat -L -c %d:%i /usr/bin/sleep)
ok=
for ((i = 0; i < 100; i++)); do sbx_identify "$O10" "$SLEEP_ID" && { ok=1; break; }; sleep 0.1; done
if [ -n "$ok" ]; then
  A10=$APID
  I10=$BINIT
  S_O=$(proc_start "$O10")
  S_I=$(proc_start "$I10")
  S_A=$(proc_start "$A10")
  sbx_ns_report "$A10" >"$OUT/ns10.txt"
  [ -z "$NSBAD" ] || bad10+="namespaces: $NSBAD"
  [ "$(exe_id "$O10")" != "$SLEEP_ID" ] || bad10+="outer bwrap has the sleep inode; "
  sbx_identify "$O10" 1:1 && bad10+="identity rule matched a bogus inode; "
  tenv tmux -S "$S10" kill-server
  for ((i = 0; i < 50; i++)); do gone "$O10" "$S_O" && gone "$I10" "$S_I" && gone "$A10" "$S_A" && break; sleep 0.1; done
  gone "$O10" "$S_O" && gone "$I10" "$S_I" && gone "$A10" "$S_A" || bad+="after kill-server: outer/init/child still alive; "
else
  bad10+="identity rule found no unique sleep under pane_pid $O10; "
fi
verdict T8 "$bad" "double-forked setsid sleepers die with the sandbox (sbx_run and agent path); kill-server on the tmux socket takes outer bwrap ($O10), init (${I10:-?}) and child (${A10:-?}) down"
verdict T10 "$bad10" "running agent-path sandbox: mnt/pid/user/uts/ipc differ, net same, NSpid two-level, unique process by exe inode ($SLEEP_ID); bogus inode rejected"

# -------------------------------------------------------------------- T9
bad=
rm -f "$HOSTMARK"
sbx_run rm -f "$REPO/hook-ran"
sbx_run git -C "$REPO" diff >/dev/null 2>&1 # control: the planted config is live (diff.external runs the hook)
control=$(sbx_run test -e "$REPO/hook-ran" && echo hook-ran || echo no-hook)
sbx_run rm -f "$REPO/hook-ran"
agent_kata_diff >/dev/null 2>&1
sbx_run test -e "$REPO/hook-ran" && bad+="hook ran inside under agent_kata_diff; "
[ -e "$HOSTMARK" ] && bad+="host marker exists; "
verdict T9 "$bad" "planted core.fsmonitor/core.hooksPath/diff.external: agent_kata_diff runs none of them (control without the overrides: $control); host marker absent"

# -------------------------------------------------------------------- T11
bad=
sbx_agent_argv "$KEYDIR/key" /opt/exp006/claude --version || bad+="argv; "
v=$(timeout -k 2 30 "${AGENT_ARGV[@]}" </dev/null 2>&1)
[ "$v" = "$WANT_VER" ] || bad+="got '$v'; "
verdict T11 "$bad" "claude --version through the agent launch config (fake key mounted): $v"

# -------------------------------------------------------------------- T12
bad=
S12=$OUT/s12.sock
SETTINGS=$ROOT/settings-nokey.json
SBX_EXTRA=(--unshare-net)
sbx_agent_argv "" /opt/exp006/claude --bare --settings "$SETTINGS" --strict-mcp-config --tools Read,Edit,Bash \
  --model claude-sonnet-5-5 --effort medium --session-id "$(cat /proc/sys/kernel/random/uuid)" || bad+="argv; "
SBX_EXTRA=()
SETTINGS=$ROOT/settings.json
tenv tmux -S "$S12" -f /dev/null new-session -d -s s -x 160 -y 45 -c "$REPO" "${AGENT_ARGV[@]}" || bad+="tmux; "
tenv tmux -S "$S12" set-option -g remain-on-exit on
O12=$(tenv tmux -S "$S12" display-message -p -t s '#{pane_pid}')
cap=
for ((i = 0; i < 15; i++)); do
  cap=$(tenv tmux -S "$S12" capture-pane -p -t s 2>/dev/null)
  grep -q . <<<"$cap" && break
  sleep 1
done
sleep 2
cap=$(tenv tmux -S "$S12" capture-pane -p -t s 2>/dev/null)
alive=no
if sbx_identify "$O12" "$CLAUDE_ID"; then
  alive=yes
  A12=$APID I12=$BINIT
  S_O=$(proc_start "$O12") S_I=$(proc_start "$I12") S_A=$(proc_start "$A12")
  [ "$(readlink "/proc/$A12/ns/net")" != "$(readlink "/proc/$$/ns/net")" ] || bad+="--unshare-net did not give a private net namespace; "
fi
{
  echo "== T12 TUI smoke (no network, no key); claude alive=$alive"
  grep . <<<"$cap" | head -20
} >>"$LOG"
cls=
grep -qiE "$DIALOG_RX" <<<"$cap" && cls+="DIALOG_RX "
grep -qE "$PROMPT_RX" <<<"$cap" && cls+="PROMPT_RX "
[ -n "$cls" ] || cls=none
grep -q . <<<"$cap" || bad+="empty capture; "
[ "$alive" = yes ] || bad+="claude not alive under bwrap (inode rule) after the capture; "
tenv tmux -S "$S12" kill-server 2>/dev/null
if [ "$alive" = yes ]; then
  for ((i = 0; i < 50; i++)); do gone "$O12" "$S_O" && gone "$I12" "$S_I" && gone "$A12" "$S_A" && break; sleep 0.1; done
  gone "$O12" "$S_O" && gone "$I12" "$S_I" && gone "$A12" "$S_A" || bad+="after kill-server: still alive; "
fi
verdict T12 "$bad" "network-less TUI smoke (--unshare-net, no key): alive=$alive, capture $(grep -c . <<<"$cap") non-empty lines, classification: $cls (text in $LOG)"

# -------------------------------------------------------------------- T13
bad=
( SETTINGS=$ROOT/does-not-exist; sbx_args 2>/dev/null ) && bad+="sbx_args accepted a missing bind source; "
( SETTINGS=$ROOT/does-not-exist; sbx_run /usr/bin/touch "$ROOT/m13a" 2>/dev/null ) && bad+="sbx_run ran with a missing bind source; "
[ -e "$ROOT/m13a" ] && bad+="m13a created; "
( BWRAP=/nonexistent; sbx_run /usr/bin/touch "$ROOT/m13b" 2>/dev/null ) && bad+="sbx_run succeeded with an unusable bwrap; "
[ -e "$ROOT/m13b" ] && bad+="m13b created (command ran unsandboxed); "
( BWRAP=/nonexistent; sbx_agent_argv "$KEYDIR/key" /usr/bin/touch "$ROOT/m13c" 2>/dev/null ) && bad+="sbx_agent_argv accepted an unusable bwrap; "
sbx_agent_argv "$KEYDIR/key" /usr/bin/touch "$ROOT/m13d" || bad+="argv; "
for i in "${!AGENT_ARGV[@]}"; do [ "${AGENT_ARGV[$i]}" = "$BWRAP" ] && AGENT_ARGV[i]=/nonexistent; done # launcher with a broken bwrap
timeout 10 "${AGENT_ARGV[@]}" </dev/null >/dev/null 2>&1 && bad+="launcher succeeded with a broken bwrap; "
[ -e "$ROOT/m13d" ] && bad+="m13d created (command ran unsandboxed); "
verdict T13 "$bad" "missing bind source or unusable bwrap: sbx_args/sbx_run/launcher fail and the command never runs unsandboxed (markers absent)"

# -------------------------------------------------------------------- T14
n=$(pv agent abstract_count)
{ echo "== T14 abstract unix sockets visible inside: check=$(pv check abstract_count) agent=$n"; } >>"$LOG"
res T14 PASS "informational: $n abstract unix sockets visible inside via the shared net namespace (names in $LOG only)"

# -------------------------------------------------------------------- T15
if "$HERE/selftest.sh" >"$OUT/selftest.txt" 2>&1 && grep -qx 'SELFTEST PASS' "$OUT/selftest.txt"; then
  res T15 PASS "agent-task/selftest.sh"
else
  res T15 FAIL "agent-task/selftest.sh: $(tail -3 "$OUT/selftest.txt" | tr '\n' ' ')"
fi

echo
if [ "$FAILS" -gt 0 ]; then echo "SANDBOX-TEST: FAIL ($FAILS)"; else echo "SANDBOX-TEST: PASS"; fi
cleanup
