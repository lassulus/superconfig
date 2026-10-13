#!/usr/bin/env bash
set -euo pipefail

# Upstream publishes a different set of platform wheels per release (no macOS
# wheel since 0.3.45), so each platform in wheels.json tracks the newest PyPI
# release that still ships its wheel tag. Hashes come from PyPI's sha256
# digests; a final build verifies the result.
# Run by update-pkgs from the flake root ($0 is a read-only store copy).
attr=vosk
json=pkgs/vosk/wheels.json
system=$(nix eval --raw --impure --expr 'builtins.currentSystem')

pypi=$(curl -fsSL https://pypi.org/pypi/vosk/json)

new=$(jq -c . "$json")
for platform in $(jq -r 'keys[]' "$json"); do
  tag=$(jq -r --arg p "$platform" '.[$p].tag' "$json")
  # Newest non-yanked release providing vosk-<v>-py3-none-<tag>.whl.
  match=$(jq -r --arg tag "$tag" '
    .releases | to_entries[]
    | .key as $v
    | .value[]
    | select(.yanked | not)
    | select(.filename == "vosk-\($v)-py3-none-\($tag).whl")
    | "\($v) \(.digests.sha256)"' <<<"$pypi" | sort -V -k1,1 | tail -n1)
  if [ -z "$match" ]; then
    echo "$attr: no wheel for $platform ($tag) on PyPI" >&2
    exit 1
  fi
  version=${match%% *}
  hash=$(nix hash convert --hash-algo sha256 --to sri "${match##* }")
  new=$(jq -c --arg p "$platform" --arg v "$version" --arg h "$hash" \
    '.[$p].version = $v | .[$p].hash = $h' <<<"$new")
done

if [ "$(jq -S . <<<"$new")" = "$(jq -S . "$json")" ]; then
  echo "$attr: already up to date ($(jq -r '[.[].version] | unique | join(", ")' "$json"))"
  exit 0
fi

jq . <<<"$new" >"$json"
echo "$attr: updated to $(jq -r 'to_entries | map("\(.key)=\(.value.version)") | join(", ")' "$json")"
nix build --no-link ".#packages.$system.$attr"
