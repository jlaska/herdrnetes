#!/usr/bin/env bash
# EXP-008 Stage C: OWNER-RUN ONLY, in the owner's own terminal, after the execution package is approved.
# Agents never run this file (it handles the dedicated API key).
#
#   owner-provider.sh setup            create ~/.cache/hxc (0700), copy the verified CLI, write site.env and login-c.sh
#   owner-provider.sh login            interactive OIDC login of the isolated CLI registration exp008c
#   owner-provider.sh list             names only: providers and profiles on the gateway (run before and after)
#   owner-provider.sh profile-import   lint + import ../task/profile-claude-code-exp008c.yaml (default workspace)
#   owner-provider.sh create           read the key with `read -rs` and create provider exp008c-anthropic
#   owner-provider.sh delete           delete provider exp008c-anthropic, then profile claude-code-exp008c
#
# Key handling (proposal 5.1 MUST-2): the key is typed/pasted at a hidden prompt, held in one shell variable,
# exported only inside a subshell whose environment has been cleared, and read by the CLI from its own
# environment (`--credential ANTHROPIC_API_KEY`, bare-key form). It is never in any argv, file or history.
# While that one CLI process runs, the same UID can read its /proc/<pid>/environ (FIND-055 boundary).
set -euo pipefail
HX=$HOME/.cache/hxc
CLI=$HX/bin/openshell
CLI_SHA=2db8e54f63feebe9f994efaf6004bbd45c55bc70ea455eda42fe82a0ea7c7e69
GW=exp008c PROV=exp008c-anthropic PROF=claude-code-exp008c
HERE=$(cd "$(dirname "$(realpath "$0")")/.." && pwd)
clean_cli() { # run the isolated CLI with a cleared environment; extra NAME=VALUE pairs are exported by the caller
  ( for v in $(compgen -e); do [ "$v" = ANTHROPIC_API_KEY ] && [ "${KEEP_KEY:-}" = 1 ] && continue; unset "$v"; done
    export HOME="$HX/home" XDG_CONFIG_HOME="$HX/home/.config" XDG_DATA_HOME="$HX/home/.local/share" \
      XDG_STATE_HOME="$HX/home/.local/state" XDG_CACHE_HOME="$HX/home/.cache" PATH=/usr/bin:/bin TERM=xterm-256color
    exec "$CLI" -g "$GW" "$@" )
}
case ${1:-} in
setup)
  umask 077; mkdir -p "$HX/bin" "$HX/home" "$HX/run"; chmod 700 "$HX" "$HX/run"
  [ -x "$HX/bin/openshell" ] || cp "$HOME/.cache/hxb/bin/openshell" "$HX/bin/openshell"
  [ "$(sha256sum "$CLI" | cut -d' ' -f1)" = "$CLI_SHA" ] || { echo "CLI sha256 mismatch" >&2; exit 1; }
  if [ ! -e "$HX/site.env" ]; then
    grep -E '^(CTX|ARGO_APP_GW|ARGO_APP_AS|GITOPS_REPO)=' "$HOME/.cache/hxb/site.env" >"$HX/site.env"
    printf 'PROV=%s\nBUDGET_USD=%s\n' "$PROV" "${BUDGET_USD:-2}" >>"$HX/site.env"
  fi
  if ! grep -q '^PIN_KUBE_SYSTEM_UID=' "$HX/site.env"; then
    # independent identity pins: Stage B run 3's recorded references (a wrong kube context cannot become the baseline)
    B=$HOME/.cache/hxb/run/1124-2222/e/refs.txt
    for k in kube_system_uid gw_sts_uid gw_pvc_uid; do
      v=$(sed -n "s/^$k=//p" "$B"); [ -n "$v" ] || { echo "missing $k in $B" >&2; exit 1; }
      printf 'PIN_%s=%s\n' "$(tr a-z A-Z <<<"$k")" "$v" >>"$HX/site.env"
    done
  fi
  # login-c.sh: the Stage B login script with the registration name and isolated HOME switched to exp008c/hxc
  sed -e 's/exp008b/exp008c/g' -e 's#\.cache/hxb#.cache/hxc#g' "$HOME/.cache/hxb/login.sh" >"$HX/login-c.sh"
  sed -e 's#\.cache/hxb#.cache/hxc#g' "$HOME/.cache/hxb/os" >"$HX/os"; chmod 700 "$HX/login-c.sh" "$HX/os"
  echo "setup done: $HX. Review $HX/site.env and $HX/login-c.sh. Add the cluster, node and gateway host names to $HX/redact.txt (one per line) so export.sh redacts and refuses them."
  ;;
login) exec "$HX/login-c.sh" ;;
list) echo "## providers"; clean_cli provider list --names; echo "## profiles"; clean_cli profile list ;;
profile-import)
  clean_cli provider profile lint -f "$HERE/task/profile-claude-code-exp008c.yaml"
  clean_cli provider profile import -f "$HERE/task/profile-claude-code-exp008c.yaml"
  ;;
create)
  IFS= read -r -s -p "Paste the dedicated EXP-008 Stage C API key (input hidden): " K; echo
  [[ $K =~ ^sk-ant-[A-Za-z0-9_-]{20,}$ ]] || { unset K; echo "does not look like an Anthropic API key; nothing done" >&2; exit 1; }
  ( export ANTHROPIC_API_KEY="$K"; unset K; KEEP_KEY=1
    clean_cli provider create --name "$PROV" --type "$PROF" --credential ANTHROPIC_API_KEY ) || { unset K; exit 1; }
  unset K; echo "provider $PROV created (value not shown)"
  ;;
delete)
  clean_cli provider delete "$PROV" || echo "provider delete failed (record it)"
  clean_cli profile delete "$PROF" || echo "profile delete failed (record it; a sandbox-attached provider blocks it)"
  ;;
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
