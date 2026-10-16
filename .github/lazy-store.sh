#!/usr/bin/env bash
# Mounts a lazy /nix/store for building INSTALLABLE... (the machine jobs of
# ci.yml): every store path the build would substitute from cache.nixos.org
# or cache.lassul.us is registered as valid from its narinfo and served by
# lazy-store (tools/lazy-store), which downloads a path's NAR only when a
# file in it is opened first. What nix builds, and what neither cache has,
# is built or substituted (also from hestia) as usual; writes go to the
# real store dir below the mount.
#
# Needs sudo, /dev/fuse and LAZY_STORE, the lazy-store package's out path
# (substitutable). If anything fails before the paths are registered, the
# mount is undone and the build substitutes eagerly: this script always
# exits 0. The FUSE log ends up in $RUNNER_TEMP/lazy-store/fuse.log.
# Usage: lazy-store.sh INSTALLABLE...
set -euo pipefail
L=$RUNNER_TEMP/lazy-store
mkdir -p "$L"

fallback() {
  set +e
  echo "::error::lazy store: $1; the build substitutes eagerly instead"
  if [ -s "$L/fuse.log" ]; then
    tail -n 50 "$L/fuse.log"
  fi
  if mountpoint -q /nix/store; then
    sudo umount /nix/store || sudo umount -l /nix/store
  fi
  if mountpoint -q /lazy/nix; then
    sudo umount -l /lazy/nix
  fi
  exit 0
}
trap 'fallback "line $LINENO failed"' ERR

nix-store --realise "$LAZY_STORE" >/dev/null || fallback "cannot get $LAZY_STORE"
lazy=$LAZY_STORE/bin/lazy-store
nixbin=$(dirname "$(readlink -f "$(command -v nix-store)")")

nix build --dry-run "$@" 2>"$L/plan" || fallback "nix build --dry-run failed: $(cat "$L/plan")"
# the path lines below the "will be fetched" header, up to the next header
awk '/^[^ ]/ { f = /will be fetched/; next } f && $1 ~ /^\/nix\/store\// { print $1 }' \
  "$L/plan" >"$L/fetch"
if [ ! -s "$L/fetch" ]; then
  echo "lazy store: nothing to substitute"
  exit 0
fi

"$lazy" closure "$L" <"$L/fetch" >/dev/null || fallback "closure failed"
jq -r '"lazy store: \(.paths) of the \(.roots) paths to substitute and their closure (\(.file_size / 1048576 | floor) MiB to download eagerly); \(.missing | length) not in the caches, \(.incomplete) referring to those"' \
  "$L/closure.json"
n=$(jq length "$L/paths.json")
if [ "$n" = 0 ]; then
  exit 0
fi

sudo modprobe fuse || true
# The upper layer is the real store dir, reached through a private bind
# mount of /nix, so that the mount on /nix/store doesn't show up there.
sudo mkdir -p /lazy/nix
sudo mount --bind /nix /lazy/nix || fallback "bind mount of /nix failed"
sudo mount --make-private /lazy/nix || fallback "making /lazy/nix private failed"
# shellcheck disable=SC2024 # the log is ours, only the mount needs root
sudo "$lazy" mount "$L" /lazy/nix/store /nix/store >"$L/fuse.log" 2>&1 &
fuse=$!
# sudo runs as root (no kill -0) and stays a zombie until waited for
fuse_alive() {
  local s
  s=$(ps -o stat= -p "$fuse") && [[ $s != Z* ]]
}
# it fetches all .ls listings before mounting
until mountpoint -q /nix/store; do
  fuse_alive || fallback "lazy-store exited before mounting /nix/store"
  sleep 1
done
grep -m1 '^init: ' "$L/fuse.log" || true

some=$(jq -r 'keys[0]' "$L/paths.json")
[ -e "/nix/store/$some" ] || fallback "/nix/store/$some is not served"
# shellcheck disable=SC2024 # db.dump is ours, only nix-store needs root
sudo "$nixbin/nix-store" --load-db <"$L/db.dump" || fallback "registering the paths failed"
# registered: the mount has to stay
trap - ERR
set +e
echo "lazy store: mounted on /nix/store, $n paths registered"
# niks3 and hestia leave out what cache.nixos.org signed by the signatures
# in nix's database; without them they would upload (and so download)
# those paths
jq -r 'keys[] | "/nix/store/" + .' "$L/paths.json" |
  sudo "$nixbin/nix" --extra-experimental-features nix-command \
    store copy-sigs -s "file://$L/narinfo" --stdin ||
  echo "::warning::lazy store: copying the signatures failed, uploads may download paths of cache.nixos.org"
