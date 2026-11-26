#!/usr/bin/env bash
# Regression test for the run 1125-2032 STOP: the sampler's kubectl watch pipeline must write each event to its
# file immediately (jq --unbuffered), survive the sampler's `kill 0` without losing it, and sampler_gate must
# pass on real data and fail on missing or error-only data. The real kwatch(), sampler_gate() and now() bodies
# are extracted from stagec.sh and run against a stub kubectl. No cluster, no network.
set -uo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)/stagec.sh
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; for p in $(cat "$T"/pg-* 2>/dev/null); do kill -TERM -- "-$p" 2>/dev/null; done; rm -rf "$T"' EXIT
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
fn() { awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' "$H"; }
{ fn now; fn ems; fn kwatch; fn sampler_gate; fn sampler_done; } >"$T/lib.sh"
grep -q -- '--unbuffered' "$T/lib.sh" && ok "kwatch extracted and uses jq --unbuffered" || no "kwatch missing or buffered"
grep -q '^sampler_gate()' "$T/lib.sh" && ok "sampler_gate extracted" || no "sampler_gate not extracted"
# stub kubectl: a watch prints one pretty-printed watch event (as kubectl -o json does), then stays open
cat >"$T/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" --watch "*)
  printf '{\n  "type": "ADDED",\n  "object": {\n    "kind": "Pod",\n    "metadata": {"name": "openshell-0", "uid": "u-1", "resourceVersion": "7"},\n    "status": {"phase": "Running"}\n  }\n}\n'
  exec sleep 60 ;;
esac
STUB
chmod +x "$T/kubectl"
cat >"$T/run.sh" <<EOF
E=$T/e NS=openshell GW_POD=openshell-0 KC=($T/kubectl --context test)
. $T/lib.sh
EOF
mkdir -p "$T/e/samples"
start_watch() { # start_watch <lib> <out>: kwatch in its own process group (as the sampler's setsid), pgid recorded
  setsid bash -c ". $T/run.sh; . $1; echo \$\$ >$T/pg-\$(basename $2); kwatch $2 pods" </dev/null >/dev/null 2>&1 &
}
waitsize() { local i; for i in $(seq 50); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }

# 1. the event reaches the file while the watch is still open
start_watch "$T/lib.sh" "$T/e/samples/pods-watch.jsonl"
waitsize "$T/e/samples/pods-watch.jsonl" && ok "watch event written while the stream is open (<= 5 s)" || no "pods-watch.jsonl still empty after 5 s"
jq -e 'select(.name == "openshell-0" and .type == "ADDED" and .phase == "Running")' "$T/e/samples/pods-watch.jsonl" >/dev/null 2>&1 \
  && ok "event parsed into the compact record" || no "record not parsed: $(head -c 200 "$T/e/samples/pods-watch.jsonl")"

# 2. sampler_gate passes on a real 1 Hz line plus a parsed event
printf '## t\nopenshell-0 c7-uid Running del= openshell-gateway:true:0:containerd://x \n' >"$T/e/samples/pods-1hz.txt"
( . "$T/run.sh"; sampler_gate ) && ok "gate passes on real data" || no "gate failed on real data"

# 3. the sampler's stop (kill 0 = SIGTERM to the whole group) keeps what was written
kill -TERM -- "-$(cat "$T/pg-pods-watch.jsonl")" 2>/dev/null; sleep 0.5
jq -e 'select(.name == "openshell-0")' "$T/e/samples/pods-watch.jsonl" >/dev/null 2>&1 && ok "event survives SIGTERM of the sampler group" || no "event lost on SIGTERM"

# 4. gate negatives (sleep stubbed so each takes no wall time)
neg() { ( . "$T/run.sh"; sleep() { :; }; sampler_gate ); }
cp "$T/e/samples/pods-watch.jsonl" "$T/good.jsonl"
printf '## t\nerror: You must be logged in to the server (Unauthorized)\n' >"$T/e/samples/pods-1hz.txt"
neg && no "gate passed on an error-only 1 Hz sample" || ok "gate fails on an error-only 1 Hz sample"
printf '## t\nopenshell-0 c7-uid Running del= \n' >"$T/e/samples/pods-1hz.txt"; : >"$T/e/samples/pods-watch.jsonl"
neg && no "gate passed on an empty pod watch" || ok "gate fails on an empty pod watch"
echo '{"type":"ADDED","name":"other-pod"}' >"$T/e/samples/pods-watch.jsonl"
neg && no "gate passed without an event for the gateway pod" || ok "gate fails without an event for the gateway pod"
echo 'not json' >"$T/e/samples/pods-watch.jsonl"
neg && no "gate passed on unparsable watch output" || ok "gate fails on unparsable watch output"

# 4b. sampler_done: false without cleanup, false within 120 s of it, true after
( . "$T/run.sh"; mkdir -p "$E/obs"; rm -f "$E/obs/cleanup-done"; ! sampler_done ) && ok "sampler_done false before cleanup" || no "sampler_done true before cleanup"
( . "$T/run.sh"; echo "$(( $(date +%s%3N) - 60000 ))" >"$E/obs/cleanup-done"; ! sampler_done ) && ok "sampler_done false 60 s after cleanup" || no "sampler_done true too early"
( . "$T/run.sh"; echo "$(( $(date +%s%3N) - 121000 ))" >"$E/obs/cleanup-done"; sampler_done ) && ok "sampler_done true 121 s after cleanup" || no "sampler_done false after 120 s"

# 5. negative control: the same kwatch without --unbuffered reproduces the defect (file stays empty)
sed 's/ --unbuffered//' "$T/lib.sh" >"$T/lib-buffered.sh"
start_watch "$T/lib-buffered.sh" "$T/e/samples/buffered.jsonl"
sleep 3
[ ! -s "$T/e/samples/buffered.jsonl" ] && ok "negative control: buffered jq leaves the file empty (the 1125-2032 defect)" || no "negative control did not reproduce the defect"
kill -TERM -- "-$(cat "$T/pg-buffered.jsonl")" 2>/dev/null; sleep 0.5
[ ! -s "$T/e/samples/buffered.jsonl" ] && ok "negative control: buffered tail is lost on SIGTERM" || no "negative control flushed on SIGTERM"
echo "failures=$fails"; [ "$fails" = 0 ]
