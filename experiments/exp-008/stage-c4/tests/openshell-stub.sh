#!/usr/bin/env bash
# Stub openshell CLI for the offline C4 tests: -g <gw> <args...>; state in $SIM. No network, no credential.
# sandbox create enforces OpenShell v0.1.9's per-element limit on the sandbox command as observed in run 1127-1814
# (gRPC InvalidArgument "spec.command[N] exceeds 32768 byte limit"; an element of exactly 32768 bytes is accepted).
# sandbox get answers "sandbox not found" when $SIM/phase is "absent" (as observed in run 1127-1814) and fails with
# an unavailable error when $SIM/get-fail exists; $SIM/sbx-json, when present, replaces the default JSON.
shift 2; echo "$*" >>"$SIM/cli-calls"
case "$1 $2" in
"sandbox create")
  i=-1; seen=0
  for a in "$@"; do
    if [ "$seen" = 1 ]; then i=$((i + 1)); [ "$(printf %s "$a" | LC_ALL=C wc -c)" -le 32768 ] || {
      printf "Error:   × code: 'Client specified an invalid argument', message: \"spec.command[%s]\n  │ exceeds 32768 byte limit\"\n" "$i" >&2; exit 1; }
    elif [ "$a" = -- ]; then seen=1; fi
  done
  echo create >>"$SIM/creates"; [ -e "$SIM/create-fail-after-admit" ] && { echo Provisioning >"$SIM/phase"; echo "Error: transport closed" >&2; exit 1; }
  echo Provisioning >"$SIM/phase"; exit 0 ;;
"sandbox get") n=$(cat "$SIM/gets" 2>/dev/null || echo 0); echo $((n + 1)) >"$SIM/gets"
  [ -e "$SIM/get-fail" ] && { echo "Error:   × code: 'The service is currently unavailable', message: \"transport error\"" >&2; exit 1; }
  if [ -s "$SIM/phase-after" ] && [ $((n + 1)) -ge "$(cut -d' ' -f1 "$SIM/phase-after")" ]; then cut -d' ' -f2 "$SIM/phase-after" >"$SIM/phase"; : >"$SIM/phase-after"; fi
  [ "$(cat "$SIM/phase" 2>/dev/null)" = absent ] && { echo "Error:   × code: 'Some requested entity was not found', message: \"sandbox not found\"" >&2; exit 1; }
  if [ -e "$SIM/sbx-json" ]; then cat "$SIM/sbx-json"; else
    printf '{"id": "sid-1", "name": "%s", "labels": {"exp008.run": "%s", "exp008.stage": "c4"}, "phase": "%s"}\n' "${STUB_SBX:-exp008c4-0101-0101}" "${STUB_RUN:-0101-0101}" "$(cat "$SIM/phase")"; fi ;;
"sandbox stop") [ "$(cat "$SIM/stop-mode")" = ok ] && echo Stopped >"$SIM/phase"; [ "$(cat "$SIM/stop-mode")" = refused-stopped ] && { echo Stopped >"$SIM/phase"; exit 1; }; [ "$(cat "$SIM/stop-mode")" = fail ] && exit 1; exit 0 ;;
"sandbox start") [ "$(cat "$SIM/start-mode")" = ok ] && echo Ready >"$SIM/phase"; [ "$(cat "$SIM/start-mode")" = refused-ready ] && { echo Ready >"$SIM/phase"; exit 1; }; [ "$(cat "$SIM/start-mode")" = fail ] && exit 1; [ "$(cat "$SIM/start-mode")" = launcher-refuses ] && { echo Error >"$SIM/phase"; exit 1; }; exit 0 ;;
"sandbox delete") [ "$(cat "$SIM/phase" 2>/dev/null)" = absent ] && { echo "✓ Sandbox $3 already deleted"; exit 0; }
  echo absent >"$SIM/phase"; : >"$SIM/residue"; : >"$SIM/crs"; exit 0 ;;
"gateway list") echo exp008c ;;
*) exit 0 ;;
esac
