# EXP-006 stage 2: G1 resource inventory and runbook (PROPOSED)

Issue [#7](https://github.com/jlaska/herdrnetes/issues/7) · REQ-009 · ADR-0001 unchanged · **Executed once as G1 run `s2a` (2026-11-22): K00–K06 PASS, cleanup CLEAN; see [`evidence/s2a/`](evidence/s2a/README.md).** Any further run needs a new owner approval. The execution image is built and published (below).
Reviewed commit: the PR #37 head SHA named in the G1 approval (a file cannot name its own commit).

Question: does the stage 1 result (tmux owns the PTY; panes are disposable `tmux attach` clients) hold across two pods,
with a scratch Herdr pod reaching an execution pod over SSH? Run only after owner approval; owner-operated, or agent-operated only after explicit G1 approval.

## Resource inventory

Namespace `herdrnetes-exp006-${RUN_ID}` (labels `herdrnetes.io/experiment=exp-006`, `herdrnetes.io/run-id`, `herdrnetes.io/disposable=true`; PSA restricted enforce/audit/warn).

| Kind | Name | Image / content |
|---|---|---|
| Namespace | `herdrnetes-exp006-${RUN_ID}` | cluster-scoped, the only such object |
| NetworkPolicy x3 | `default-deny-all`, `herdr-egress` (to exec TCP 2222, kube-dns 53), `exec-ingress` (from herdr TCP 2222) | |
| Service | `exp006-exec` (ClusterIP, 2222) | |
| Secret | `exp006-exec-ssh` (`ssh_host_ed25519_key`, `authorized_keys`) | created from a temp dir, never in the repo |
| Secret | `exp006-client-ssh` (`id_ed25519`, `known_hosts`) | created from a temp dir, never in the repo |
| Pod | `exp006-exec` | `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16` (pinned in `manifests/exec-pod.yaml`) |
| Pod | `exp006-herdr` | `ghcr.io/jlaska/herdrnetes-herdr:exp002-h095-c311@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277` (EXP-002, unchanged) |

**No PVCs, no ServiceAccount tokens, no RBAC, no cluster-scoped objects except the Namespace.** 9 objects in total. Manifests: [`manifests/`](manifests/).

## Image

- Herdr pod: EXP-002 digest above, reused. It already has `openssh-client` and no tmux. Its entrypoint needs a writable `$HOME` and `XDG_*`; these are emptyDirs. Its config is baked in, so no ConfigMap.
- Exec pod: built from [`../exec-image/`](../exec-image/) (Debian trixie-slim, base digest as EXP-002). Binary pins verified against the live trixie index on 2026-11-22: `tmux 3.5a-3`, `openssh-server 1:10.0p1-7+deb13u4`, `tini 0.19.0-3+b8`, `procps 2:4.0.4-9` (sources in the Containerfile header; a stale pin fails the build). Built and published:
  - Image: `ghcr.io/jlaska/herdrnetes-exec@sha256:9c8fc9d00aada8c910e93325bd1c465a6eea9af28a6de77eba4fa066e91d7a16` (tag `exp006-s1` resolves to the same digest; single linux/amd64 Docker v2 manifest; config `User` `1000:1000`, entrypoint `tini -- exp006-entrypoint`).
  - Build source: `35369c2db4daa6d241aa6b08e9ddf3e751143490` (the checkout logged `HEAD is now at 35369c2`; the verify step passed).
  - CI: [run 45033107115](https://github.com/jlaska/herdrnetes/actions/runs/45033107115), `workflow_dispatch` on `main` at workflow commit `fea0a7a1079bddd35ed7f1ada24d340a50e14b39`, conclusion **success** (2026-11-22T14:29:44Z). The installed `.github/workflows/exp006-exec-image.yml` is byte-identical to the inactive copy in `exec-image/` (`contents: read`, `packages: write`, `workflow_dispatch` only).
  - `smoke.sh` in that run, all PASS: A, PTY plus forced tmux attach, ACK from the original process (ssh rc 0). B, remote `id` not executed, no `uid=`, 2 accepted logins (ssh rc 1). C, unauthorized key rejected (ssh rc 255, no ACK). D, identity unchanged (`start` equals live `/proc` start), counter advancing (n 9→11).
  - Visibility: the owner set the package PUBLIC. An anonymous registry token resolved the digest (HTTP 200, `Docker-Content-Digest` equal to the pin), so no imagePullSecret is needed.
- Build path (no step builds "from main" or from a moving branch):
  1. The owner reviews `exec-image/`, then installs the corrected workflow on `main` as `.github/workflows/exp006-exec-image.yml` in an owner-operated commit (the agent token has no `workflow` scope) and dispatches it (`workflow_dispatch` only, GITHUB_TOKEN, no PAT).
  2. The workflow (from `main`) checks out the **pinned reviewed source commit** (`SOURCE_SHA` = `35369c2db4daa6d241aa6b08e9ddf3e751143490`, which holds `exec-image/` and `smoke.sh`), verifies HEAD equals it, and builds.
  3. `smoke.sh` runs before any GHCR login. A failure stops the job and nothing is pushed.
  4. On success it pushes and prints `ghcr.io/jlaska/herdrnetes-exec@sha256:...` and the source SHA in the job summary.
  5. The owner sets the GHCR package to PUBLIC by hand (the image holds no secret), so no imagePullSecret is needed.
  6. The digest and source SHA are recorded in a reviewed commit to `manifests/exec-pod.yaml` and this runbook.

## Credentials plan (per run; none are the owner's identity; nothing is printed)

1. In a mode-0700 temp dir, create two throwaway ed25519 keypairs (exec host key, client key) with `env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -f ...`. No agent, no passphrase, no PAT.
2. `known_hosts` holds one line with the alias `exp006-exec` and the host public key.
3. `authorized_keys` holds `restrict,pty,command="tmux -S /tmp/agent/tmux.sock -f /dev/null attach -t agent" <client public key>`.
4. Put them in Secrets `exp006-exec-ssh` and `exp006-client-ssh` with `--from-file` (K01). Shred the temp dir at K06.

## Resource budget

Requests per pod: cpu 50m, memory 64Mi, ephemeral 64Mi. Limits: exec 500m / 256Mi / 256Mi; Herdr 500m / 512Mi / 512Mi.
Totals: requests 100m / 128Mi / 128Mi; limits 1000m / 768Mi / 768Mi. emptyDir sizeLimits: exec 128Mi; Herdr 128Mi + 32Mi + 128Mi. Placement: required anti-affinity keeps both pods off the live Herdr node and off each other.

## Procedure

Setup (run in **bash**, not zsh: `$K` relies on word splitting and `run_ok` uses `[[ =~ ]]`; `CTX`, the `EXPECT_*` identity values and `ARGO_APP` are supplied by the owner at run time and never committed; `jq` runs locally; run from `experiments/exp-006/k8s`):
```
export RUN_ID=s2a NS=herdrnetes-exp006-s2a CTX='<context>'   # RUN_ID: [a-z0-9-], NS must be herdrnetes-exp006-$RUN_ID
export EXPECT_SERVER='<api-url>' EXPECT_KUBE_SYSTEM_UID='<uid>' EXPECT_HERDR_UID='<uid>' ARGO_APP='<cluster>-herdrnetes-exp'   # owner-supplied, never committed
K="kubectl --context $CTX"; umask 077; WORK=$(mktemp -d) && mkdir "$WORK"/{m,keys,ev}
for f in manifests/*.yaml; do sed "s/\${RUN_ID}/$RUN_ID/g" "$f" >"$WORK/m/$(basename "$f")"; done   # the exec image digest is already pinned
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

**K00 read-only preflight.** `ctx_ok && live_ok && run_ok && baseline >"$WORK/ev/k00.txt"` (no output file means stop); `$K get ns "$NS"` must print `Error from server (NotFound)`; `$K get ns -l herdrnetes.io/experiment=exp-006` lists none. Expected: all guards pass (server URL, `kube-system` UID and `herdr-0` UID match the owner-supplied values; rendered manifests name only `$NS`), all nodes Ready, at least 3 schedulable nodes (two besides the live Herdr node), `herdr-0` Running with its UID, node, restart counts and image IDs recorded, Argo CD app Synced/Healthy.

**K01 namespace, network, secrets, exec pod.**
```
M create -f "$WORK/m/namespace.yaml" && ns_ok
MN create -f "$WORK/m/networkpolicy.yaml" -f "$WORK/m/service.yaml"
env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -C "exp006-host-$RUN_ID" -f "$WORK/keys/host"
env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -C "exp006-client-$RUN_ID" -f "$WORK/keys/client"
printf 'restrict,pty,command="tmux -S /tmp/agent/tmux.sock -f /dev/null attach -t agent" %s\n' "$(cut -d' ' -f1,2 "$WORK/keys/client.pub")" >"$WORK/keys/authorized_keys"
printf 'exp006-exec %s\n' "$(cut -d' ' -f1,2 "$WORK/keys/host.pub")" >"$WORK/keys/known_hosts"
MN create secret generic exp006-exec-ssh --from-file=ssh_host_ed25519_key="$WORK/keys/host" --from-file=authorized_keys="$WORK/keys/authorized_keys"
MN create secret generic exp006-client-ssh --from-file=id_ed25519="$WORK/keys/client" --from-file=known_hosts="$WORK/keys/known_hosts"
MN label secret exp006-exec-ssh exp006-client-ssh herdrnetes.io/experiment=exp-006 herdrnetes.io/run-id="$RUN_ID"
MN create -f "$WORK/m/exec-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-exec --timeout=300s
$K -n "$NS" get pod exp006-exec -o jsonpath='{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].restartCount}{"\n"}'
X cat /tmp/agent/out/identity
X bash -c 'p=$(sed -n "s/^pid=//p" /tmp/agent/out/identity); sed "s/.*) //" /proc/$p/stat | awk "{print \$20}"; ps -eo pid,ppid,cmd'
```
Expected: Ready within 5 min on a node other than the live one; `identity` has `pid`, `start`, `nonce`; the `/proc` field 22 value equals `start`; the tmux server has ppid 1 (tini). Save outputs to `$WORK/ev`.

**K02 Herdr pod and first attach.**
```
MN create -f "$WORK/m/herdr-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-herdr --timeout=300s
ATTACH='ssh -i /run/exp006/client/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/exp006/client/known_hosts -o HostKeyAlias=exp006-exec -o UpdateHostKeys=no -p 2222 -t herdr@exp006-exec'
newpane() { H workspace create --cwd /tmp --label "$1" --no-focus | jq -r .result.root_pane.pane_id; }
attach() { P=$(newpane "$1") && [ -n "$P" ] && [ "$P" != null ] && H pane run "$P" "$ATTACH" && sleep 5; }
mark() { H pane send-text "$P" "mark $1" && H pane send-keys "$P" Enter && H pane wait-output "$P" --match "ACK $1 pid=" --source visible --timeout 15000 && H pane read "$P" --source visible --lines 40 >"$WORK/ev/pane-$1.txt"; }
attach k02 && mark k02; X grep ' ACK k02 ' /tmp/agent/out/counter.log; X tmux -S /tmp/agent/tmux.sock list-clients
```
Expected: the ACK line carries the K01 `pid`, `start` and `nonce`; one tmux client. Failure twice: stop.

**K03 pane close, continuity, reattach.** `n0=$(X tail -1 /tmp/agent/out/counter.log)`; `H pane close "$P"`; wait 10 s; `X tmux -S /tmp/agent/tmux.sock list-clients` (expect none); `X cat /tmp/agent/out/identity` and `X tail -3 /tmp/agent/out/counter.log` (same identity, `n` advanced past `n0`); then `attach k03 && mark k03`. Expected: same triple, `n` greater than at close.

**K04 Herdr pod replacement.** `MN delete pod exp006-herdr --wait=true`; `$K -n "$NS" get pod exp006-herdr` (NotFound); `X tail -2 /tmp/agent/out/counter.log` twice, a few seconds apart (still advancing); `MN create -f "$WORK/m/herdr-pod.yaml" && $K -n "$NS" wait --for=condition=Ready pod/exp006-herdr --timeout=300s`; `attach k04 && mark k04`. Expected: the new Herdr has no panes; the ACK shows the same triple. This is a pod replacement, not a Herdr upgrade.

**K05 identity and continuity.** `X cat /tmp/agent/out/counter.log >"$WORK/ev/counter.log"`; `grep -E ' ACK k0[234] ' "$WORK/ev/counter.log"` (three ACKs, one triple, rising `n`); `grep COUNT "$WORK/ev/counter.log" | sed 's/.*n=//' | awk 'NR>1&&$1!=p+1{g++}{p=$1}END{print "gaps="g+0,"last="p}'` (expect `gaps=0`); re-run the K01 pod command (UID, restartCount 0 and `startedAt` unchanged: `$K -n "$NS" get pod exp006-exec -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}'`).

**K06 label-guarded cleanup.** The guard and the delete are one `&&` line: if the cluster identity, the run-namespace name or its labels do not match, the delete is not executed. `live_ok` is deliberately not part of this guard, so that a change to the live system cannot block removal of the scratch namespace. Such a change still shows in the K00/K06 baseline diff and is reported.
```
ctx_ok && run_ok && ns_ok && $K delete ns "$NS" --wait=true --timeout=300s
$K get ns "$NS"                                       # must print Error from server (NotFound)
$K get pv -o json | jq -e --arg ns "$NS" '[.items[]|select(.spec.claimRef.namespace==$ns)]|length==0'
baseline >"$WORK/ev/k06.txt"; diff "$WORK/ev/k00.txt" "$WORK/ev/k06.txt"
shred -u "$WORK"/keys/* ; rmdir "$WORK/keys"; ls "$WORK/keys" 2>&1  # evidence stays in $WORK/ev
```
Report **CLEAN** only if the namespace is positively NotFound, no PV has a claimRef to it, and the baseline is identical (K00 vs K06). **RESIDUE** if the namespace or a PV remains or the baseline changed. **UNVERIFIED** for any check that failed for another reason than a clear NotFound (Forbidden, timeout, empty output). Shredding is best effort on a journaling filesystem; the keys are throwaway, and the Secrets die with the namespace.

## Read-only baseline observed during preparation (2026-11-22, G0)

This was captured with `kubectl get`/`version`/`auth can-i` only. K00 must re-capture it at G1, and any difference is a stop condition.

| Item | Observed |
|---|---|
| Server / nodes | v1.36.6; 3 nodes Ready (Talos 1.14.6, kernel 6.18.63, containerd 2.3.7) |
| Target namespace | `herdrnetes-exp006-g1rev` NotFound; no `herdrnetes-exp006*` namespaces; no objects labelled `herdrnetes.io/experiment=exp-006`; no PV claimRef into one |
| Live `herdrnetes-exp/herdr-0` | UID prefix `fe7cd780`, Running since 2026-11-19T07:45:51Z, restarts 0/0. `herdr` at `ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae…8e277`, `ovis` at `ghcr.io/jlaska/herdrnetes-ovis@sha256:8e31cc27…0db`. Labels include `app.kubernetes.io/name=herdr` (the anti-affinity selector) |
| Argo CD | `argo-system/<cluster>-herdrnetes-exp` Synced/Healthy |
| DNS | `kube-system` pods labelled `k8s-app=kube-dns` (matches `herdr-egress`) |
| `auth can-i` (owner admin context) | yes for namespaces, pods, secrets, services, networkpolicies and pods/exec |

## Owner-operated or approval-gated steps (in order)

1. **Image build. DONE** (owner-operated): workflow installed on `main`, dispatched, package set PUBLIC; digest and source recorded above and in `manifests/exec-pod.yaml`.
2. **G1.** Review this package at the PR #37 head, then approve K00–K06 owner-operated or explicitly agent-authorized.

## Stop conditions

Stop and report (do not continue) on: any command exiting non-zero or printing something other than its Expected result (except the K00/K06 NotFound checks, where NotFound is expected); any guard printing `FAILED` (`ctx_ok`, `live_ok`, `run_ok`, `ns_ok`; the write on that line has not run, and later lines must not be worked around by hand); any `create` failing with `AlreadyExists`; any K00 baseline change; a rendered manifest whose namespace is not the run namespace; a pod not Ready within 5 min; a pod scheduled onto the live Herdr node; PSA rejection; the K02 attach failing twice; any ssh prompt for a password or passphrase. If the K06 guard fails, the namespace is left in place and reported as **RESIDUE**; the owner deletes it only after re-establishing the cluster identity.

## Safety

No changes to `herdrnetes-exp`, Argo CD or Longhorn (only reads). No owner SSH or GPG agent use (`env -u SSH_AUTH_SOCK`, `IdentityAgent=none`). No PAT. No secrets, key text, node names or contexts in the repo or in committed evidence. Sanitize before committing.

## Untested risks

1. Non-root `sshd` under PSA restricted (no setuid, no chroot): `/run/sshd`, OpenSSH 10 `sshd-session` re-exec, the pre-auth sandbox under the default seccomp profile, and the `sshd` privsep user. `smoke.sh` passed in CI run 45033107115, but under docker, not Kubernetes. Its docker flags (uid 1000, read-only rootfs, no caps, no-new-privileges, tmpfs) only approximate PSA restricted; the cluster's runtime and seccomp profile can differ.
2. `StrictModes yes`: `authorized_keys` lives under the passwd home `/tmp/home` (0700), where sshd's parent-directory walk stops. `smoke.sh` passed this in CI (docker), including key-permission handling and the forced command (`restrict,pty,command=...`, and `id` must not run). Fallback if rejected: `EXP006_STRICT_MODES=no` (entrypoint env) in a reviewed manifest change.
3. The client key Secret file is root-owned and group-readable through fsGroup. `smoke.sh` mimics this with a 0644 file not owned by uid 1000 and the real client `ssh`; it cannot reproduce the kubelet's actual Secret mount. Fallback: `install -m 0600` it into an emptyDir and change `-i`.
4. `HostKeyAlias=exp006-exec` with `-p 2222` should match a plain `exp006-exec` known_hosts line; confirm with `ssh -v`.
5. The EXP-002 entrypoint has never run with emptyDir `$HOME`, `/run/herdr` and a read-only rootfs; hook reconciliation writes under `$HOME`.
6. NetworkPolicy: the kube-dns labels, a node-local DNS cache, and whether the CNI lets kubelet reach tcpSocket 2222 through ingress deny.
7. Resolved for this digest: the package is PUBLIC and the digest resolves anonymously. Debian pins only matter for a rebuild.
8. Only two non-live nodes can host the pods; tmux client count can lag after pod deletion (half-open TCP).
