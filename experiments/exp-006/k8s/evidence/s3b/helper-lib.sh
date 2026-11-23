# G1 s3b session lib: stage-3 runbook setup at f4197df (functions verbatim); inputs from g1-inputs.env (never committed)
set -o pipefail; set -a; . <g1>-inputs.env; set +a
export RUN_ID=s3b NS=herdrnetes-exp006-s3b KEY_FILE=<owner-key-file>
K="kubectl --context $CTX"; umask 077; WORK=<g3b>/work
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
P1_T='Session codeword is @CODE@. Do not write it to any file. Task: in kata.py implement f01, f02, f03, f04 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f04 passes, reply with exactly: DONE-A @CODE@'
PB='Task: in kata.py implement f05, f06, f07, f08 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f08 passes, reply with exactly: DONE-B'
PC='Task: in kata.py implement f09, f10, f11, f12 in order, one at a time; after EACH function run exactly the command "python3 check.py" (no arguments). Do not touch other functions or files. When f12 passes, reply with exactly: DONE-C'
Q_T='Reply with exactly one line: Q@K@ CODEWORD=<the session codeword from my first message> DONE=<number of functions passing per your last check>'
ATTACH='ssh -i /run/exp006/client/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/exp006/client/known_hosts -o HostKeyAlias=exp006-exec -o UpdateHostKeys=no -p 2222 -t herdr@exp006-exec'
newpane() { H workspace create --cwd /tmp --label "$1" --no-focus | jq -r .result.root_pane.pane_id; }
attach() { P=$(newpane "$1") && [ -n "$P" ] && [ "$P" != null ] && echo "$P" >"$WORK/pane" && H pane run "$P" "$ATTACH" && sleep 5; }   # as runbook; P persisted across shells
P=$(cat "$WORK/pane" 2>/dev/null); CODE=$(cat "<g3b>/code" 2>/dev/null); [ -f "$WORK/vars" ] && . "$WORK/vars"   # CODE: 0600 scratch file, never committed
