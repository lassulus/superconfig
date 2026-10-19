#!/usr/bin/env bash
set -euo pipefail

# Tangled has no releases for the knot-rs era and isn't on GitHub, so
# nix-update can't follow it: bump src to the head of master, take the
# frontend assets (the flake's *-src inputs) from its flake.lock and probe the
# Go vendor and cargo hashes.
attr=tangled
url=https://tangled.org/tangled.org/core

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
dir=pkgs/tangled
pkg=$dir/package.nix
# Linux-only package: always evaluate/build the x86_64-linux variant.
build_attr=".#packages.x86_64-linux.$attr"

new_rev=$(git ls-remote "$url" refs/heads/master | cut -f1)
old_rev=$(sed -n 's|^ *rev = "\([^"]*\)";|\1|p' "$pkg")
if [ "$old_rev" = "$new_rev" ]; then
  echo "$attr: already up to date ($new_rev)"
  exit 0
fi

# The flake fetcher's narHash is fetchgit's hash, and its store path has the
# flake.lock with the asset pins.
prefetch=$(nix flake prefetch --json "git+$url?rev=$new_rev")
src_hash=$(jq -r .hash <<<"$prefetch")
src_path=$(jq -r .storePath <<<"$prefetch")
new_date=$(date -u -d "@$(jq -r .locked.lastModified <<<"$prefetch")" +%F)
new_version="0-unstable-$new_date"

jq '.nodes as $n
  | [.nodes.root.inputs | to_entries[] | select(.key | endswith("-src"))
     | { key, value: ($n[.value].locked
         | { type, url } + (if .rev then { rev } else {} end) + { hash: .narHash }) }]
  | sort_by(.key) | from_entries' "$src_path/flake.lock" >"$dir/assets.json"

# Bump rev + version and blank the derived hashes: with the old ones in place
# nix reuses the cached FODs and the build "succeeds" on stale code.
sed -i \
  -e "s|^\( *\)rev = \".*\";|\1rev = \"$new_rev\";|" \
  -e "s|^\( *\)version = \".*\";|\1version = \"$new_version\";|" \
  -e "s|^\( *\)hash = \"sha256-.*\";|\1hash = \"$src_hash\";|" \
  -e "s|^\( *\)vendorHash = \".*\";|\1vendorHash = \"\";|" \
  -e "s|^\( *\)cargoHash = \".*\";|\1cargoHash = \"\";|" \
  "$pkg"

# The probe build is *expected* to fail (hash mismatch); `|| true` keeps
# pipefail/errexit from turning that into an empty `got`. awk must not
# `exit` early or tee dies of SIGPIPE and takes the pipeline with it.
probe_hash() {
  { nix build --no-link "$build_attr$1" 2>&1 || true; } | tee /dev/stderr |
    awk '/got:/ && !seen { print $2; seen = 1 }' || true
}

# Probe each FOD on its own so a hash is never attributed to the wrong field.
for spec in vendorHash:.appview.goModules cargoHash:.knot-rs.cargoDeps; do
  field=${spec%%:*}
  got=$(probe_hash "${spec#*:}")
  if [ -z "$got" ]; then
    echo "$attr: no hash reported for $field" >&2
    exit 1
  fi
  sed -i "s|^\( *\)$field = \"[^\"]*\";|\1$field = \"$got\";|" "$pkg"
  echo "$attr: $field → $got"
done

echo "$attr: updated to $new_rev ($new_version)"
nix build --no-link "$build_attr"
