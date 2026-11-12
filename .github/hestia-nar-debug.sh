#!/usr/bin/env bash
# Debug for a failed barnacle build: barnacle gets "Empty reply from server"
# from hestia's local substituter for its Linux paths (the VM disk image)
# and hestia's log shows nothing. Fetch those paths straight from hestia and
# log their size, the response, and memory and disk while hestia serves them.
# Runs on macOS's bash 3.2 (no mapfile).
set -uo pipefail

drv=$(nix eval --raw "$FLAKE#darwinConfigurations.barnacle.system.drvPath")
# outputs of the Linux derivations barnacle needs (see barnacle-linux)
paths=$(nix derivation show -r "$drv" | jq -r '
  (.derivations // .) | with_entries(.key |= ltrimstr("/nix/store/")) as $d
  | [$d[] | select(.system != "aarch64-linux")
     | (.inputs.drvs // .inputDrvs) | keys[] | ltrimstr("/nix/store/")
     | select($d[.].system == "aarch64-linux")]
  | unique[] | $d[.].outputs[].path | "/nix/store/\(ltrimstr("/nix/store/"))"')

pid=$(pgrep -f "$HESTIA_BIN serve" | head -1)
sysctl -n hw.memsize | awk '{ printf "memory: %d MiB\n", $1 / 1048576 }'
df -h /System/Volumes/Data

# store paths have no spaces
for path in $paths; do
  [ -e "$path" ] && continue
  hash=$(basename "$path" | cut -c1-32)
  echo "== $path"
  narinfo=$(curl -sS "http://$HESTIA_LISTEN/$hash.narinfo") || continue
  grep -E '^(URL|NarSize|FileSize):' <<<"$narinfo"
  url=$(sed -n 's/^URL: //p' <<<"$narinfo")
  [ -n "$url" ] || continue
  # hestia's resident memory and the system's free memory every 2 seconds
  while sleep 2; do
    echo "rss $(ps -o rss= -p "$pid" | awk '{ printf "%d MiB", $1 / 1024 }'), $(memory_pressure | tail -1)"
  done &
  sampler=$!
  curl -sS -o /dev/null -w 'http %{http_code}, %{size_download} bytes, %{time_total} s\n' \
    "http://$HESTIA_LISTEN/$url"
  kill "$sampler"
done

[ -n "$pid" ] && ps -o pid=,rss=,etime= -p "$pid" || echo "hestia is not running"
vm_stat
df -h /System/Volumes/Data
# kills by macOS's memory manager (jetsam) or crashes of hestia
log show --last 30m --style compact \
  --predicate 'eventMessage CONTAINS[c] "hestia" OR eventMessage CONTAINS[c] "jetsam"' |
  tail -30
echo "--- hestia serve log ---"
cat "$HESTIA_SERVE_LOG"
