#!/usr/bin/env bash
set -euo pipefail

# Bumps photocraft to the latest GitHub release and keeps the bundled
# wasm-bindgen-cli in lockstep with the wasm-bindgen version in Cargo.lock
# (trunk refuses mismatched versions), so nix-update alone is not enough.
owner=storytold
repo=photocraft
attr=photocraft-web

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
pkg=pkgs/photocraft-web/package.nix
system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
flake_attr=".#packages.$system.$attr"

tag=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/releases/latest" | jq -r .tag_name)
new_version=${tag#v}
old_version=$(nix eval --raw "$flake_attr.version")

new_wb=$(curl -fsSL "https://raw.githubusercontent.com/$owner/$repo/$tag/Cargo.lock" \
  | awk '/^name = "wasm-bindgen"$/ && !seen { getline; gsub(/version = |"/, ""); print; seen = 1 }')
old_wb=$(nix eval --raw "$flake_attr.wasm-bindgen-cli.version")
if [ -z "$new_wb" ]; then
  echo "$attr: could not find wasm-bindgen in Cargo.lock of $tag" >&2
  exit 1
fi

if [ "$old_version" = "$new_version" ] && [ "$old_wb" = "$new_wb" ]; then
  echo "$attr: already up to date ($new_version, wasm-bindgen $new_wb)"
  exit 0
fi

# Blank every hash we bump, otherwise nix reuses the cached old FODs.
sed -i \
  -e "/pname = \"$attr\"/,/version = /s|version = \"[^\"]*\"|version = \"$new_version\"|" \
  -e "/repo = \"$repo\"/,/hash = /s|hash = \"[^\"]*\"|hash = \"\"|" \
  -e "s|cargoHash = \"[^\"]*\"|cargoHash = \"\"|" \
  "$pkg"
if [ "$old_wb" != "$new_wb" ]; then
  sed -i \
    -e "/pname = \"wasm-bindgen-cli\"/,/hash = /s|version = \"[^\"]*\"|version = \"$new_wb\"|" \
    -e "/pname = \"wasm-bindgen-cli\"/,/hash = /s|hash = \"[^\"]*\"|hash = \"\"|" \
    -e "/fetchCargoVendor/,/hash = /s|hash = \"[^\"]*\"|hash = \"\"|" \
    "$pkg"
fi

# The probe build is *expected* to fail (hash mismatch); `|| true` keeps
# pipefail/errexit from turning that into an empty `got`.
probe_hash() {
  { nix build --no-link "$flake_attr.$1" 2>&1 || true; } | tee /dev/stderr \
    | awk '/got:/ && !seen { print $2; seen = 1 }' || true
}

# fill <sub-attr> <sed address range start> <field>
fill() {
  local got
  got=$(probe_hash "$1")
  if [ -n "$got" ]; then
    sed -i "$2,/$3 = /s|$3 = \"[^\"]*\"|$3 = \"$got\"|" "$pkg"
    echo "$attr: $1 → $got"
  fi
}

if [ "$old_wb" != "$new_wb" ]; then
  fill wasm-bindgen-cli.src '/pname = "wasm-bindgen-cli"/' hash
  fill wasm-bindgen-cli.cargoDeps '/fetchCargoVendor/' hash
fi
fill src "/repo = \"$repo\"/" hash
fill cargoDeps '/cargoHash/' cargoHash

echo "$attr: updated $old_version → $new_version (wasm-bindgen $old_wb → $new_wb)"
nix build --no-link "$flake_attr"
