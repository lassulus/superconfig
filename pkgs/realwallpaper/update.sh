#!/usr/bin/env bash
set -euo pipefail

# realwallpaper has no version of its own; it pins two upstream GitHub assets
# by commit. Bump each to the head of its default branch and refresh its hash.
# Run by update-pkgs from the flake root ($0 is a read-only store copy).
attr=realwallpaper
dir=pkgs/realwallpaper
system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
build_attr=".#packages.$system.$attr"

# file | owner/repo | branch | URL prefix up to (and excluding) the 40-char rev
assets=(
  "$dir/grib2json.nix|krebs/grib2json-bin|master|https://github.com/krebs/grib2json-bin/archive/"
  "$dir/package.nix|ofrohn/d3-celestial|master|https://raw.githubusercontent.com/ofrohn/d3-celestial/"
)

# The probe build is *expected* to fail (hash mismatch); `|| true` keeps
# pipefail/errexit from turning that into an empty `got`. awk must not
# `exit` early or tee dies of SIGPIPE and takes the pipeline with it.
probe_hash() {
  { nix build --no-link "$build_attr" 2>&1 || true; } | tee /dev/stderr \
    | awk '/got:/ && !seen { print $2; seen = 1 }' || true
}

changed=0
for asset in "${assets[@]}"; do
  IFS='|' read -r file repo branch prefix <<<"$asset"
  prefix_re=${prefix//./\\.}

  old_rev=$(grep -oE "${prefix_re}[0-9a-f]{40}" "$file" | sed "s|^${prefix_re}||")
  new_rev=$(curl -fsSL "https://api.github.com/repos/$repo/commits/$branch" | jq -r .sha)
  if [ -z "$old_rev" ] || [ -z "$new_rev" ] || [ "$new_rev" = null ]; then
    echo "$attr: could not determine revisions for $repo (old='$old_rev' new='$new_rev')" >&2
    exit 1
  fi
  if [ "$old_rev" = "$new_rev" ]; then
    echo "$attr: $repo already at $new_rev"
    continue
  fi

  # Bump the rev and blank the hash that follows the URL: with the old hash in
  # place nix would reuse the cached FOD and "succeed" on stale content.
  sed -i \
    -e "s|${prefix_re}${old_rev}|${prefix}${new_rev}|" \
    -e "\|${prefix_re}${new_rev}|,\|hash = |s|hash = \"[^\"]*\"|hash = \"\"|" \
    "$file"

  # Only this asset's hash is blank, so the first mismatch belongs to it.
  got=$(probe_hash)
  if [ -z "$got" ]; then
    echo "$attr: no hash mismatch reported for $repo" >&2
    exit 1
  fi
  sed -i "\|${prefix_re}${new_rev}|,\|hash = |s|hash = \"\"|hash = \"$got\"|" "$file"
  echo "$attr: $repo $old_rev → $new_rev ($got)"
  changed=1
done

if [ "$changed" = 0 ]; then
  echo "$attr: already up to date"
  exit 0
fi

nix build --no-link "$build_attr"
