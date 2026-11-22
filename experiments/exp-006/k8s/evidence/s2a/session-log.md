# EXP-006 stage 2 run s2a: session command log (sanitized)

Extracted from the agent session transcript: the setup render step and every K00–K06 shell command as issued, with its captured output, in order.
Substitutions: `<g1>`/`<scratch>`/`<tasks>` = local scratch paths; `node-L` = node of the live Herdr pod, `node-E` = exec pod node, `node-H` = scratch Herdr pod node; pod UIDs as `<...-uid>` tokens. The K00 baseline output is replaced by a summary. Each command ran in a fresh `bash` that sources `<g1>/lib.sh` (see `helper-lib.sh`).
Working directory for every command: `experiments/exp-006/k8s` (the transcript records commands without the leading `cd`).

### Setup: create work dir, render manifests, check run_ok (local only)

```
$ G=<g1>
bash -c '. "$0"/lib.sh; test ! -e "$WORK" && mkdir -m 700 "$WORK" && mkdir "$WORK"/{m,keys,ev} && for f in manifests/*.yaml; do sed "s/\${RUN_ID}/$RUN_ID/g" "$f" >"$WORK/m/$(basename "$f")"; done && ls "$WORK/m" && run_ok && echo RUN_OK' "$G"; echo "exit=$?"
```

Output:

```
exec-pod.yaml
herdr-pod.yaml
namespace.yaml
networkpolicy.yaml
service.yaml
RUN_OK
exit=0
```

### K00: run read-only identity and live-system guards

```
$ G=<g1>
bash -c '. "$0"/lib.sh; ctx_ok && echo CTX_OK' "$G"; echo "exit=$?"
bash -c '. "$0"/lib.sh; live_ok && echo LIVE_OK' "$G"; echo "exit=$?"
```

Output:

```
CTX_OK
exit=0
LIVE_OK
exit=0
```

### K00: capture live-system baseline

```
$ G=<g1>
bash -c '. "$0"/lib.sh; ctx_ok && live_ok && run_ok && baseline >"$WORK/ev/k00.txt"; r=$?; echo "rc=$r"; cat "$WORK/ev/k00.txt"' "$G"
```

Output:

```
(rc=0. The 1100-line baseline written to k00.txt is withheld: it holds node names, the live pod's UID and node,
live object names and the cluster-wide PV inventory. Non-sensitive content: 3 nodes Ready=True; live herdr-0
restartCount 0/0 with images ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae…8e277 and
ghcr.io/jlaska/herdrnetes-ovis@sha256:8e31cc27…0db; Argo CD app "Synced Healthy". Its sha256 is in baseline-check.txt.)
```

### K00: namespace absence, labels, node schedulability, PV refs

```
$ G=<g1>
bash -c '. "$0"/lib.sh; $K get ns "$NS"; echo "rc=$?"' "$G" 2>&1
bash -c '. "$0"/lib.sh; $K get ns -l herdrnetes.io/experiment=exp-006; echo "rc=$?"' "$G" 2>&1
bash -c '. "$0"/lib.sh; $K get nodes -o jsonpath="{range .items[*]}{.metadata.name} unsched={.spec.unschedulable} taints={.spec.taints}{\"\n\"}{end}"; echo "rc=$?"' "$G" 2>&1
bash -c '. "$0"/lib.sh; $K get pv -o json | jq -e --arg ns "$NS" "[.items[]|select(.spec.claimRef.namespace==\$ns)]|length==0"; echo "rc=$?"' "$G" 2>&1
```

Output:

```
Error from server (NotFound): namespaces "herdrnetes-exp006-s2a" not found
rc=1
No resources found
rc=0
node-H unsched= taints=
node-E unsched= taints=
node-L unsched= taints=
rc=0
true
rc=0
```

### K01: create scratch namespace through guarded wrapper

```
$ G=<g1>
bash -c '. "$0"/lib.sh; M create -f "$WORK/m/namespace.yaml" && ns_ok; echo "rc=$?"' "$G" 2>&1
```

Output:

```
namespace/herdrnetes-exp006-s2a created
rc=0
```

### K01: create network policies and service

```
$ G=<g1>
bash -c '. "$0"/lib.sh; MN create -f "$WORK/m/networkpolicy.yaml" -f "$WORK/m/service.yaml"; echo "rc=$?"' "$G" 2>&1
```

Output:

```
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/herdr-egress created
networkpolicy.networking.k8s.io/exec-ingress created
service/exp006-exec created
rc=0
```

### K01: generate two throwaway ed25519 keypairs locally

```
$ G=<g1>
bash -c '. "$0"/lib.sh
env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N "" -C "exp006-host-$RUN_ID" -f "$WORK/keys/host"; echo "keygen-host rc=$?"
env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N "" -C "exp006-client-$RUN_ID" -f "$WORK/keys/client"; echo "keygen-client rc=$?"' "$G" 2>&1 </dev/null
```

Output:

```
keygen-host rc=0
keygen-client rc=0
```

### K01: write authorized_keys and known_hosts; show structure only

```
$ G=<g1>
bash -c '. "$0"/lib.sh
printf '"'"'restrict,pty,command="tmux -S /tmp/agent/tmux.sock -f /dev/null attach -t agent" %s\n'"'"' "$(cut -d" " -f1,2 "$WORK/keys/client.pub")" >"$WORK/keys/authorized_keys"; echo "authkeys rc=$?"
printf "exp006-exec %s\n" "$(cut -d" " -f1,2 "$WORK/keys/host.pub")" >"$WORK/keys/known_hosts"; echo "known_hosts rc=$?"
ls -l "$WORK/keys" | awk "{print \$1, \$5, \$9}"
# structure only, no key text
sed -E "s/ssh-ed25519 [A-Za-z0-9+\/=]+/ssh-ed25519 <pub>/" "$WORK/keys/authorized_keys" "$WORK/keys/known_hosts"' "$G" 2>&1
```

Output:

```
authkeys rc=0
known_hosts rc=0
total  
-rw-------. 162 authorized_keys
-rw-------. 411 client
-rw-------. 99 client.pub
-rw-------. 411 host
-rw-------. 97 host.pub
-rw-------. 93 known_hosts
restrict,pty,command="tmux -S /tmp/agent/tmux.sock -f /dev/null attach -t agent" ssh-ed25519 <pub>
exp006-exec ssh-ed25519 <pub>
```

### K01: create exec SSH secret

```
$ G=<g1>
bash -c '. "$0"/lib.sh; MN create secret generic exp006-exec-ssh --from-file=ssh_host_ed25519_key="$WORK/keys/host" --from-file=authorized_keys="$WORK/keys/authorized_keys"; echo "rc=$?"' "$G" 2>&1
```

Output:

```
secret/exp006-exec-ssh created
rc=0
```

### K01: create client SSH secret

```
$ G=<g1>
bash -c '. "$0"/lib.sh; MN create secret generic exp006-client-ssh --from-file=id_ed25519="$WORK/keys/client" --from-file=known_hosts="$WORK/keys/known_hosts"; echo "rc=$?"' "$G" 2>&1
```

Output:

```
secret/exp006-client-ssh created
rc=0
```

### K01: label the two secrets

```
$ G=<g1>
bash -c '. "$0"/lib.sh; MN label secret exp006-exec-ssh exp006-client-ssh herdrnetes.io/experiment=exp-006 herdrnetes.io/run-id="$RUN_ID"; echo "rc=$?"' "$G" 2>&1
```

Output:

```
secret/exp006-exec-ssh labeled
secret/exp006-client-ssh labeled
rc=0
```

### K01: create exec pod and wait for Ready

```
$ G=<g1>
bash -c '. "$0"/lib.sh; date -u +%FT%TZ; MN create -f "$WORK/m/exec-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-exec --timeout=300s; echo "rc=$?"; date -u +%FT%TZ' "$G" 2>&1
```

Output:

```
2026-11-22T17:59:01Z
pod/exp006-exec created
pod/exp006-exec condition met
rc=0
2026-11-22T17:59:04Z
```

### K01: record exec pod UID, node, restarts, image

```
$ G=<g1>
bash -c '. "$0"/lib.sh; $K -n "$NS" get pod exp006-exec -o jsonpath="{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].state.running.startedAt} {.status.containerStatuses[0].imageID}{\"\n\"}" | tee "$WORK/ev/k01-pod.txt"; echo "rc=$?"' "$G" 2>&1
```

Output:

```
<exec-pod-uid> node-E 0 2026-11-22T17:59:03Z ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16
rc=0
```

### K01: read exec process identity file

```
$ G=<g1>
bash -c '. "$0"/lib.sh; X cat /tmp/agent/out/identity | tee "$WORK/ev/k01-identity.txt"; echo "rc=$?"' "$G" 2>&1
```

Output:

```
pid=17
start=29585526
nonce=4d941f1d19cdad5d
rc=0
```

### K01: verify /proc start time and process tree

```
$ G=<g1>
bash -c '. "$0"/lib.sh; X bash -c '"'"'p=$(sed -n "s/^pid=//p" /tmp/agent/out/identity); sed "s/.*) //" /proc/$p/stat | awk "{print \$20}"; ps -eo pid,ppid,cmd'"'"' | tee "$WORK/ev/k01-ps.txt"; echo "rc=$?"' "$G" 2>&1
```

Output:

```
29585526
    PID    PPID CMD
      1       0 /usr/bin/tini -- /usr/local/bin/exp006-entrypoint
      7       1 sshd: /usr/sbin/sshd -D -e -f /tmp/ssh/sshd_config [listener] 0 of 10-100 startups
     16       1 tmux -S /tmp/agent/tmux.sock -f /dev/null new-session -d -s agent /usr/local/bin/counter.sh /tmp/agent/out
     17      16 bash /usr/local/bin/counter.sh /tmp/agent/out
     43       0 ps -eo pid,ppid,cmd
rc=0
```

### K02: create scratch Herdr pod and wait for Ready

```
$ G=<g1>
bash -c '. "$0"/lib.sh; date -u +%FT%TZ; MN create -f "$WORK/m/herdr-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-herdr --timeout=300s; echo "rc=$?"; date -u +%FT%TZ; $K -n "$NS" get pod exp006-herdr -o jsonpath="{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].imageID}{\"\n\"}" | tee "$WORK/ev/k02-herdr-pod.txt"' "$G" 2>&1
```

Output:

```
2026-11-22T17:59:26Z
pod/exp006-herdr created
pod/exp006-herdr condition met
rc=0
2026-11-22T17:59:29Z
<herdr-pod-uid-1> node-H 0 ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277
```

### K02: open Herdr pane and run SSH attach

```
$ G=<g1>
bash -c '. "$0"/lib.sh; attach k02; echo "rc=$? P=$(cat $WORK/pane)"' "$G" 2>&1
```

Output:

```
rc=0 P=w1:p1
```

### K02: send mark k02 through Herdr pane, wait for ACK

```
$ G=<g1>
bash -c '. "$0"/lib.sh; mark k02; echo "rc=$?"; tail -8 "$WORK/ev/pane-k02.txt" 2>/dev/null' "$G" 2>&1
```

Output:

```
{"id":"cli:pane:wait-output","result":{"matched_line":"ACK k02 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=41","pane_id":"w1:p1","read":{"format":"text","pane_id":"w1:p1","revision":0,"source":"visible","tab_id":"w1:t1","text":"tick n=7\ntick n=8\ntick n=9\ntick n=10\ntick n=11\ntick n=12\ntick n=13\ntick n=14\ntick n=15\ntick n=16\ntick n=17\ntick n=18\ntick n=19\ntick n=20\ntick n=21\ntick n=22\ntick n=23\ntick n=24\ntick n=25\ntick n=26\ntick n=27\ntick n=28\ntick n=29\ntick n=30\ntick n=31\ntick n=32\ntick n=33\ntick n=34\ntick n=35\ntick n=36\ntick n=37\ntick n=38\ntick n=39\ntick n=40\nmark k02tick n=41\n\nACK k02 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=41\ntick n=42\n\n[agent] 0:bash*                                                                           \"exp006-exec\" 17:59 22-Nov-26\n","truncated":false,"workspace_id":"w1"},"revision":0,"type":"output_matched"}}
rc=0
tick n=39
tick n=40
mark k02tick n=41

ACK k02 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=41
tick n=42

[agent] 0:bash*                                                                           "exp006-exec" 17:59 22-Nov-26
```

### K02: confirm ACK in counter log and one tmux client

```
$ G=<g1>
bash -c '. "$0"/lib.sh; X grep " ACK k02 " /tmp/agent/out/counter.log; echo "rc=$?"; X tmux -S /tmp/agent/tmux.sock list-clients; echo "rc=$?"' "$G" 2>&1
```

Output:

```
1795370384.400702 2026-11-22T17:59:44 ACK k02 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=41
rc=0
/dev/pts/1: agent [119x40 xterm-256color] (attached,focused)
rc=0
```

### K03: record counter position and close the Herdr pane

```
$ G=<g1>
bash -c '. "$0"/lib.sh; n0=$(X tail -1 /tmp/agent/out/counter.log) && echo "$n0" | tee "$WORK/ev/k03-n0.txt"; echo "rc=$?"; H pane close "$P"; echo "close rc=$?"; date -u +%FT%TZ' "$G" 2>&1
```

Output:

```
1795370397.414092 2026-11-22T17:59:57 COUNT n=55
rc=0
{"id":"cli:pane:close","result":{"type":"ok"}}
close rc=0
2026-11-22T17:59:58Z
```

### K03: wait 10 s, then check clients, identity, counter

```
$ G=<g1>
for i in $(seq 1 10); do read -t 1 -r _ </dev/zero 2>/dev/null || true; done 2>/dev/null; timeout 11 tail -f /dev/null; 
bash -c '. "$0"/lib.sh; date -u +%FT%TZ; X tmux -S /tmp/agent/tmux.sock list-clients; echo "clients rc=$? (empty output = 0 clients)"; X cat /tmp/agent/out/identity; X tail -3 /tmp/agent/out/counter.log' "$G" 2>&1 | tee -a /dev/null
```

Output:

```
Command did not complete within its 60s timeout and was moved to the background (ID: bztiw01y4). Output is being written to: <tasks>/bztiw01y4.output. You will be notified when it completes. It is running now: do not start a second copy while it runs. If it is no longer needed, stop it with TaskStop. No output had been read from it when it was moved. A program that buffers its output, or a pipe into one such as tail, can keep the output file empty until the command finishes. To check interim output, use Read on that file path.
```

[Note added during sanitization: the agent then stopped this background task with the harness's task-stop control (`TaskStop`, task `bztiw01y4`), which is not a shell command. The task's output file contained only `[killed]` and no line from the `bash -c` part.]

### K03: check zero clients, identity, counter while detached

```
$ G=<g1>
bash -c '. "$0"/lib.sh; date -u +%FT%TZ; X tmux -S /tmp/agent/tmux.sock list-clients; echo "clients rc=$? (no lines above = 0 clients)"; X cat /tmp/agent/out/identity; X tail -3 /tmp/agent/out/counter.log' "$G" 2>&1 | tee "$G/work/ev/k03-detached.txt"
```

Output:

```
2026-11-22T18:01:16Z
clients rc=0 (no lines above = 0 clients)
pid=17
start=29585526
nonce=4d941f1d19cdad5d
1795370474.484948 2026-11-22T18:01:14 COUNT n=132
1795370475.486110 2026-11-22T18:01:15 COUNT n=133
1795370476.486816 2026-11-22T18:01:16 COUNT n=134
```

### K03: reattach from a new pane and send mark k03

```
$ G=<g1>
bash -c '. "$0"/lib.sh; attach k03; echo "attach rc=$? P=$(cat $WORK/pane)"' "$G" 2>&1
bash -c '. "$0"/lib.sh; mark k03 >/dev/null; echo "mark rc=$?"; grep "ACK k03" "$WORK/ev/pane-k03.txt"; X grep " ACK k03 " /tmp/agent/out/counter.log; X tmux -S /tmp/agent/tmux.sock list-clients' "$G" 2>&1
```

Output:

```
attach rc=0 P=w2:p1
mark rc=0
ACK k03 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=146
1795370488.896676 2026-11-22T18:01:28 ACK k03 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=146
/dev/pts/1: agent [119x40 xterm-256color] (attached,focused)
```

### K04: delete the scratch Herdr pod only

```
$ G=<g1>
bash -c '. "$0"/lib.sh; date -u +%FT%TZ; MN delete pod exp006-herdr --wait=true; echo "rc=$?"; date -u +%FT%TZ' "$G" 2>&1 | tee "$G/work/ev/k04-delete.txt"
```

Output:

```
2026-11-22T18:01:36Z
pod "exp006-herdr" deleted from herdrnetes-exp006-s2a namespace
rc=0
2026-11-22T18:01:38Z
```

### K04: confirm Herdr pod NotFound and counter advancing

```
$ G=<g1>
bash -c '. "$0"/lib.sh; $K -n "$NS" get pod exp006-herdr; echo "rc=$?"; X tail -2 /tmp/agent/out/counter.log; X tmux -S /tmp/agent/tmux.sock list-clients; echo "clients-listed"' "$G" 2>&1 | tee "$G/work/ev/k04-absent-1.txt"
```

Output:

```
Error from server (NotFound): pods "exp006-herdr" not found
rc=1
1795370502.911476 2026-11-22T18:01:42 COUNT n=161
1795370503.912489 2026-11-22T18:01:43 COUNT n=162
clients-listed
```

### K04: second counter sample while Herdr is absent

```
$ G=<g1>
bash -c '. "$0"/lib.sh; $K -n "$NS" get pod exp006-herdr 2>&1; X tail -2 /tmp/agent/out/counter.log; X cat /tmp/agent/out/identity' "$G" 2>&1 | tee "$G/work/ev/k04-absent-2.txt"
```

Output:

```
Error from server (NotFound): pods "exp006-herdr" not found
1795370507.915996 2026-11-22T18:01:47 COUNT n=166
1795370508.917172 2026-11-22T18:01:48 COUNT n=167
pid=17
start=29585526
nonce=4d941f1d19cdad5d
```

### K04: recreate scratch Herdr pod and wait for Ready

```
$ G=<g1>
bash -c '. "$0"/lib.sh; date -u +%FT%TZ; MN create -f "$WORK/m/herdr-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-herdr --timeout=300s; echo "rc=$?"; date -u +%FT%TZ; $K -n "$NS" get pod exp006-herdr -o jsonpath="{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].restartCount}{\"\n\"}"' "$G" 2>&1 | tee "$G/work/ev/k04-recreate.txt"
```

Output:

```
2026-11-22T18:01:55Z
pod/exp006-herdr created
pod/exp006-herdr condition met
rc=0
2026-11-22T18:01:57Z
<herdr-pod-uid-2> node-H 0
```

### K04: list workspaces in new Herdr pod (expect none)

```
$ G=<g1>
bash -c '. "$0"/lib.sh; H workspace list; echo "rc=$?"' "$G" 2>&1 | tee "$G/work/ev/k04-new-herdr-workspaces.txt"
```

Output:

```
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[]}}
rc=0
```

### K04: attach from a pane in the new Herdr pod

```
$ G=<g1>
bash -c '. "$0"/lib.sh; attach k04; echo "attach rc=$? P=$(cat $WORK/pane)"' "$G" 2>&1
```

Output:

```
attach rc=0 P=w1:p1
```

### K04: send mark k04 and confirm ACK

```
$ G=<g1>
bash -c '. "$0"/lib.sh; mark k04 >/dev/null; echo "mark rc=$?"; grep "ACK k04" "$WORK/ev/pane-k04.txt"; X grep " ACK k04 " /tmp/agent/out/counter.log; X tmux -S /tmp/agent/tmux.sock list-clients' "$G" 2>&1
```

Output:

```
mark rc=0
ACK k04 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=197
1795370539.708054 2026-11-22T18:02:19 ACK k04 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=197
/dev/pts/1: agent [119x40 xterm-256color] (attached,focused)
```

### K05: ACK identity, counter gaps, exec pod restarts

```
$ G=<g1>
bash -c '. "$0"/lib.sh; X cat /tmp/agent/out/counter.log >"$WORK/ev/counter.log"; echo "copy rc=$?"; wc -l <"$WORK/ev/counter.log"
grep -E " ACK k0[234] " "$WORK/ev/counter.log"
grep -E " ACK k0[234] " "$WORK/ev/counter.log" | grep -oE "pid=[0-9]+ start=[0-9]+ nonce=[0-9a-f]+" | sort -u
grep COUNT "$WORK/ev/counter.log" | sed "s/.*n=//" | awk "NR>1&&\$1!=p+1{g++}{p=\$1}END{print \"gaps=\"g+0,\"last=\"p}"
grep COUNT "$WORK/ev/counter.log" | head -1
$K -n "$NS" get pod exp006-exec -o jsonpath="{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].state.running.startedAt}{\"\n\"}"
cat "$WORK/ev/k01-pod.txt" | cut -d" " -f1-4
X bash -c '"'"'p=$(sed -n "s/^pid=//p" /tmp/agent/out/identity); sed "s/.*) //" /proc/$p/stat | awk "{print \$20}"'"'"'' "$G" 2>&1 | tee "$G/work/ev/k05.txt"
```

Output:

```
copy rc=0
211
1795370384.400702 2026-11-22T17:59:44 ACK k02 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=41
1795370488.896676 2026-11-22T18:01:28 ACK k03 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=146
1795370539.708054 2026-11-22T18:02:19 ACK k04 pid=17 start=29585526 nonce=4d941f1d19cdad5d n=197
pid=17 start=29585526 nonce=4d941f1d19cdad5d
gaps=0 last=208
1795370344.075359 2026-11-22T17:59:04 COUNT n=1
<exec-pod-uid> node-E 0 2026-11-22T17:59:03Z
<exec-pod-uid> node-E 0 2026-11-22T17:59:03Z
29585526
```

### K06: guarded deletion of the scratch namespace

```
$ G=<g1>
bash -c '. "$0"/lib.sh; date -u +%FT%TZ; ctx_ok && run_ok && ns_ok && $K delete ns "$NS" --wait=true --timeout=300s; echo "rc=$?"; date -u +%FT%TZ' "$G" 2>&1 | tee "$G/work/ev/k06-delete.txt"
```

Output:

```
2026-11-22T18:02:37Z
namespace "herdrnetes-exp006-s2a" deleted
rc=0
2026-11-22T18:02:49Z
```

### K06: verify NotFound, no PV refs, baseline unchanged

```
$ G=<g1>
bash -c '. "$0"/lib.sh; $K get ns "$NS"; echo "rc=$?"
$K get pv -o json | jq -e --arg ns "$NS" "[.items[]|select(.spec.claimRef.namespace==\$ns)]|length==0"; echo "pv rc=$?"
$K get ns -l herdrnetes.io/experiment=exp-006; echo "labelled rc=$?"
ctx_ok && live_ok && baseline >"$WORK/ev/k06.txt"; echo "baseline rc=$?"; diff "$WORK/ev/k00.txt" "$WORK/ev/k06.txt"; echo "diff rc=$?"; wc -l "$WORK/ev/k00.txt" "$WORK/ev/k06.txt"' "$G" 2>&1 | tee "$G/work/ev/k06-verify.txt"
```

Output:

```
Error from server (NotFound): namespaces "herdrnetes-exp006-s2a" not found
rc=1
true
pv rc=0
No resources found
labelled rc=0
baseline rc=0
diff rc=0
 1100 <g1>/work/ev/k00.txt
 1100 <g1>/work/ev/k06.txt
 2200 total
```

### K06: shred local throwaway keys; scan evidence for key text

```
$ W=<g1>/work; shred -u "$W"/keys/authorized_keys "$W"/keys/client "$W"/keys/client.pub "$W"/keys/host "$W"/keys/host.pub "$W"/keys/known_hosts; echo "shred rc=$?"; rmdir "$W/keys"; echo "rmdir rc=$?"; ls "$W/keys" 2>&1; ls "$W/ev"; grep -rlE 'PRIVATE KEY|ssh-ed25519 AAAA' "$W" 2>/dev/null | head; echo "keyscan done"
```

Output:

```
shred rc=0
rmdir rc=0
ls: cannot access '<g1>/work/keys': No such file or directory
counter.log
k00.txt
k01-identity.txt
k01-pod.txt
k01-ps.txt
k02-herdr-pod.txt
k03-detached.txt
k03-n0.txt
k04-absent-1.txt
k04-absent-2.txt
k04-delete.txt
k04-new-herdr-workspaces.txt
k04-recreate.txt
k05.txt
k06-delete.txt
k06.txt
k06-verify.txt
pane-k02.txt
pane-k03.txt
pane-k04.txt
keyscan done
```

