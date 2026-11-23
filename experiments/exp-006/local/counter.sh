#!/usr/bin/env bash
# EXP-006 synthetic "agent": proves process identity across client/Herdr churn.
#   counter.sh <outdir>
# Writes <outdir>/identity (pid, /proc stat starttime, nonce) once at start,
# prints "tick n=<N>" about once per second and logs it with a timestamp to
# <outdir>/counter.log. Input line "mark <word>" prints and logs an ACK line.
set -u
out=${1:?usage: counter.sh <outdir>}
mkdir -p "$out"
pid=$$
# /proc/<pid>/stat field 22 (starttime); strip "pid (comm) " first so a comm
# containing spaces cannot shift the fields (state is then field 3).
start=$(sed 's/.*) //' "/proc/$pid/stat" | awk '{print $20}')
nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
printf 'pid=%s\nstart=%s\nnonce=%s\n' "$pid" "$start" "$nonce" >"$out/identity.tmp"
mv "$out/identity.tmp" "$out/identity"

log() { printf '%s %(%FT%T)T %s\n' "$EPOCHREALTIME" -1 "$*" >>"$out/counter.log"; }

n=0
buf=
while :; do
  n=$((n + 1))
  echo "tick n=$n"
  log "COUNT n=$n"
  # Waits up to 1 s: this is also the tick interval when nobody types.
  read -r -t 1 chunk
  rc=$?
  buf+=${chunk-}
  if [ "$rc" -eq 0 ]; then
    line=$buf
    buf=
    case $line in
    "mark "*)
      word=${line#mark }
      msg="ACK $word pid=$pid start=$start nonce=$nonce n=$n"
      echo "$msg"
      log "$msg"
      ;;
    esac
  fi
done
