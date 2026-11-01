#!/usr/bin/env bash
set -euo pipefail

# tg isn't released on a forge nix-update can follow: bump src to the head of
# main on tangled.org and probe the Go vendor hash.
attr=tg
url=https://tangled.org/aly.codes/tg

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
pkg=pkgs/tg/package.nix
build_attr=".#packages.x86_64-linux.$attr"

new_rev=$(git ls-remote "$url" HEAD | cut -f1)
old_rev=$(sed -n 's|^ *rev = "\([^"]*\)";|\1|p' "$pkg")
if [ "$old_rev" = "$new_rev" ]; then
  echo "$attr: already up to date ($new_rev)"
  exit 0
fi

prefetch=$(nix flake prefetch --json "git+$url?rev=$new_rev")
src_hash=$(jq -r .hash <<<"$prefetch")
new_date=$(date -u -d "@$(jq -r .locked.lastModified <<<"$prefetch")" +%F)

# Blank the vendor hash: with the old one in place nix reuses the cached FOD
# and the build "succeeds" on stale modules.
sed -i \
  -e "s|^\( *\)rev = \".*\";|\1rev = \"$new_rev\";|" \
  -e "s|^\( *\)version = \".*\";|\1version = \"0-unstable-$new_date\";|" \
  -e "s|^\( *\)hash = \".*\";|\1hash = \"$src_hash\";|" \
  -e "s|^\( *\)vendorHash = \".*\";|\1vendorHash = \"\";|" \
  "$pkg"

# The probe build is *expected* to fail (hash mismatch); `|| true` keeps
# pipefail/errexit from turning that into an empty `got`.
got=$({ nix build --no-link "$build_attr.goModules" 2>&1 || true; } | tee /dev/stderr |
  awk '/got:/ && !seen { print $2; seen = 1 }' || true)
if [ -z "$got" ]; then
  echo "$attr: no hash reported for vendorHash" >&2
  exit 1
fi
sed -i "s|^\( *\)vendorHash = \"[^\"]*\";|\1vendorHash = \"$got\";|" "$pkg"

echo "$attr: updated to $new_rev"
nix build --no-link "$build_attr"
