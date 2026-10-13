#!/usr/bin/env bash
set -euo pipefail

# Tracks the default branch (dev) of audibleblink/worldview.
# nix-update can't edit this flake-module.nix (no package.nix / meta.position).
owner=audibleblink
repo=worldview
attr=worldview

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
file=tools/worldview/flake-module.nix
# Depends on ungoogled-chromium, which only evaluates on Linux.
system=x86_64-linux

commit=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/HEAD")
new_rev=$(jq -r .sha <<<"$commit")
new_date=$(jq -r .commit.committer.date <<<"$commit" | cut -d T -f1)
new_version="0-unstable-$new_date"
old_rev=$(sed -n 's/^ *rev = "\([0-9a-f]*\)";/\1/p' "$file")
if [ "$old_rev" = "$new_rev" ]; then
  echo "$attr: already up to date ($new_rev)"
  exit 0
fi

# Blank the hash: with the old one nix reuses the cached FOD (old source).
sed -i \
  -e "s|^\( *\)rev = \"[0-9a-f]*\";|\1rev = \"$new_rev\";|" \
  -e "s|^\( *\)version = \"[^\"]*\";|\1version = \"$new_version\";|" \
  -e "s|^\( *\)hash = \"[^\"]*\";|\1hash = \"\";|" \
  "$file"

build_attr=".#packages.$system.$attr"

# Probe build is expected to fail with a hash mismatch.
got=$({ nix build --no-link "$build_attr" 2>&1 || true; } | tee /dev/stderr \
  | awk '/got:/ && !seen { print $2; seen = 1 }' || true)
if [ -z "$got" ]; then
  echo "$attr: failed to determine src hash" >&2
  exit 1
fi
sed -i "s|^\( *\)hash = \"\";|\1hash = \"$got\";|" "$file"

echo "$attr: updated $old_rev -> $new_rev ($new_version)"
nix build --no-link "$build_attr"
