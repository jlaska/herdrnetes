#!/usr/bin/env bash
# Cluster-free header-capture regression test for the Stage C launcher (owner requirement, 2026-11-26).
# Runs the REAL bootstrap, launcher and settings with the REAL Claude Code binary (sha256-pinned, the one in the
# agent image) against a local mock endpoint, inside an unprivileged user+network namespace whose only
# interface is loopback: no network, no model, no credential. The "placeholder" is a made-up string of the
# documented shape. Asserts what OpenShell v0.1.9's single x-api-key placement requires:
#   every request carries the placeholder in x-api-key only (no Authorization, no other header, not in a body),
#   at least one POST /v1/messages is sent, and no custom-API-key approval dialog appears.
# Negative control: the run 1125-2153 launcher + settings (apiKeyHelper, from git bdbbd6f) must FAIL the same
# assertions by sending "Authorization: Bearer <placeholder>". Exit 2 (NOT RUN) if the pinned binary is absent.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CLAUDE_SHA=604d29a6869409106b6a1110bdadcc8b72e8654a5a865d23258f938a696e348e
FAKE=openshell:resolve:env:v7_ANTHROPIC_API_KEY
fails=0; ok() { echo "ok   - $*"; }; no() { echo "FAIL - $*"; fails=$((fails + 1)); }
BIN=
for c in "${CLAUDE_BIN:-}" "$(command -v claude 2>/dev/null)" /home/linuxbrew/.linuxbrew/Caskroom/claude-code/2.1.323/claude; do
  [ -n "$c" ] && c=$(readlink -f "$c") && [ -x "$c" ] && [ "$(sha256sum "$c" | cut -d' ' -f1)" = "$CLAUDE_SHA" ] && { BIN=$c; break; }
done
[ -n "$BIN" ] || { echo "NOT RUN: no Claude Code binary with sha256 $CLAUDE_SHA (set CLAUDE_BIN)"; exit 2; }
unshare -rn true 2>/dev/null || { echo "NOT RUN: unprivileged user+network namespaces unavailable"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

pkg() { # pkg <name> <launch.sh> <settings.json>: remapped package, as tests/launch-test.sh does
  local d=$T/$1; mkdir -p "$d/src"
  cp "$2" "$d/src/launch.sh"; cp "$3" "$d/src/settings.json"; cp "$HERE/task/step.sh" "$HERE/task/prompt.txt" "$d/src/"
  chmod 0644 "$d/src"/*; chmod 0755 "$d/src/launch.sh" "$d/src/step.sh"
  sed -i -e "s#/sandbox/c#$d/sb/c#g" -e "s#/usr/local/bin/claude#$BIN#g" "$d/src/launch.sh"
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$d/src" -cf "$d/p.tar" launch.sh prompt.txt settings.json step.sh
  base64 -w0 "$d/p.tar" >"$d/p.b64"; sha256sum "$d/p.tar" | cut -d' ' -f1 >"$d/p.sha"
  # shellcheck disable=SC2016
  L=$T E=$T RUN=0000-0000 IMG=x PROV=x bash -c '. "$1/launcher.sh"; printf %s "$BOOT"' _ "$HERE" | sed -e "s#/sandbox/c#$d/sb/c#g" >"$d/boot.sh"
}
capture() { # capture <name>: run inside a loopback-only netns; writes $T/<name>/cap.json
  local d=$T/$1
  unshare -rn sh -c 'ip link set lo up && exec /usr/bin/python3 -I "$0" "$@"' "$HERE/tests/header_capture.py" \
    "$d/cap.json" "$d/boot.sh" "$d/p.b64" "$(cat "$d/p.sha")" "$FAKE" 60 >"$d/run.log" 2>&1
}
verdict() { # verdict <cap.json>: one line "posts=N xapikey=... authorization=... other=... body=... dialog=..."
  /usr/bin/python3 -I -c '
import json, sys
c = json.load(open(sys.argv[1])); r = c["requests"]
f = lambda k: ",".join(sorted({q[k] for q in r})) or "none"
print("posts=%d requests=%d xapikey=%s authorization=%s other=%s body=%s dialog=%s" % (c["messages_posts"], len(r), f("x-api-key"), f("authorization"),
      ",".join(sorted({h for q in r for h in q["placeholder_in_other_headers"]})) or "none", any(q["placeholder_in_body"] for q in r), c["custom_key_dialog_seen"]))' "$1"
}

pkg fixed "$HERE/task/launch.sh" "$HERE/task/settings.json"
capture fixed
[ -s "$T/fixed/cap.json" ] && ok "capture ran (pinned binary, loopback-only netns)" || { no "capture produced no result: $(tail -c 300 "$T/fixed/run.log")"; echo "failures=$fails"; exit 1; }
v=$(verdict "$T/fixed/cap.json"); echo "     fixed launcher: $v"
[[ $v =~ posts=([1-9][0-9]*) ]] && ok "agent sent POST /v1/messages (${BASH_REMATCH[1]})" || no "no POST /v1/messages"
[[ $v == *" xapikey=placeholder "* ]] && ok "every request: placeholder in x-api-key" || no "x-api-key form(s) not only placeholder"
[[ $v == *" authorization=absent "* ]] && ok "no request carries an Authorization header" || no "Authorization header present"
[[ $v == *" other=none "* ]] && ok "placeholder in no other header" || no "placeholder in another header"
[[ $v == *" body=False "* ]] && ok "placeholder in no request body" || no "placeholder in a request body"
[[ $v == *" dialog=False" ]] && ok "no custom-API-key approval dialog" || no "custom-API-key dialog shown"

# negative control: the launcher and settings that ran in 1125-2153 (apiKeyHelper) must be caught
git -C "$HERE" show bdbbd6f:experiments/exp-008/stage-c/task/launch.sh >"$T/old-launch.sh" 2>/dev/null \
  && git -C "$HERE" show bdbbd6f:experiments/exp-008/stage-c/task/settings.json >"$T/old-settings.json" 2>/dev/null \
  || { no "negative control: cannot read the bdbbd6f launcher from git"; echo "failures=$fails"; exit 1; }
pkg old "$T/old-launch.sh" "$T/old-settings.json"
capture old
v=$(verdict "$T/old/cap.json" 2>/dev/null); echo "     1125-2153 launcher: $v"
[[ $v == *" authorization=bearer-placeholder "* ]] && ok "negative control: the 1125-2153 launcher sends Authorization: Bearer <placeholder> (the defect)" \
  || no "negative control did not reproduce the 1125-2153 defect"
echo "failures=$fails"; [ "$fails" = 0 ]
