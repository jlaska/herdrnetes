#!/usr/bin/env bash
# Local scenario H/E: run a sequence of image variants against ONE persistent
# home volume, as successive GitOps image changes would, and record the hook
# files, settings, integration status and layout after each hop.
#
#   hooks-test.sh <workdir> <hooks-mode:reconcile|skip> <variant>...
#   e.g. hooks-test.sh /tmp/x reconcile h095-c311 h080-c311 h095-c311
#
# Before the first hop a user-owned Claude hook and setting are seeded into
# settings.json to check that reconciliation preserves them.
set -uo pipefail
wd=${1:?workdir} mode=${2:?reconcile|skip}
shift 2
REPO=${IMAGE_REPO:-ghcr.io/jlaska/herdrnetes-herdr}
[ -e "$wd" ] && { echo "refusing to reuse $wd" >&2; exit 1; }
mkdir -p "$wd"/{home/.claude,workspace/alpha/sub,workspace/beta,evidence}
ev=$wd/evidence
cat >"$wd/home/.claude/settings.json" <<'EOF'
{
  "permissions": {"allow": ["Bash(git status)"]},
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "echo user-hook", "timeout": 5}]}
    ]
  }
}
EOF
name="exp002-hooks-$$"
x() { podman exec "$name" "$@"; }
hop=0
for v in "$@"; do
  hop=$((hop + 1))
  # First hop always reconciles (fresh home); later hops use the chosen mode.
  hm=$mode
  [ "$hop" = 1 ] && hm=reconcile
  podman run -d --name "$name" --userns=keep-id:uid=1000,gid=1000 --read-only --cap-drop=ALL \
    --security-opt no-new-privileges --tmpfs /tmp:rw,mode=1777 --tmpfs /run/herdr:rw,mode=0700,U \
    -v "$wd/home:/home/herdr:Z" -v "$wd/workspace:/workspace:Z" -e HOME=/home/herdr \
    -e "HERDRNETES_HOOKS=$hm" "$REPO:exp002-$v" >/dev/null
  for _ in $(seq 1 100); do x herdr status server >/dev/null 2>&1 && break; sleep 0.1; done
  out="$ev/hop$hop-$v"
  mkdir -p "$out"
  x herdr --version >"$out/version.txt" 2>&1
  x herdr status server >"$out/status.txt" 2>&1
  x herdr integration status >"$out/integration-status.txt" 2>&1
  x sh -c 'grep -h HERDR_INTEGRATION_VERSION ~/.claude/hooks/* ~/.codex/herdr-agent-state.sh 2>&1; ls -la ~/.claude/hooks' >"$out/hook-files.txt" 2>&1
  cp "$wd/home/.claude/settings.json" "$out/claude-settings.json"
  cp "$wd/home/.codex/hooks.json" "$out/codex-hooks.json" 2>/dev/null
  cp "$wd/home/.codex/config.toml" "$out/codex-config.toml" 2>/dev/null
  if [ "$hop" = 1 ]; then
    # Layout to carry across versions: 2 workspaces, a split, a label.
    x herdr workspace create --cwd /workspace/alpha --label alpha --no-focus >/dev/null
    x herdr workspace create --cwd /workspace/beta --label beta --no-focus >/dev/null
    sleep 1
    p=$(x herdr api snapshot | python3 -c 'import json,sys;s=json.load(sys.stdin)["result"]["snapshot"];w=[w for w in s["workspaces"] if w["label"]=="alpha"][0]["workspace_id"];t=[t for t in s["tabs"] if t["workspace_id"]==w][0]["tab_id"];print([l for l in s["layouts"] if l["tab_id"]==t][0]["panes"][0]["pane_id"])')
    x herdr pane split "$p" --direction right --cwd /workspace/alpha/sub --no-focus >/dev/null
    x herdr pane rename "$p" editor >/dev/null
    sleep 7
  fi
  x herdr api snapshot 2>/dev/null | python3 -c '
import json,sys
s=json.load(sys.stdin)["result"]["snapshot"]
for w in sorted(s["workspaces"], key=lambda w: w["number"]):
    print("ws", w["label"])
for p in s["panes"]:
    print("pane", p.get("label") or "-", p.get("cwd"))' >"$out/layout.txt" 2>&1
  podman stop -t 30 "$name" >/dev/null
  podman logs "$name" >"$out/container.log" 2>&1
  podman rm "$name" >/dev/null
  cp "$wd/home/.config/herdr/session.json" "$out/session.json" 2>/dev/null
  echo "== hop $hop $v hooks=$hm: $(tr '\n' ' ' <"$out/version.txt")"
  grep -E '^(claude|codex):' "$out/integration-status.txt"
  grep -c . "$out/layout.txt" | sed 's/^/layout lines: /'
done
