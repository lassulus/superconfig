#!/usr/bin/env bash
set -euo pipefail

# Tangled has no releases for the knot-rs era and isn't on GitHub, so
# nix-update can't follow it: bump src to the head of master and probe the
# cargo hash.
attr=tangled
url=https://tangled.org/tangled.org/core

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
pkg=pkgs/tangled/package.nix
# Linux-only package: always evaluate/build the x86_64-linux variant.
build_attr=".#packages.x86_64-linux.$attr"

new_rev=$(git ls-remote "$url" refs/heads/master | cut -f1)
old_rev=$(sed -n 's|^ *rev = "\([^"]*\)";|\1|p' "$pkg")
if [ "$old_rev" = "$new_rev" ]; then
  echo "$attr: already up to date ($new_rev)"
  exit 0
fi

# The flake fetcher's narHash is fetchgit's hash.
prefetch=$(nix flake prefetch --json "git+$url?rev=$new_rev")
src_hash=$(jq -r .hash <<<"$prefetch")
new_date=$(date -u -d "@$(jq -r .locked.lastModified <<<"$prefetch")" +%F)

# Bump rev + version and blank the cargo hash: with the old one in place nix
# reuses the cached FOD and the build "succeeds" on stale code.
sed -i \
  -e "s|^\( *\)rev = \".*\";|\1rev = \"$new_rev\";|" \
  -e "s|^\( *\)version = \".*\";|\1version = \"0-unstable-$new_date\";|" \
  -e "s|^\( *\)hash = \".*\";|\1hash = \"$src_hash\";|" \
  -e "s|^\( *\)cargoHash = \".*\";|\1cargoHash = \"\";|" \
  "$pkg"

# The probe build is *expected* to fail (hash mismatch); `|| true` keeps
# pipefail/errexit from turning that into an empty `got`. awk must not
# `exit` early or tee dies of SIGPIPE and takes the pipeline with it.
got=$({ nix build --no-link "$build_attr.cargoDeps" 2>&1 || true; } | tee /dev/stderr |
  awk '/got:/ && !seen { print $2; seen = 1 }' || true)
if [ -z "$got" ]; then
  echo "$attr: no hash reported for cargoHash" >&2
  exit 1
fi
sed -i "s|^\( *\)cargoHash = \"[^\"]*\";|\1cargoHash = \"$got\";|" "$pkg"

echo "$attr: updated to $new_rev"
nix build --no-link "$build_attr"
