#!/usr/bin/env bash
set -euo pipefail

# Bumps two sources together: hexgrad/kokoro (main branch, 0-unstable-DATE)
# and the en_core_web_sm wheel misaki needs. The spacy model only loads with a
# matching spacy major.minor, so it follows the newest model release for the
# spacy version in our nixpkgs.
attr=kokoro
owner=hexgrad
repo=kokoro
branch=main

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
pkg=pkgs/kokoro/package.nix
system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
build_attr=".#packages.$system.$attr"

# Line number of the n-th line matching an ERE.
line_of() {
  grep -nE "$1" "$pkg" | awk -F: -v n="${2:-1}" 'NR == n { print $1 }'
}
# Replace the quoted value on line $1.
set_value() {
  local tmp
  tmp=$(mktemp)
  awk -v l="$1" -v v="$2" 'NR == l { sub(/"[^"]*"/, "\"" v "\"") } { print }' "$pkg" >"$tmp"
  cat "$tmp" >"$pkg"
  rm -f "$tmp"
}
value_at() {
  awk -v l="$1" 'NR == l { match($0, /"[^"]*"/); print substr($0, RSTART + 1, RLENGTH - 2) }' "$pkg"
}

# Field locations: kokoro block first, spacy model block second.
kokoro_version_line=$(line_of '^[[:space:]]*version = "0-unstable-')
kokoro_rev_line=$(line_of '^[[:space:]]*rev = "')
kokoro_hash_line=$(line_of '^[[:space:]]*hash = "' 1)
model_version_line=$(line_of '^[[:space:]]*version = "[0-9]+\.[0-9]+\.[0-9]+"')
model_hash_line=$(line_of '^[[:space:]]*hash = "' 2)

old_rev=$(value_at "$kokoro_rev_line")
old_model=$(value_at "$model_version_line")

new_rev=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$branch" | jq -r .sha)

spacy_version=$(nix eval --raw "$build_attr.pythonModule.pkgs.spacy.version")
spacy_mm=$(echo "$spacy_version" | cut -d. -f1-2)
new_model=$(curl -fsSL "https://api.github.com/repos/explosion/spacy-models/releases?per_page=100" |
  jq -r --arg p "en_core_web_sm-$spacy_mm." '
    [.[] | select(.prerelease | not) | .tag_name | select(startswith($p))
     | ltrimstr("en_core_web_sm-")]
    | sort_by(split(".") | map(tonumber)) | last // empty')
if [ -z "$new_model" ]; then
  echo "$attr: no en_core_web_sm release for spacy $spacy_mm, keeping $old_model" >&2
  new_model=$old_model
fi

if [ "$old_rev" = "$new_rev" ] && [ "$old_model" = "$new_model" ]; then
  echo "$attr: already up to date ($new_rev, en_core_web_sm $new_model)"
  exit 0
fi

# Blank the hashes of whatever changed: with the old ones in place nix reuses
# the cached FODs and the build "succeeds" on stale sources.
if [ "$old_rev" != "$new_rev" ]; then
  new_date=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$new_rev" | jq -r .commit.committer.date | cut -d T -f1)
  set_value "$kokoro_rev_line" "$new_rev"
  set_value "$kokoro_version_line" "0-unstable-$new_date"
  set_value "$kokoro_hash_line" ""
fi
if [ "$old_model" != "$new_model" ]; then
  set_value "$model_version_line" "$new_model"
  set_value "$model_hash_line" ""
fi

# Probe builds are *expected* to fail (hash mismatch); `|| true` keeps
# errexit from aborting. One FOD fails per build; the two fetches are
# independent, so match the reported derivation name to pick the field.
for _ in 1 2; do
  out=$({ nix build --no-link "$build_attr" 2>&1 || true; } | tee /dev/stderr)
  got=$(echo "$out" | awk '/got:/ && !seen { print $2; seen = 1 }')
  [ -n "$got" ] || break
  if echo "$out" | grep -q 'hash mismatch in fixed-output derivation.*en_core_web_sm'; then
    set_value "$model_hash_line" "$got"
    echo "$attr: en_core_web_sm hash → $got"
  else
    set_value "$kokoro_hash_line" "$got"
    echo "$attr: src hash → $got"
  fi
done

echo "$attr: updated to $new_rev, en_core_web_sm $new_model"
nix build --no-link "$build_attr"
