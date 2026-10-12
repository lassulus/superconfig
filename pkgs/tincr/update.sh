#!/usr/bin/env bash
set -euo pipefail

# Tracks our fork's integration branch (Mic92/tincr#101 + #109); switch back to
# Mic92/main once merged.
owner=Lassulus
repo=tincr
branch=lassulus/fixes
attr=tincr

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
pkg=pkgs/tincr/package.nix
system=$(nix eval --raw --impure --expr 'builtins.currentSystem')

new_rev=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$branch" | jq -r .sha)
old_rev=$(grep -oP '^\s*rev = "\K[^"]+' "$pkg")
if [ "$old_rev" = "$new_rev" ]; then
  echo "$attr: already up to date ($new_rev)"
  exit 0
fi

new_date=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$new_rev" | jq -r .commit.author.date | cut -d T -f1)
new_version="0-unstable-$new_date"

# Bump rev + version, leave hashes for nix to complain about.
# Blank both hashes too: with the old ones in place nix reuses the cached
# FODs (old src + old vendor dir) and the build "succeeds" on stale code.
sed -i \
  -e "s|^\(\s*\)rev = \".*\"|\1rev = \"$new_rev\"|" \
  -e "s|^\(\s*\)version = \".*\"|\1version = \"$new_version\"|" \
  -e "s|^\(\s*\)hash = \".*\"|\1hash = \"\"|" \
  -e "s|^\(\s*\)cargoHash = \".*\"|\1cargoHash = \"\"|" \
  "$pkg"

# Each FOD reports its own hash on first miss; build twice (src, then vendor).
extract_got() {
  awk '/got:/{print $2; exit}'
}
update_hash() {
  local field=$1 new=$2
  sed -i "s|^\(\s*\)$field = \"[^\"]*\"|\1$field = \"$new\"|" "$pkg"
}

build_attr=".#packages.$system.$attr"

# The probe build is *expected* to fail (hash mismatch); `|| true` keeps
# pipefail/errexit from turning that into an empty `got`. awk must not
# `exit` early or tee dies of SIGPIPE and takes the pipeline with it.
probe_hash() {
  { nix build --no-link "$build_attr" 2>&1 || true; } | tee /dev/stderr \
    | awk '/got:/ && !seen { print $2; seen = 1 }' || true
}

got=$(probe_hash)
if [ -n "$got" ]; then
  update_hash hash "$got"
  echo "$attr: src hash → $got"
fi

got=$(probe_hash)
if [ -n "$got" ]; then
  update_hash cargoHash "$got"
  echo "$attr: cargoHash → $got"
fi

echo "$attr: updated to $new_rev ($new_version)"
nix build --no-link "$build_attr"
