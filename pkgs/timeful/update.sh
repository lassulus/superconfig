#!/usr/bin/env bash
set -euo pipefail

# Three hashes move together (src, frontend npmDepsHash, server vendorHash),
# and src is wrapped in applyPatches, so nix-update can't do this one.
owner=schej-it
repo=timeful.app
branch=main
attr=timeful

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
pkg=pkgs/timeful/package.nix
# Linux-only package: always evaluate/build the x86_64-linux variant.
build_attr=".#packages.x86_64-linux.$attr"

new_rev=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$branch" | jq -r .sha)
old_rev=$(sed -n 's|^ *rev = "\([^"]*\)";|\1|p' "$pkg")
if [ "$old_rev" = "$new_rev" ]; then
  echo "$attr: already up to date ($new_rev)"
  exit 0
fi

new_date=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$new_rev" | jq -r .commit.committer.date | cut -d T -f1)
new_version="0-unstable-$new_date"

# Portable in-place sed (BSD and GNU).
edit() {
  local tmp
  tmp=$(mktemp)
  sed "$@" "$pkg" >"$tmp"
  cat "$tmp" >"$pkg"
  rm -f "$tmp"
}

# Bump rev + version and blank every hash: with the old ones in place nix
# reuses the cached FODs and the build "succeeds" on stale code.
edit \
  -e "s|^\( *\)rev = \".*\";|\1rev = \"$new_rev\";|" \
  -e "s|^\( *\)version = \".*\";|\1version = \"$new_version\";|" \
  -e "s|^\( *\)hash = \".*\";|\1hash = \"\";|" \
  -e "s|^\( *\)npmDepsHash = \".*\";|\1npmDepsHash = \"\";|" \
  -e "s|^\( *\)vendorHash = \".*\";|\1vendorHash = \"\";|"

update_hash() {
  local field=$1 new=$2
  edit -e "s|^\( *\)$field = \"[^\"]*\";|\1$field = \"$new\";|"
}

# The probe build is *expected* to fail (hash mismatch); `|| true` keeps
# pipefail/errexit from turning that into an empty `got`. awk must not
# `exit` early or tee dies of SIGPIPE and takes the pipeline with it.
probe_hash() {
  { nix build --no-link "$build_attr$1" 2>&1 || true; } | tee /dev/stderr \
    | awk '/got:/ && !seen { print $2; seen = 1 }' || true
}

# Probe each FOD on its own so a hash is never attributed to the wrong field.
for spec in hash:.src npmDepsHash:.frontend.npmDeps vendorHash:.goModules; do
  field=${spec%%:*}
  sub=${spec#*:}
  got=$(probe_hash "$sub")
  if [ -z "$got" ]; then
    echo "$attr: no hash reported for $field" >&2
    exit 1
  fi
  update_hash "$field" "$got"
  echo "$attr: $field → $got"
done

echo "$attr: updated to $new_rev ($new_version)"
nix build --no-link "$build_attr"
