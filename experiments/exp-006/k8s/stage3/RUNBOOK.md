# EXP-006 stage 3: Kubernetes real-agent G1 package and runbook (run `s3a`: INCONCLUSIVE, stopped at K02 on API credit; see [`../evidence/s3a/`](../evidence/s3a/README.md))

Issue [#7](https://github.com/jlaska/herdrnetes/issues/7) · REQ-009 · ADR-0001 unchanged · **Status: the execution image is built, smoke-tested and published (see Image). Nothing has been applied to a cluster or run, and no API key exists. G1 needs a new owner approval, and separately the owner-created key and $5 budget.**
Reviewed commit: the PR head SHA named in the G1 approval (a file cannot name its own commit). Stage 2 ([`../RUNBOOK.md`](../RUNBOOK.md), run `s2a`, CLEAN) is unchanged.

Question: does stage 2's result (tmux owns the PTY; panes are disposable `tmux attach` clients; two pods over SSH) hold for a **real Claude Code session**? Specifically: does the same agent process, with the same conversation, keep working while no Herdr pane is attached, and is it reachable and still remembers its first prompt after the Herdr pod is deleted and recreated? This is process, PTY and conversation continuity across Herdr churn. It is not a Herdr upgrade test and does not use `--resume` (FIND-007). The local bwrap harness ([`../../local/STAGE3.md`](../../local/STAGE3.md)) is historical preparation; this Kubernetes stage supersedes it.

## Resource inventory

Namespace `herdrnetes-exp006-${RUN_ID}` (`RUN_ID=s3a`; labels `herdrnetes.io/experiment=exp-006`, `herdrnetes.io/run-id`, `herdrnetes.io/disposable=true`; PSA restricted enforce/audit/warn). Manifests are in this directory.

| Kind | Name | Image / content |
|---|---|---|
| Namespace | `herdrnetes-exp006-${RUN_ID}` | cluster-scoped, the only such object |
| NetworkPolicy x3 | `default-deny-all`, `herdr-egress`, `exec-ingress` | unchanged from stage 2 |
| CiliumNetworkPolicy | `exec-egress-anthropic` | the exec pod's only egress: DNS for `api.anthropic.com` and `api.anthropic.com:443` (see Egress) |
| Service | `exp006-exec` (ClusterIP, 2222) | unchanged |
| Secret | `exp006-exec-ssh`, `exp006-client-ssh` | throwaway SSH keys, as stage 2 |
| Secret | `exp006-anthropic` (`api-key`) | the owner-created API key, from `$KEY_FILE`; mounted only in the exec pod |
| Pod | `exp006-exec` | `ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18` (tag `exp006-s3`; see Image) |
| Pod | `exp006-herdr` | EXP-002 Herdr image, unchanged (`herdr-pod.yaml` is byte-identical to stage 2); it gets **no** API key |

No PVCs, no ServiceAccount tokens, no RBAC, no cluster-scoped objects except the Namespace. 11 objects. Placement: the stage-2 required anti-affinity (off the live Herdr node, off each other). Budget: exec requests 100m / 256Mi / 256Mi ephemeral, limits 1000m / 1Gi / 1Gi; `/tmp` emptyDir 1Gi; Herdr pod as stage 2.

## Image

Built from [`../../exec-image-agent/`](../../exec-image-agent/) (context `experiments/exp-006`), on the published stage-2 exec image `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16`:
- Claude Code **2.1.323** linux-x64 from `https://downloads.claude.ai/claude-code-releases/2.1.323/linux-x64/claude`, `sha256 604d29a6869409106b6a1110bdadcc8b72e8654a5a865d23258f938a696e348e` (checked in the build).
- Debian trixie pins (live index, 2026-11-22): `python3-minimal 3.13.5-1`, `ca-certificates 20250419+deb13u1` (sources in the Containerfile header; a stale pin fails the build).
- `exp006-agent-entrypoint` (stage-2 sshd setup, then one Claude Code process in tmux) and `exp006-status` (read-only status). The pristine task repo is at `/usr/share/exp006/agent-task/repo` (root-owned).
- Build path (no step builds from main or a moving branch): the owner installs the inactive [`proposed-workflow-exp006-exec-agent-image.yml`](../../exec-image-agent/proposed-workflow-exp006-exec-agent-image.yml) as `.github/workflows/exp006-exec-agent-image.yml` in an owner-operated commit (the agent token has no `workflow` scope) with `SOURCE_SHA` pinned to the build-source commit `b6e3c92418a5cc03689cc475d9245a33b000a662`, then dispatches it. It builds the pinned source, runs `smoke-agent.sh` (no key, `--internal` network, no egress) before any GHCR login, then pushes tag `exp006-s3` of the existing public package.
- **Built and published (2026-11-22).** The owner installed the workflow on main in `6c7a88a` (byte-identical to the inactive copy) and dispatched [CI run 45083319378](https://github.com/jlaska/herdrnetes/actions/runs/45083319378) (`workflow_dispatch`, conclusion success). The run checked out and verified `b6e3c92418a5cc03689cc475d9245a33b000a662`, the build fetched Claude Code with the sha256 above (`2.1.323 (Claude Code)`), and `smoke-agent.sh: PASS` ran before the GHCR login:

  | Result | Test | Detail (from the run log) |
  |---|---|---|
  | PASS | A pty+forced tmux attach, detach, session still exists | ssh rc=0; session agent exists |
  | PASS | B remote command `id` not executed | no uid= in output; ssh rc=1 (nonzero is expected) |
  | PASS | C unauthorized key rejected | ssh rc=255; no new accepted login |
  | PASS | D agent alive and stable, no key, hashes ok, version | alive=yes x2, passing=0, jsonl_count=0, version=2.1.323 |
  | PASS | E claude <- tmux server <- tini (pid 1) | claude ppid = tmux server, its ppid = 1 (tini) |

  Pushed digest: **`ghcr.io/jlaska/herdrnetes-exec@sha256:b70f90a6fc045d45cdef4642e00fa188c167b95a976cfac2f7fea73de9ff4f18`** (docker v2 manifest, linux/amd64, 12 layers, config `sha256:c2e87ebb088042fb47ae8b40b82b895457ad327dc2a144545cdca20d11a182f5`, `User 1000:1000`, entrypoint `tini -- exp006-agent-entrypoint`). Anonymous pull checked on 2026-11-22 with no credentials: a GHCR anonymous pull token returned HTTP 200 for the manifest by digest and by tag `exp006-s3` (both `docker-content-digest` equal to the pinned digest), for the config blob (sha256 verified) and for a layer blob. `exec-pod.yaml` pins this digest; `run_ok` still stops on any remaining placeholder.

## Egress

The exec pod needs exactly one outside destination. The stage-2 `default-deny-all` still applies; Cilium adds this allow:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: exec-egress-anthropic
  namespace: herdrnetes-exp006-${RUN_ID}
  labels:
    herdrnetes.io/experiment: exp-006
    herdrnetes.io/run-id: "${RUN_ID}"
    herdrnetes.io/component: networkpolicy
    herdrnetes.io/disposable: "true"
spec:
  endpointSelector:
    matchLabels:
      herdrnetes.io/component: exec
      herdrnetes.io/run-id: "${RUN_ID}"
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchName: api.anthropic.com
    - toFQDNs:
        - matchName: api.anthropic.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

The exec pod sets `dnsConfig` `ndots: 1`. With the Kubernetes default of 5, a two-dot name such as `api.anthropic.com` is first tried with each search-list suffix; the DNS rule above rejects those (REFUSED is Cilium's default reject code), and both glibc and c-ares stop searching on such an answer, so the allowed name would never be queried. With `ndots: 1` the name is queried as-is first. Short in-cluster names are not used by the exec pod.

Limitations (this is not a sandbox):
- It is an L3/L4 plus FQDN allow to `api.anthropic.com:443`, not HTTP-level inspection. Anything served from that hostname is reachable, and the DNS proxy answers only for that name. Cilium resolves the name through its DNS proxy (`enable-l7-proxy=true` on this cluster, `toFQDNs` supported); the allow is learned from those answers.
- The agent can read its own API key (it needs it). Its exposure is bounded by the workspace spend limit and by revoking the key at K06. The exec pod also holds the throwaway SSH host key.
- The agent and `sshd` share uid 1000 in one pod and one pid namespace, so the agent could disrupt its own `sshd` or tmux. Accepted for a proof of concept; OpenShell is the production isolation (not in scope, no approved decision).
- Whether Claude Code (`--bare`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`) needs any other host is unverified; a blocked host would show as a stall or an error in the pane (stop condition), not as a silent success.

## Budget and credential prerequisites (owner, before G1)

1. An Anthropic Console **workspace `herdrnetes-exp006`** with a **$5 spend limit**, and **one** API key created in it for this run. The agent creates and uses no key.
2. The key is stored in `$KEY_FILE`: mode 0600, outside the repo, never printed, never in argv, never committed. It is delivered to the exec pod as Secret `exp006-anthropic` and read through `apiKeyHelper` (`cat /run/exp006/anthropic/api-key`); it is never an environment variable.
3. The model is Claude Haiku 5.5 (`claude-haiku-5-5`, effort `medium`), set by `EXP006_MODEL` in `exec-pod.yaml`; it overrides the entrypoint's built-in default (`claude-sonnet-5-5`, unchanged in the pinned image), and K01 checks `model=` in the identity file. The model id is re-verified with the key at K00b, before anything is created. Expected spend is well under $1; the $5 workspace limit stays as the safeguard.
4. After K05/K06 the owner **revokes the key** in the Console and removes `$KEY_FILE`. The run is not CLEAN until that is confirmed.
5. Run cap: 30 minutes of wall clock from the exec pod's creation; stop earlier if spend approaches the limit.

## Procedure

Setup (run in **bash**, not zsh: `$K` relies on word splitting and `run_ok` uses `[[ =~ ]]`; `CTX`, the `EXPECT_*` identity values and `ARGO_APP` are supplied by the owner at run time and never committed; `jq` runs locally; run from `experiments/exp-006/k8s/stage3`; `KEY_FILE` is the owner-supplied API key file, 0600, outside the repo):
```
export RUN_ID=s3a NS=herdrnetes-exp006-s3a CTX='<context>'   # RUN_ID: [a-z0-9-], NS must be herdrnetes-exp006-$RUN_ID
export EXPECT_SERVER='<api-url>' EXPECT_KUBE_SYSTEM_UID='<uid>' EXPECT_HERDR_UID='<uid>' ARGO_APP='<cluster>-herdrnetes-exp'   # owner-supplied, never committed
export KEY_FILE='<path>'   # owner-supplied API key file (mode 0600, outside the repo); never printed
K="kubectl --context $CTX"; umask 077; WORK=$(mktemp -d) && mkdir "$WORK"/{m,keys,ev}
for f in ./*.yaml; do sed "s/\${RUN_ID}/$RUN_ID/g" "$f" >"$WORK/m/$(basename "$f")"; done   # run_ok stops if any rendered manifest still holds a <PLACEHOLDER> or ${...}
baseline() { { ctx_ok && $K get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
  $K -n herdrnetes-exp get pod herdr-0 -o jsonpath='{.metadata.uid} {.spec.nodeName}{range .status.containerStatuses[*]} {.restartCount} {.imageID}{end}{"\n"}'
  $K -n herdrnetes-exp get sts,pvc,networkpolicy -o name; $K get pv -o json | jq -S '[.items[]|{n:.metadata.name,c:.spec.claimRef}]'
  $K -n argo-system get applications.argoproj.io "$ARGO_APP" -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'; } 2>&1; }
# Guards. Each returns non-zero and prints FAILED on any mismatch, missing value or API error.
ctx_ok() { local s u   # cluster identity, through the same $K the mutations use; never current-context
  [ -n "$CTX" ] && [ "$K" = "kubectl --context $CTX" ] && [ -n "$EXPECT_SERVER" ] && [ -n "$EXPECT_KUBE_SYSTEM_UID" ] &&
  s=$($K config view --minify -o jsonpath='{.clusters[0].cluster.server}') && u=$($K get ns kube-system -o jsonpath='{.metadata.uid}') &&
  [ "$s" = "$EXPECT_SERVER" ] && [ "$u" = "$EXPECT_KUBE_SYSTEM_UID" ] || { echo "ctx_ok FAILED: stop" >&2; return 1; }; }
live_ok() { local h a   # live Herdr pod unchanged and Argo CD Synced/Healthy
  [ -n "$EXPECT_HERDR_UID" ] && [ -n "$ARGO_APP" ] &&
  h=$($K -n herdrnetes-exp get pod herdr-0 -o jsonpath='{.metadata.uid}') &&
  a=$($K -n argo-system get applications.argoproj.io "$ARGO_APP" -o jsonpath='{.status.sync.status} {.status.health.status}') &&
  [ "$h" = "$EXPECT_HERDR_UID" ] && [ "$a" = "Synced Healthy" ] || { echo "live_ok FAILED: stop" >&2; return 1; }; }
run_ok() {   # run namespace name, and every rendered manifest names only it, with no unfilled placeholder
  [[ $RUN_ID =~ ^[a-z0-9-]+$ ]] && [ "$NS" = "herdrnetes-exp006-$RUN_ID" ] && [ -s "$WORK/m/namespace.yaml" ] &&
  ! grep -qE '<[A-Z]|\$\{' "$WORK"/m/*.yaml && [ "$(grep -hoE 'herdrnetes-exp006-[a-z0-9-]+' "$WORK"/m/*.yaml | sort -u)" = "$NS" ] ||
  { echo "run_ok FAILED: stop" >&2; return 1; }; }
ns_ok() {   # the run namespace exists with this run's labels
  [ "$($K get ns "$NS" -o jsonpath='{.metadata.labels.herdrnetes\.io/experiment}/{.metadata.labels.herdrnetes\.io/run-id}')" = "exp-006/$RUN_ID" ] ||
  { echo "ns_ok FAILED: stop" >&2; return 1; }; }
# Every Kubernetes write goes through M or MN, which re-check the guards first and never call kubectl if one fails.
M()  { ctx_ok && live_ok && run_ok && $K "$@"; }                     # cluster-scoped: only the K01 namespace create
MN() { ctx_ok && live_ok && run_ok && ns_ok && $K -n "$NS" "$@"; }   # every namespaced write
X() { ctx_ok && run_ok && ns_ok && $K -n "$NS" exec exp006-exec -- "$@"; }   # exec into this run's pods only
H() { ctx_ok && run_ok && ns_ok && $K -n "$NS" exec exp006-herdr -c herdr -- herdr "$@"; }
```
A failed guard blocks only the operation it wraps: each `M`/`MN` write and each `X`/`H` exec re-checks its guards and
does not call kubectl if one fails. The guards do not stop the shell. A command that fails for another reason, such as
a `create` returning `AlreadyExists`, a `wait` timing out or a local `ssh-keygen` error, does not stop the next line,
and a later line whose own guards pass will still run. Do not paste blocks unchecked. Run one command at a time, check
its exit status and output against the Expected text, and stop on any non-zero or unexpected result. Writes use `create`, never `apply`, so an existing object is an error, not a patch; and `-n "$NS"` makes
kubectl reject a manifest naming any other namespace. The only unwrapped write is the K06 namespace delete, which
sits on the same line as its guard. `baseline` output names nodes: it stays in `$WORK/ev` and is sanitized before
anything is committed.


**K00 read-only preflight.** `ctx_ok && live_ok && run_ok && baseline >"$WORK/ev/k00.txt"` (no output file means stop); `$K get ns "$NS"` must print `Error from server (NotFound)`; `$K get ns -l herdrnetes.io/experiment=exp-006` lists none; `$K get crd ciliumnetworkpolicies.cilium.io` exists. Expected: all guards pass (rendered manifests name only `$NS` and no placeholder remains, so the exec image digest is pinned), all nodes Ready, at least 3 schedulable nodes (two besides the live Herdr node), `herdr-0` Running, Argo CD app Synced/Healthy.

**K00b model check (credentialed approval only; no Kubernetes access).** `KEY_FILE` is owner-supplied, mode 0600, outside the repo, and never printed. The key goes through a process substitution, not argv:
```
curl -sS -o /dev/null -w '%{http_code}\n' -H @<(printf 'x-api-key: %s\nanthropic-version: 2023-06-01\n' "$(cat "$KEY_FILE")") https://api.anthropic.com/v1/models/claude-haiku-5-5
```
Expected `200`. Anything else: stop (nothing has been created).

**K01 namespace, network, secrets, exec pod.**
```
M create -f "$WORK/m/namespace.yaml" && ns_ok
MN create -f "$WORK/m/networkpolicy.yaml" -f "$WORK/m/service.yaml"
MN create -f "$WORK/m/cilium-exec-egress.yaml"
env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -C "exp006-host-$RUN_ID" -f "$WORK/keys/host"
env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -C "exp006-client-$RUN_ID" -f "$WORK/keys/client"
printf 'restrict,pty,command="tmux -S /tmp/agent/tmux.sock -f /dev/null attach -t agent" %s\n' "$(cut -d' ' -f1,2 "$WORK/keys/client.pub")" >"$WORK/keys/authorized_keys"
printf 'exp006-exec %s\n' "$(cut -d' ' -f1,2 "$WORK/keys/host.pub")" >"$WORK/keys/known_hosts"
MN create secret generic exp006-exec-ssh --from-file=ssh_host_ed25519_key="$WORK/keys/host" --from-file=authorized_keys="$WORK/keys/authorized_keys"
MN create secret generic exp006-client-ssh --from-file=id_ed25519="$WORK/keys/client" --from-file=known_hosts="$WORK/keys/known_hosts"
MN create secret generic exp006-anthropic --from-file=api-key="$KEY_FILE"
MN label secret exp006-exec-ssh exp006-client-ssh exp006-anthropic herdrnetes.io/experiment=exp-006 herdrnetes.io/run-id="$RUN_ID"
MN create -f "$WORK/m/exec-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-exec --timeout=300s
$K -n "$NS" get pod exp006-exec -o jsonpath='{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].imageID}{"\n"}'
X cat /tmp/agent/out/identity
X exp006-status
X python3 -I -c 'import socket;s=socket.create_connection(("api.anthropic.com",443),10);print("allowed ok",s.getpeername()[1]);s.close()'
X python3 -I -c 'import socket;socket.create_connection(("1.1.1.1",443),5)'
X python3 -I -c 'import socket;print(socket.getaddrinfo("example.com",443))'
```
Expected: Ready within 5 min on a node other than the live one; `imageID` equals the pinned digest; `identity` has `pid`, `start`, `sid`, `model=claude-haiku-5-5` (if it shows `claude-sonnet-5-5`, the env override did not apply: stop), `effort=medium`, `claude_version=2.1.323`, `key_present=yes`; status has `alive=yes`, `key_present=yes`, `passing=0`, `check_sha_ok=yes`, `readme_sha_ok=yes`, `resume_flag=no`; the allowed probe prints `allowed ok 443` (DNS through the proxy and a TCP connect only: no TLS, no HTTP request, no key, no spend); both other egress probes **fail** (a timeout or a resolution error), showing that only the allowed name is reachable. If the allowed probe fails, stop: the agent could not reach the API either. Save outputs to `$WORK/ev` (they name a node: sanitize first). If the pod does not become Ready, `X` and `$K logs` show the entrypoint log (never the key).

**K02 Herdr pod, first attach, first prompt.** The prompts are single-line ASCII; only `P1` carries the codeword.
```
P1_T='Session codeword is @CODE@. Do not write it to any file. Task: in kata.py implement f01, f02, f03, f04 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f04 passes, reply with exactly: DONE-A @CODE@'
PB='Task: in kata.py implement f05, f06, f07, f08 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f08 passes, reply with exactly: DONE-B'
PC='Task: in kata.py implement f09, f10, f11, f12 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f12 passes, reply with exactly: DONE-C'
Q_T='Reply with exactly one line: Q@K@ CODEWORD=<the session codeword from my first message> DONE=<number of functions passing per your last check>'
MN create -f "$WORK/m/herdr-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-herdr --timeout=300s
ATTACH='ssh -i /run/exp006/client/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/exp006/client/known_hosts -o HostKeyAlias=exp006-exec -o UpdateHostKeys=no -p 2222 -t herdr@exp006-exec'
newpane() { H workspace create --cwd /tmp --label "$1" --no-focus | jq -r .result.root_pane.pane_id; }
attach() { P=$(newpane "$1") && [ -n "$P" ] && [ "$P" != null ] && H pane run "$P" "$ATTACH" && sleep 5; }
attach k02 && H pane wait-output "$P" --match 'for shortcuts' --source visible --timeout 60000
H pane read "$P" --source visible --lines 45 >"$WORK/ev/pane-k02-ready.txt"; grep -iE 'log ?in|sign ?in|api key|trust|onboarding|theme|select|choose' "$WORK/ev/pane-k02-ready.txt"
```
The `grep` must print nothing and the pane must show the Claude Code prompt; a login, onboarding, trust or other dialog is a stop condition (never click through it). Then, still one command at a time:
```
CODE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')    # operator shell only; never written to a file or committed
T0=$(X date +%s)                                       # the pod's clock: progress and transcript timestamps are in pod time
H pane send-text "$P" "${P1_T//@CODE@/$CODE}" && H pane send-keys "$P" Enter
for i in $(seq 60); do s=$(X exp006-status --since "$T0" --brief); echo "$s"; grep -q 'progress_since=[1-9]' <<<"$s" && break; sleep 5; done
X exp006-status --since "$T0" >"$WORK/ev/status-k02.txt"; cat "$WORK/ev/status-k02.txt"
```
Expected: `progress_since>=1` within 300 s (a new `check.py` line in `progress.log`), `alive=yes`, same `pid`/`start` as K01, `sid_jsonl=yes`. Otherwise stop.

**K03 close the pane while the agent is working, wait, reattach, ask Q1.**
```
X exp006-status --said "DONE-A $CODE" --brief           # said=no is required: close while still working
N0=$(X exp006-status | sed -n 's/^passing=//p'); T_CLOSE=$(X date +%s); H pane close "$P"
for i in $(seq 30); do s=$(X exp006-status --brief); echo "$s"; grep -q 'tmux_clients=0' <<<"$s" && break; sleep 2; done
for i in $(seq 60); do s=$(X exp006-status --since "$T_CLOSE"); n=$(sed -n 's/^passing=//p' <<<"$s"); p=$(sed -n 's/^progress_since=//p' <<<"$s"); echo "passing=$n progress_since=$p"; [ "$p" -ge 1 ] && [ "$n" -gt "$N0" ] && break; sleep 5; done
X exp006-status --since "$T_CLOSE" >"$WORK/ev/status-k03-detached.txt"; cat "$WORK/ev/status-k03-detached.txt"
attach k03
H pane send-text "$P" "${Q_T//@K@/1}" && H pane send-keys "$P" Enter
for i in $(seq 60); do s=$(X exp006-status --said "Q1 CODEWORD=$CODE" --brief); echo "$s"; grep -q 'said=yes' <<<"$s" && break; sleep 5; done
H pane read "$P" --source visible --lines 45 >"$WORK/ev/pane-k03.txt"; X exp006-status >"$WORK/ev/status-k03-after.txt"; cat "$WORK/ev/status-k03-after.txt"
```
Expected: `tmux_clients=0` after the close; while detached, `progress_since>=1` and `passing` above `N0` (the agent worked with no client; wait at most 300 s, else stop: no progress within 300 s while detached); `said=yes` for `Q1 CODEWORD=<codeword>` (Q1 does not contain the codeword, so only a session that remembers P1 can answer); the same `pid`/`start`/`sid` as K01; `resume_flag=no`. `--said` prints no text, but the codeword is briefly visible in the `exec` argv inside the pod (the agent already holds it; accepted).

**K04 Herdr pod replacement while the agent works, then Q2.**
```
X exp006-status --said "DONE-B" --brief                  # if said=yes, send PC instead of PB below (the agent must still be working at the delete)
T_PB=$(X date +%s); H pane send-text "$P" "$PB" && H pane send-keys "$P" Enter
for i in $(seq 60); do s=$(X exp006-status --since "$T_PB" --brief); echo "$s"; grep -q 'progress_since=[1-9]' <<<"$s" && break; sleep 5; done
T_DEL=$(X date +%s); MN delete pod exp006-herdr --wait=true
$K -n "$NS" get pod exp006-herdr                         # NotFound
X exp006-status --since "$T_DEL" --brief; sleep 30; X exp006-status --since "$T_DEL" --brief
MN create -f "$WORK/m/herdr-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-herdr --timeout=300s
H workspace list                                         # the new Herdr has no workspaces
attach k04
H pane send-text "$P" "${Q_T//@K@/2}" && H pane send-keys "$P" Enter
for i in $(seq 60); do s=$(X exp006-status --said "Q2 CODEWORD=$CODE" --brief); echo "$s"; grep -q 'said=yes' <<<"$s" && break; sleep 5; done
H pane read "$P" --source visible --lines 45 >"$WORK/ev/pane-k04.txt"; X exp006-status >"$WORK/ev/status-k04-after.txt"; cat "$WORK/ev/status-k04-after.txt"
```
Expected: two status samples while the pod is absent with `progress_since` (since `T_DEL`) rising between them if the agent was still working, and `tmux_clients=0` (a half-open TCP connection can delay the count; re-sample once before judging); after the new pane attaches, `said=yes` for Q2, and the same `pid`/`start`/`sid`. This is a pod replacement, not a Herdr upgrade. If the agent had already finished its task when the pod was deleted, report the sample as inconclusive for "worked while Herdr was down", not as a failure.

**K05 identity and evidence.**
```
X exp006-status >"$WORK/ev/status-final.txt"; cat "$WORK/ev/status-final.txt"
X cat /tmp/agent/out/identity >"$WORK/ev/identity.txt"
X cat /tmp/work/repo/progress.log >"$WORK/ev/progress.log"
X python3 -I -c 'import glob,json
for f in glob.glob("/tmp/home/.claude/projects/**/*.jsonl",recursive=True):
 for l in open(f):
  try: d=json.loads(l)
  except ValueError: continue
  m=d.get("message") or {}
  c=m.get("content") if isinstance(m,dict) else None
  c=c if isinstance(c,list) else []
  t=" ".join(b.get("text","") for b in c if isinstance(b,dict) and b.get("type")=="text")[:200] if d.get("type")=="assistant" else ""
  print(d.get("timestamp"),d.get("type"),[b.get("name") for b in c if isinstance(b,dict) and b.get("type")=="tool_use"],t)' >"$WORK/ev/transcript-projection.txt"
$K -n "$NS" get pod exp006-exec -o jsonpath='{.metadata.uid} {.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].state.running.startedAt}{"\n"}'
```
Expected: the same `pid`, `start` and `sid` as K01 in every sample; `sid_jsonl=yes`, `jsonl_count=1`; `resume_flag=no`; `check_sha_ok=yes` and `readme_sha_ok=yes`; `progress_bad=0`; exec pod `restartCount` 0 and `startedAt` equal to K01's. **Not finishing all 12 functions is acceptable**: what is measured is continuity and work during detachment, not task completion. The transcript projection prints only timestamp, entry type, tool names and the first 200 characters of assistant text (it includes the codeword if the agent echoes it). Never copy the settings, the key, or full transcripts, and never sanitize-by-hand into the repo: review `$WORK/ev` before committing anything.


**K06 label-guarded cleanup and credential revocation.** The guard and the delete are one `&&` line: if the cluster identity, the run-namespace name or its labels do not match, the delete is not executed. `live_ok` is deliberately not part of this guard, so that a change to the live system cannot block removal of the scratch namespace. Such a change still shows in the K00/K06 baseline diff and is reported.
```
ctx_ok && run_ok && ns_ok && $K delete ns "$NS" --wait=true --timeout=300s
$K get ns "$NS"                                       # must print Error from server (NotFound)
$K get pv -o json | jq -e --arg ns "$NS" '[.items[]|select(.spec.claimRef.namespace==$ns)]|length==0'
baseline >"$WORK/ev/k06.txt"; diff "$WORK/ev/k00.txt" "$WORK/ev/k06.txt"
shred -u "$WORK"/keys/* ; rmdir "$WORK/keys"; ls "$WORK/keys" 2>&1  # evidence stays in $WORK/ev
```
Then the operator **revokes the API key in the Anthropic Console** and removes the local copy (`shred -u "$KEY_FILE"`). Report **CLEAN** only if the namespace is positively NotFound, no PV has a claimRef to it, the baseline is identical (K00 vs K06) and the operator confirms the key is revoked. **RESIDUE** if the namespace or a PV remains, the baseline changed, or the key is still active. **UNVERIFIED** for any check that failed for another reason than a clear NotFound (Forbidden, timeout, empty output). Shredding is best effort on a journaling filesystem; the SSH keys are throwaway and all three Secrets die with the namespace.

## Stop conditions

Stop and report (do not continue) on: any command exiting non-zero or printing something other than its Expected result (except the K00/K06 NotFound checks); any guard printing `FAILED` (the write on that line has not run, and later lines must not be worked around by hand); any `create` failing with `AlreadyExists`; any K00 baseline change; a rendered manifest whose namespace is not the run namespace or that still holds a placeholder; a pod not Ready within 5 min; a pod scheduled onto the live Herdr node; PSA rejection; the K02 attach failing twice; any ssh prompt for a password or passphrase. Stage 3 adds:
- the Claude Code TUI shows a login, onboarding, trust or any other dialog;
- `exp006-status` shows `alive=no`, or `pid`/`start` differ from K01;
- `resume_flag=yes`;
- the exec pod restarts, or any hash is not `yes`;
- no progress within 300 s while detached;
- the run exceeds 30 minutes, or spend approaches the $5 limit.
On a stop, run K06 (the namespace delete ends the agent) and revoke the key.

## Safety

No changes to `herdrnetes-exp`, Argo CD or Longhorn (only reads). No owner SSH or GPG agent use (`env -u SSH_AUTH_SOCK`, `IdentityAgent=none`). No PAT. The API key never appears in argv, an environment variable, a log, the repo or evidence. No secrets, key text, node names or contexts in the repo or in committed evidence. Sanitize before committing.

## Unverified assumptions (G0 validated statically only)

1. Under `--bare` with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, Claude Code contacts no host other than `api.anthropic.com`. If it does, the policy blocks it and the run stalls (stop condition).
2. The pre-seeded `.claude.json` keys (`hasCompletedOnboarding`, `hasTrustDialogAccepted`) suppress all first-run dialogs; the permission rule syntax (`./` is the project directory, `//` an absolute path) and `apiKeyHelper` under `--bare` work as in the local harness, which never ran either.
3. ~~The Claude TUI stays alive without a key.~~ Shown in CI run 45083319378 (smoke D: `alive=yes` twice, flags `--bare --settings --strict-mcp-config --tools --model --effort --session-id` accepted). With a key it is still untested.
4. `python3-minimal` suffices: `exp006-status` ran in smoke D (`json`, `re`, `subprocess`, `hashlib`, `argparse`). `passing=0` there is the expected value for the pristine task but would also be printed if `check.py` failed to run, so `check.py` itself is first shown at K02 (`progress_since>=1`). `socket` is first used by the K01 probes.
5. A Secret file with a trailing newline is accepted by `apiKeyHelper`; the model id `claude-haiku-5-5` is valid for the key (K00b), and Claude Code 2.1.323 accepts it with `--effort medium`.
6. Cilium rejects disallowed names with REFUSED (default) or NXDOMAIN; `ndots: 1` works for either. If the API name returns AAAA records, Claude Code falls back to IPv4 on this IPv4-only cluster (the K01 probe uses Python, not Claude Code).
7. Cilium merges the CiliumNetworkPolicy with the stage-2 NetworkPolicies additively, its DNS proxy handles the `matchName` rule, and the policy does not break the kubelet's `tcpSocket` readiness probe.
8. The Herdr pod can attach to a tmux session whose client is a full-screen TUI, and `herdr pane wait-output --match` matches the literal text `for shortcuts`.
9. The Debian pins are those of the live index on 2026-11-22; any later point release fails the build until re-reviewed. `python3.13-minimal`, `libpython3.13-minimal` and `openssl` float within the suite.
