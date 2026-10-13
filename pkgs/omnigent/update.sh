#!/usr/bin/env bash
set -euo pipefail

# omnigent, omnigent-client and omnigent-ui-sdk are released in lockstep and
# all three are fetched as py3 wheels in package.nix; nix-update only bumps
# the top-level src, so bump all of them here.
attr=omnigent

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
pkg=pkgs/omnigent/package.nix
system=$(nix eval --raw --impure --expr 'builtins.currentSystem')

new_version=$(curl -fsSL https://pypi.org/pypi/omnigent/json | jq -r .info.version)
old_version=$(sed -n 's|^  version = "\([^"]*\)";|\1|p' "$pkg")
if [ "$old_version" = "$new_version" ]; then
  echo "$attr: already up to date ($new_version)"
  exit 0
fi

# Hash of the py3-none-any wheel as published on PyPI, in SRI form.
wheel_hash() {
  local project=$1 hex
  hex=$(curl -fsSL "https://pypi.org/pypi/$project/$new_version/json" |
    jq -r '.urls[] | select(.packagetype == "bdist_wheel" and (.filename | endswith("-py3-none-any.whl"))) | .digests.sha256')
  if [ -z "$hex" ]; then
    echo "$attr: no py3-none-any wheel for $project $new_version" >&2
    exit 1
  fi
  nix hash convert --hash-algo sha256 --to sri "$hex"
}

# Replace the `hash = ...` that follows `pname = "<pname>"` (blanking first so
# nothing ever builds against a stale cached FOD).
set_hash() {
  local pname=$1 hash=$2
  sed -i "/pname = \"$pname\";/,/hash = /s|^\(\s*\)hash = \"[^\"]*\"|\1hash = \"$hash\"|" "$pkg"
}

client_hash=$(wheel_hash omnigent-client)
ui_sdk_hash=$(wheel_hash omnigent-ui-sdk)
app_hash=$(wheel_hash omnigent)

sed -i \
  -e "s|^\(\s*\)version = \"$old_version\";|\1version = \"$new_version\";|" \
  -e "s|^\(\s*\)hash = \".*\"|\1hash = \"\"|" \
  "$pkg"

set_hash omnigent_client "$client_hash"
set_hash omnigent_ui_sdk "$ui_sdk_hash"
set_hash omnigent "$app_hash"

if grep -q 'hash = ""' "$pkg"; then
  echo "$attr: failed to fill in every hash" >&2
  exit 1
fi

echo "$attr: updated $old_version → $new_version"
nix build --no-link ".#packages.$system.$attr"
