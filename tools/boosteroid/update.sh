#!/usr/bin/env bash
set -euo pipefail

url="https://boosteroid.com/linux/installer/boosteroid_portable.tar"
# Run by update-pkgs from the flake root ($0 is a read-only store copy).
pkg=tools/boosteroid/package.nix

old_hash=$(grep -oP 'hash = "\K[^"]+' "$pkg")

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

curl -fsSL -A "Mozilla/5.0" -o "$tmpfile" "$url"
new_hash=$(nix hash file --sri "$tmpfile")

if [ "$old_hash" = "$new_hash" ]; then
  echo "boosteroid: already up to date ($old_hash)"
  exit 0
fi

echo "boosteroid: updating hash"
echo "  old: $old_hash"
echo "  new: $new_hash"
sed -i "s|$old_hash|$new_hash|" "$pkg"
