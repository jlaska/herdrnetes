#!/usr/bin/env bash
# Offline test of the Stage C bootstrap argv and launcher (no cluster, no network, no model, no credential).
# /sandbox/c is remapped to a temp dir and /usr/local/bin/claude to a stub that records its argv and the
# FORM of the key-related variables. The "placeholder" below is a made-up string of the documented shape.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "ok   - $1"; }; no() { echo "FAIL - $1"; fails=$((fails + 1)); }

# stub claude: same PID as the launcher (exec), records argv and variable forms
cat >"$T/fakeclaude" <<'EOF'
#!/bin/sh
f() { case $1 in '') echo absent ;; openshell:resolve:*) echo placeholder ;; *) echo other ;; esac; }
{ echo "pid=$$"; echo "keyref=$(f "${EXP008_ANTHROPIC_KEYREF:-}")"; echo "ak=$(f "${ANTHROPIC_API_KEY:-}")"; echo "at=$(f "${ANTHROPIC_AUTH_TOKEN:-}")"; echo "ot=$(f "${CLAUDE_CODE_OAUTH_TOKEN:-}")"
  echo "nonce_set=$([ -n "${EXP008_NONCE:-}" ] && echo yes || echo no)"; echo "ccd=$CLAUDE_CONFIG_DIR"; echo "pwd=$(pwd)"
  echo "ca=${NODE_EXTRA_CA_CERTS:-unset}"; for a in "$@"; do echo "arg=$a"; done; } >"$OUTF"
EOF
chmod 0755 "$T/fakeclaude"

# build the package exactly as the harness does (launcher.sh pkg_build), twice: must be deterministic
L=$T; E=$T; RUN=0000-0000; IMG=x; PROV=exp008c-test
# shellcheck source=../launcher.sh
. "$HERE/launcher.sh"
pkg_build "$T/a.tar"; pkg_build "$T/b.tar"
cmp -s "$T/a.tar" "$T/b.tar" && ok "package build is deterministic" || no "package build is not deterministic"
SHA=$(sha256sum "$T/a.tar" | cut -d' ' -f1)

# remap paths for the offline run
mkdir -p "$T/sb"
BOOT_T=$(sed -e "s#/sandbox/c#$T/sb/c#g" <<<"$BOOT")
mkdir -p "$T/pkgsrc" && tar -xf "$T/a.tar" -C "$T/pkgsrc"
sed -i -e "s#/sandbox/c#$T/sb/c#g" -e "s#/usr/local/bin/claude#$T/fakeclaude#g" "$T/pkgsrc/launch.sh"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$T/pkgsrc" -cf "$T/t.tar" launch.sh prompt.txt settings.json step.sh
TSHA=$(sha256sum "$T/t.tar" | cut -d' ' -f1)

# 1. tampered package is refused
env -i PATH=/usr/bin:/bin OUTF="$T/out0" /bin/sh -c "$BOOT_T" "$(base64 -w0 "$T/t.tar")" "$SHA" 2>/dev/null \
  && no "bootstrap accepted a package whose sha256 differs" || ok "bootstrap refuses a sha256 mismatch"
rm -rf "$T/sb/c"

# 2. no placeholder -> agent not started
env -i PATH=/usr/bin:/bin OUTF="$T/out1" /bin/sh -c "$BOOT_T" "$(base64 -w0 "$T/t.tar")" "$TSHA" 2>/dev/null \
  && no "launcher started without a placeholder" || ok "launcher refuses to start without a placeholder"
[ ! -e "$T/out1" ] && ok "claude not exec'd without a placeholder" || no "claude exec'd without a placeholder"
grep -q '^key_form=absent$' "$T/sb/c/launch/identity" && ok "identity records key_form=absent" || no "identity key_form"
rm -rf "$T/sb/c"

# 3. placeholder present -> kept in ANTHROPIC_API_KEY (sent only as X-Api-Key), no KEYREF variable, approval tail seeded, same PID, CA var kept
echo pem >"$T/ca.crt"
env -i PATH=/usr/bin:/bin OUTF="$T/out2" ANTHROPIC_API_KEY=openshell:resolve:env:v1_ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN=injected CLAUDE_CODE_OAUTH_TOKEN=injected \
  NODE_EXTRA_CA_CERTS="$T/ca.crt" /bin/sh -c "$BOOT_T" "$(base64 -w0 "$T/t.tar")" "$TSHA"
grep -q '^ak=placeholder$' "$T/out2" && ok "placeholder kept in ANTHROPIC_API_KEY for claude" || no "ANTHROPIC_API_KEY not the placeholder"
grep -q '^keyref=absent$' "$T/out2" && ok "no EXP008_ANTHROPIC_KEYREF (no apiKeyHelper path)" || no "keyref variable present"
grep -q '^at=absent$' "$T/out2" && grep -q '^ot=absent$' "$T/out2" && ok "ANTHROPIC_AUTH_TOKEN and CLAUDE_CODE_OAUTH_TOKEN unset (no Bearer source)" || no "a Bearer-capable variable reached claude"
grep -q "^ca=$T/ca.crt$" "$T/out2" && ok "inherited NODE_EXTRA_CA_CERTS kept" || no "CA variable lost"
grep -q '^nonce_set=yes$' "$T/out2" && ok "nonce exported" || no "nonce"
[ "$(sed -n 's/^pid=//p' "$T/out2")" = "$(sed -n 's/^pid=//p' "$T/sb/c/launch/identity")" ] && ok "claude keeps the launcher PID (exec chain)" || no "PID changed across exec"
grep -q '^key_form=placeholder$' "$T/sb/c/launch/identity" && grep -q '^node_extra_ca=readable$' "$T/sb/c/launch/identity" && ok "identity record forms" || no "identity record"
grep -q -x "pwd=$T/sb/c/repo" "$T/out2" && ok "cwd is the task repo" || no "cwd"
for a in --bare --strict-mcp-config --tools Bash --model claude-haiku-5-5 --session-id; do grep -q -x -- "arg=$a" "$T/out2" || no "missing arg $a"; done
grep -q -x 'arg=--settings' "$T/out2" && ok "claude argv flags present" || no "argv"
grep -q 'hasTrustDialogAccepted' "$T/sb/c/claude/.claude.json" && cmp -s "$T/sb/c/claude/.claude.json" "$T/sb/c/home/.claude.json" && ok "first-run state seeded in CLAUDE_CONFIG_DIR and HOME" || no "seed"
python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); assert "apiKeyHelper" not in s and s["permissions"]["defaultMode"]=="dontAsk" and "Read(/sandbox/c/home/**)" in s["permissions"]["deny"] and "Read(/proc/**)" in s["permissions"]["deny"]' "$T/sb/c/settings.json" && ok "settings.json valid, no apiKeyHelper, home state read-denied" || no "settings.json"
python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["customApiKeyResponses"] == {"approved": [sys.argv[2][-20:]], "rejected": []}, s' "$T/sb/c/claude/.claude.json" "openshell:resolve:env:v1_ANTHROPIC_API_KEY" \
  && ok "custom-key approval seeded with the placeholder's last 20 characters only" || no "customApiKeyResponses"
grep -r -q -F 'openshell:resolve' "$T/sb/c" && no "placeholder prefix appears literally in the state tree" || ok "placeholder prefix not literal on disk"
grep -r -q -F 'env:v1_ANTHROPIC_API_KEY' "$T/sb/c" && no "more than the 20-character approval tail written to the state tree" || ok "no more than the approval tail of the placeholder on disk"
[ "$(grep -r -l -F 'v1_ANTHROPIC_API_KEY' "$T/sb/c" | sed "s#$T/sb/c/##" | sort | tr '\n' ' ')" = "claude/.claude.json home/.claude.json " ] \
  && ok "approval tail only in the two seeded .claude.json files" || no "approval tail elsewhere: $(grep -r -l -F 'v1_ANTHROPIC_API_KEY' "$T/sb/c")"

# 3b. a placeholder with unexpected characters (would change under trim / need JSON escaping) or < 20 chars is refused
for bad in 'openshell:resolve:env:v1_ANTHROPIC_API_KEY ' 'openshell:resolve:env:v1_"X' 'openshell:resolve:x'; do
  rm -rf "$T/sb/c"
  env -i PATH=/usr/bin:/bin OUTF="$T/outb" ANTHROPIC_API_KEY="$bad" /bin/sh -c "$BOOT_T" "$(base64 -w0 "$T/t.tar")" "$TSHA" 2>/dev/null \
    && no "launcher accepted a malformed placeholder (${#bad} chars)" || ok "launcher refuses a malformed placeholder (${#bad} chars)"
done
rm -f "$T/outb"; rm -rf "$T/sb/c"
env -i PATH=/usr/bin:/bin OUTF="$T/out2b" ANTHROPIC_API_KEY=openshell:resolve:env:v1_ANTHROPIC_API_KEY /bin/sh -c "$BOOT_T" "$(base64 -w0 "$T/t.tar")" "$TSHA"

# 4. reuse refused
env -i PATH=/usr/bin:/bin OUTF="$T/out3" ANTHROPIC_API_KEY=openshell:resolve:env:v1_ANTHROPIC_API_KEY /bin/sh "$T/sb/c/pkg/launch.sh" 2>/dev/null \
  && no "launcher reused existing state" || ok "launcher refuses to reuse existing state"

# 5. argv size sanity (one argv element; Linux MAX_ARG_STRLEN is 128 KiB)
n=$(base64 -w0 "$T/a.tar" | wc -c); [ "$n" -lt 100000 ] && ok "package argv element is $n bytes" || no "package argv too large ($n)"

echo "failures=$fails"; [ "$fails" = 0 ]
