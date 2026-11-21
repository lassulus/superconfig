#!/usr/bin/env bash
set -euo pipefail

# continuum lives on cgit (no API nix-update knows) and has no Cargo.lock:
# bump to master and generate the lock for that rev with our patches.
url=https://cgit.krebsco.de/continuum
attr=continuum

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
dir=pkgs/continuum
pkg=$dir/package.nix
system=$(nix eval --raw --impure --expr 'builtins.currentSystem')

new_rev=$(git ls-remote "$url" refs/heads/master | cut -f1)
old_rev=$(sed -n 's/^ *rev = "\([^"]*\)".*/\1/p' "$pkg")
if [ "$old_rev" = "$new_rev" ]; then
  echo "$attr: already up to date ($new_rev)"
  exit 0
fi

src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
git -C "$src" init -q
git -C "$src" fetch -q --depth 1 "$url" "$new_rev"
git -C "$src" checkout -q FETCH_HEAD
# the lock covers what our patches (if any) add to Cargo.toml
shopt -s nullglob
for p in "$dir"/*.patch; do git -C "$src" apply "$PWD/$p"; done
shopt -u nullglob
new_date=$(git -C "$src" log -1 --format=%cs)
nix shell nixpkgs#cargo -c cargo generate-lockfile --manifest-path "$src/Cargo.toml"
cp "$src/Cargo.lock" "$dir/Cargo.lock"

# Blank the src hash (the first one) too: with the old one in place nix
# reuses the cached FOD.
sed -i \
  -e "s|^\( *\)rev = \".*\"|\1rev = \"$new_rev\"|" \
  -e "s|^\( *\)version = \".*\"|\1version = \"1.0.0-unstable-$new_date\"|" \
  -e "0,/^ *hash = \".*\"/s/^\( *\)hash = \".*\"/\1hash = \"\"/" \
  "$pkg"

# The probe build is *expected* to fail with a hash mismatch; awk must not
# exit early or tee dies of SIGPIPE.
got=$({ nix build --no-link ".#packages.$system.$attr" 2>&1 || true; } | tee /dev/stderr |
  awk '/got:/ && !seen { print $2; seen = 1 }' || true)
if [ -n "$got" ]; then
  sed -i "0,/^ *hash = \"\"/s|^\( *\)hash = \"\"|\1hash = \"$got\"|" "$pkg"
  echo "$attr: src hash -> $got"
fi

nix build --no-link ".#packages.$system.$attr"
echo "$attr: $old_rev -> $new_rev"
