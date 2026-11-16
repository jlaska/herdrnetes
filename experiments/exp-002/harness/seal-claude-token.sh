#!/usr/bin/env bash
# Seal an owner-generated Claude Code token (`claude setup-token`) for the
# experiment namespace, without echoing it or writing it to disk in clear text.
# Run this yourself in a terminal; do not paste the token into an agent session.
#
#   seal-claude-token.sh <sealed-secrets-cert.pem> <output.sealed.yaml>
set -euo pipefail
cert=${1:?sealed-secrets public cert} out=${2:?output file}
# shellcheck disable=SC2016 # literal backticks in the prompt
read -rsp 'Paste the token from `claude setup-token` (input hidden): ' token
echo
[ -n "$token" ] || { echo "empty token" >&2; exit 1; }
printf '%s' "$token" |
  kubectl create secret generic herdr-claude-token -n herdrnetes-exp \
    --from-file=CLAUDE_CODE_OAUTH_TOKEN=/dev/stdin --dry-run=client -o yaml |
  kubeseal --cert "$cert" --format yaml >"$out"
unset token
echo "wrote $out ($(wc -c <"$out") bytes, encrypted for namespace herdrnetes-exp)"
