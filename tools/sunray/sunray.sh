#!/usr/bin/env bash
set -euo pipefail

# sunray <host> [app]: stream a host's desktop to Moonlight. The host runs
# Sunshine permanently (configs/sunray.nix); ssh is only used to approve the
# pairing, so a client that can ssh in gets paired once and then streams
# directly.
if [ $# -lt 1 ] || [ "$1" = -h ] || [ "$1" = --help ]; then
  echo "usage: sunray <host> [app]" >&2
  exit 1
fi
host=$1
app=${2:-Desktop}
# the address behind ssh config aliases, which Moonlight connects to
target=$(ssh -G "$host" | awk '$1 == "hostname" { print $2 }')

if ! moonlight list "$target" >/dev/null 2>&1; then
  pin=$(printf '%04d' $((SRANDOM % 10000)))
  moonlight pair "$target" --pin "$pin" >/dev/null 2>&1 &
  pair=$!
  # shellcheck disable=SC2029 # pin and name are meant for the host
  ssh "$host" sunray-pin "$pin" "$HOSTNAME" &
  approve=$!
  status=0
  wait -n -p first "$pair" "$approve" || status=$?
  if [ "$first" = "$pair" ]; then
    kill "$approve"
    echo "sunray: moonlight pair exited before the host approved it" >&2
    exit 1
  fi
  if [ "$status" != 0 ]; then
    kill "$pair"
    exit "$status"
  fi
  # moonlight pair finishes the handshake after the host approved it, then
  # keeps running; stop it once the pairing is stored
  until moonlight list "$target" >/dev/null 2>&1; do
    sleep 1
  done
  kill "$pair"
fi

exec moonlight stream "$target" "$app"
