# EXP-006 stage 2: G1 resource inventory and runbook (PROPOSED)

Issue [#7](https://github.com/jlaska/herdrnetes/issues/7) · REQ-009 · ADR-0001 unchanged · **G1 is not authorized.** Nothing here has been applied, built or run.
Commit SHA: <filled at G1>

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
| Pod | `exp006-exec` | `ghcr.io/jlaska/herdrnetes-exec@sha256:<pending the owner-dispatched build>` |
| Pod | `exp006-herdr` | `ghcr.io/jlaska/herdrnetes-herdr:exp002-h095-c311@sha256:c5a235ae20ddebd25debeae4cc844a98d854cae5f7d130693958955b37e8d277` (EXP-002, unchanged) |

**No PVCs, no ServiceAccount tokens, no RBAC, no cluster-scoped objects except the Namespace.** 9 objects in total. Manifests: [`manifests/`](manifests/).

## Image

- Herdr pod: EXP-002 digest above, reused. It already has `openssh-client` and no tmux. Its entrypoint needs a writable `$HOME` and `XDG_*`; these are emptyDirs. Its config is baked in, so no ConfigMap.
- Exec pod: built from [`../exec-image/`](../exec-image/) (Debian trixie-slim, base digest as EXP-002; `tmux 3.5a-3`, `openssh-server 1:10.0p1-7+deb13u4`, `tini 0.19.0-3`, `procps 2:4.0.4-9`). Digest: **pending the owner-dispatched build**.
- Prerequisite: owner reviews the inactive copy [`exec-image/proposed-workflow-exp006-exec-image.yml`](../exec-image/proposed-workflow-exp006-exec-image.yml), moves it to `.github/workflows/exp006-exec-image.yml` on the default branch in an owner-operated commit (the agent token has no `workflow` scope; GitHub rejected the agent push), keeping it `workflow_dispatch` only, GITHUB_TOKEN, no PAT) and dispatches it. The digest from the job summary is then committed into `manifests/exec-pod.yaml` in a reviewed commit. A new GHCR package is private by default: the owner must make it public (the image holds no secret) or decide on a pull credential. Any such change is a separate decision.

## Credentials plan (per run; none are the owner's identity; nothing is printed)

1. In a mode-0700 temp dir, create two throwaway ed25519 keypairs (exec host key, client key) with `env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -f ...`. No agent, no passphrase, no PAT.
2. `known_hosts` holds one line with the alias `exp006-exec` and the host public key.
3. `authorized_keys` holds `restrict,pty,command="tmux -S /tmp/agent/tmux.sock -f /dev/null attach -t agent" <client public key>`.
4. Put them in Secrets `exp006-exec-ssh` and `exp006-client-ssh` with `--from-file` (K01). Shred the temp dir at K06.

## Resource budget

Requests per pod: cpu 50m, memory 64Mi, ephemeral 64Mi. Limits: exec 500m / 256Mi / 256Mi; Herdr 500m / 512Mi / 512Mi.
Totals: requests 100m / 128Mi / 128Mi; limits 1000m / 768Mi / 768Mi. emptyDir sizeLimits: exec 128Mi; Herdr 128Mi + 32Mi + 128Mi. Placement: required anti-affinity keeps both pods off the live Herdr node and off each other.

## Procedure

Setup (run in **bash**, not zsh: the `$K`/`$X`/`$H` command variables rely on word splitting; `CTX` is the owner's kube context, never committed; `jq` runs locally):
```
export RUN_ID=s2a NS=herdrnetes-exp006-s2a CTX=<context>   # RUN_ID: [a-z0-9-], NS must be herdrnetes-exp006-$RUN_ID
K="kubectl --context $CTX"; umask 077; WORK=$(mktemp -d); mkdir "$WORK"/{m,keys,ev}
for f in manifests/*.yaml; do sed -e "s/\${RUN_ID}/$RUN_ID/g" -e "s|sha256:<DIGEST-FROM-G1-BUILD>|$EXEC_DIGEST|" "$f" >"$WORK/m/$(basename "$f")"; done  # EXEC_DIGEST=sha256:<hex>
grep -nE '<[A-Z]|\$\{' "$WORK"/m/*.yaml   # must print nothing (no unfilled placeholder)
test "$(grep -hoE 'herdrnetes-exp006-[a-z0-9-]+' "$WORK"/m/*.yaml | sort -u)" = "$NS" && echo ns-ok   # every manifest names only the run namespace
baseline() { { $K config current-context >/dev/null && $K get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
  $K -n herdrnetes-exp get pod herdr-0 -o jsonpath='{.metadata.uid} {.spec.nodeName}{range .status.containerStatuses[*]} {.restartCount} {.imageID}{end}{"\n"}'
  $K -n herdrnetes-exp get sts,pvc,networkpolicy -o name; $K get pv -o json | jq -S '[.items[]|{n:.metadata.name,c:.spec.claimRef}]'
  $K -n argo-system get applications.argoproj.io <cluster>-herdrnetes-exp -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'; } 2>&1; }
```
`baseline` output names nodes: it stays in `$WORK/ev` and is sanitized before anything is committed.

**K00 read-only preflight.** `baseline >"$WORK/ev/k00.txt"`; `$K get ns "$NS"` must print `Error from server (NotFound)`; `$K get ns -l herdrnetes.io/experiment=exp-006` lists none. Expected: the context is the intended cluster, all nodes Ready, at least 3 schedulable nodes (two besides the live Herdr node), `herdr-0` Running with its UID, node, restart counts and image IDs recorded, Argo CD app Synced/Healthy.

**K01 namespace, network, secrets, exec pod.**
```
$K apply -f "$WORK/m/namespace.yaml"; $K -n "$NS" apply -f "$WORK/m/networkpolicy.yaml" -f "$WORK/m/service.yaml"
env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -C "exp006-host-$RUN_ID" -f "$WORK/keys/host"
env -u SSH_AUTH_SOCK ssh-keygen -q -t ed25519 -N '' -C "exp006-client-$RUN_ID" -f "$WORK/keys/client"
printf 'restrict,pty,command="tmux -S /tmp/agent/tmux.sock -f /dev/null attach -t agent" %s\n' "$(cut -d' ' -f1,2 "$WORK/keys/client.pub")" >"$WORK/keys/authorized_keys"
printf 'exp006-exec %s\n' "$(cut -d' ' -f1,2 "$WORK/keys/host.pub")" >"$WORK/keys/known_hosts"
$K -n "$NS" create secret generic exp006-exec-ssh --from-file=ssh_host_ed25519_key="$WORK/keys/host" --from-file=authorized_keys="$WORK/keys/authorized_keys"
$K -n "$NS" create secret generic exp006-client-ssh --from-file=id_ed25519="$WORK/keys/client" --from-file=known_hosts="$WORK/keys/known_hosts"
$K -n "$NS" label secret exp006-exec-ssh exp006-client-ssh herdrnetes.io/experiment=exp-006 herdrnetes.io/run-id="$RUN_ID"
$K apply -f "$WORK/m/exec-pod.yaml"; $K -n "$NS" wait --for=condition=Ready pod/exp006-exec --timeout=300s
X="$K -n $NS exec exp006-exec --"; $K -n "$NS" get pod exp006-exec -o jsonpath='{.metadata.uid} {.spec.nodeName} {.status.containerStatuses[0].restartCount}{"\n"}'
$X cat /tmp/agent/out/identity
$X bash -c 'p=$(sed -n "s/^pid=//p" /tmp/agent/out/identity); sed "s/.*) //" /proc/$p/stat | awk "{print \$20}"; ps -eo pid,ppid,cmd'
```
Expected: Ready within 5 min on a node other than the live one; `identity` has `pid`, `start`, `nonce`; the `/proc` field 22 value equals `start`; the tmux server has ppid 1 (tini). Save outputs to `$WORK/ev`.

**K02 Herdr pod and first attach.**
```
$K apply -f "$WORK/m/herdr-pod.yaml"; $K -n "$NS" wait --for=condition=Ready pod/exp006-herdr --timeout=300s
H="$K -n $NS exec exp006-herdr -c herdr -- herdr"
ATTACH='ssh -i /run/exp006/client/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/exp006/client/known_hosts -o HostKeyAlias=exp006-exec -o UpdateHostKeys=no -p 2222 -t herdr@exp006-exec'
newpane() { $H workspace create --cwd /tmp --label "$1" --no-focus | jq -r .result.root_pane.pane_id; }
attach() { P=$(newpane "$1"); $H pane run "$P" "$ATTACH"; sleep 5; }
mark() { $H pane send-text "$P" "mark $1"; $H pane send-keys "$P" Enter; $H pane wait-output "$P" --match "ACK $1 pid=" --source visible --timeout 15000 && $H pane read "$P" --source visible --lines 40 >"$WORK/ev/pane-$1.txt"; }
attach k02; mark k02; $X grep ' ACK k02 ' /tmp/agent/out/counter.log; $X tmux -S /tmp/agent/tmux.sock list-clients
```
Expected: the ACK line carries the K01 `pid`, `start` and `nonce`; one tmux client. Failure twice: stop.

**K03 pane close, continuity, reattach.** `n0=$($X tail -1 /tmp/agent/out/counter.log)`; `$H pane close "$P"`; wait 10 s; `$X tmux -S /tmp/agent/tmux.sock list-clients` (expect none); `$X cat /tmp/agent/out/identity` and `$X tail -3 /tmp/agent/out/counter.log` (same identity, `n` advanced past `n0`); then `attach k03; mark k03`. Expected: same triple, `n` greater than at close.

**K04 Herdr pod replacement.** `$K -n "$NS" delete pod exp006-herdr --wait=true`; `$K -n "$NS" get pod exp006-herdr` (NotFound); `$X tail -2 /tmp/agent/out/counter.log` twice, a few seconds apart (still advancing); `$K apply -f "$WORK/m/herdr-pod.yaml"`; wait Ready; `attach k04; mark k04`. Expected: the new Herdr has no panes; the ACK shows the same triple. This is a pod replacement, not a Herdr upgrade.

**K05 identity and continuity.** `$X cat /tmp/agent/out/counter.log >"$WORK/ev/counter.log"`; `grep -E ' ACK k0[234] ' "$WORK/ev/counter.log"` (three ACKs, one triple, rising `n`); `grep COUNT "$WORK/ev/counter.log" | sed 's/.*n=//' | awk 'NR>1&&$1!=p+1{g++}{p=$1}END{print "gaps="g+0,"last="p}'` (expect `gaps=0`); re-run the K01 pod command (UID, restartCount 0 and `startedAt` unchanged: `$K -n "$NS" get pod exp006-exec -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}'`).

**K06 label-guarded cleanup.**
```
test "$($K get ns "$NS" -o jsonpath='{.metadata.labels.herdrnetes\.io/experiment}')" = exp-006 && test "$($K get ns "$NS" -o jsonpath='{.metadata.labels.herdrnetes\.io/run-id}')" = "$RUN_ID" && case $NS in herdrnetes-exp006-*) ;; *) false;; esac
$K delete ns "$NS" --wait=true --timeout=300s
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
| Live `herdrnetes-exp/herdr-0` | UID `fe7cd780-06ae-4756-ad8e-d22deb410a38`, Running since 2026-11-19T07:45:51Z, restarts 0/0. `herdr` at `ghcr.io/jlaska/herdrnetes-herdr@sha256:c5a235ae…8e277`, `ovis` at `ghcr.io/jlaska/herdrnetes-ovis@sha256:8e31cc27…0db`. Labels include `app.kubernetes.io/name=herdr` (the anti-affinity selector) |
| Argo CD | `argo-system/<cluster>-herdrnetes-exp` Synced/Healthy |
| DNS | `kube-system` pods labelled `k8s-app=kube-dns` (matches `herdr-egress`) |
| `auth can-i` (owner admin context) | yes for namespaces, pods, secrets, services, networkpolicies and pods/exec |

## Owner-operated or approval-gated steps (in order)

1. **Image build.** Review `exec-image/`, including `proposed-workflow-exp006-exec-image.yml`. In an owner-operated commit, copy the workflow to `.github/workflows/exp006-exec-image.yml` on `main` (`workflow_dispatch` only runs from the default branch; the agent's token cannot write workflows). Dispatch it and record the digest. Make the GHCR package public, or choose a pull credential. The agent cannot do this: there is no local build or push, and no personal GHCR identity.
2. **Rehearsal, optional but recommended.** Run the built image locally with `podman` to retire risks 1–4 below before touching the cluster. The agent did not do this, because earlier local build and rehearsal delegation was declined by the agent permission system.
3. **G1.** Commit the digest into `manifests/exec-pod.yaml`, fill `Commit SHA`, review, then run K00–K06 owner-operated or explicitly agent-authorized.

## Stop conditions

Stop and report (do not continue) on: any K00 baseline change; a rendered manifest whose namespace is not the run namespace; a pod not Ready within 5 min; a pod scheduled onto the live Herdr node; PSA rejection; the K02 attach failing twice; any ssh prompt for a password or passphrase.

## Safety

No changes to `herdrnetes-exp`, Argo CD or Longhorn (only reads). No owner SSH or GPG agent use (`env -u SSH_AUTH_SOCK`, `IdentityAgent=none`). No PAT. No secrets, key text, node names or contexts in the repo or in committed evidence. Sanitize before committing.

## Untested risks

1. Non-root `sshd` under PSA restricted (no setuid, no chroot): `/run/sshd`, OpenSSH 10 `sshd-session` re-exec, the pre-auth sandbox under RuntimeDefault seccomp, and the `sshd` privsep user. Unverified; build and rehearsal must show it.
2. `StrictModes yes`: `authorized_keys` lives under the passwd home `/tmp/home` (0700), where sshd's parent-directory walk stops, so `/tmp` (1777) should not be checked. Fallback if rejected: `EXP006_STRICT_MODES=no` (entrypoint env) in a reviewed manifest change.
3. The client key Secret file is root-owned and group-readable through fsGroup. `ssh` may refuse it (believed to check only files it owns). Fallback: `install -m 0600` it into an emptyDir and change `-i`.
4. `HostKeyAlias=exp006-exec` with `-p 2222` should match a plain `exp006-exec` known_hosts line; confirm with `ssh -v`.
5. The EXP-002 entrypoint has never run with emptyDir `$HOME`, `/run/herdr` and a read-only rootfs; hook reconciliation writes under `$HOME`.
6. NetworkPolicy: the kube-dns labels, a node-local DNS cache, and whether the CNI lets kubelet reach tcpSocket 2222 through ingress deny.
7. GHCR package visibility after a GITHUB_TOKEN first push; Debian pins go stale when the archive moves.
8. Only two non-live nodes can host the pods; tmux client count can lag after pod deletion (half-open TCP).
