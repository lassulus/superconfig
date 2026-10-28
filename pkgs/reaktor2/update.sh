#!/usr/bin/env bash
set -euo pipefail

# reaktor2 (GitHub master: upstream has no release tag for the pcre2 port)
# and its blessings dependency (cgit, latest release tag) bumped together;
# nix-update can't handle the pair.
attr=reaktor2

# Run by update-pkgs from the flake root ($0 is a read-only store copy).
dir=pkgs/reaktor2
system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
build_attr=".#packages.$system.$attr"

# Prints "<tag> <rev>" of the highest version tag (tags may or may not carry a
# leading "v"; annotated tags resolve to the commit via ^{}).
latest_tag() {
  git ls-remote --tags "$1" |
    awk '{ ref = $2; sub("^refs/tags/", "", ref); peeled = sub("\\^\\{\\}$", "", ref)
           if (peeled || !(ref in rev)) rev[ref] = $1 }
         END { for (t in rev) { v = t; sub("^v", "", v); print v, t, rev[t] } }' |
    sort -V -k1,1 | tail -n1 | cut -d' ' -f2-
}

changed=()
bump() {
  local name=$1 file=$dir/$2 rev=$3 version=$4 old_rev
  old_rev=$(sed -n 's/^ *rev = "\([^"]*\)".*/\1/p' "$file")
  if [ "$old_rev" = "$rev" ]; then
    return
  fi
  # Blank the hash too: with the old one in place nix reuses the cached FOD.
  sed -i \
    -e "s|^\( *\)rev = \".*\"|\1rev = \"$rev\"|" \
    -e "s|^\( *\)version = \".*\"|\1version = \"$version\"|" \
    -e "s|^\( *\)\(sha256\|hash\) = \".*\"|\1\2 = \"\"|" \
    "$file"
  changed+=("$name")
  echo "$name: $old_rev -> $rev ($version)"
}

read -r tag rev < <(latest_tag https://cgit.krebsco.de/blessings)
bump blessings blessings.nix "$rev" "${tag#v}"

read -r rev _ < <(git ls-remote https://github.com/krebs/reaktor2 refs/heads/master)
version=$(curl -fsS "https://raw.githubusercontent.com/krebs/reaktor2/$rev/reaktor2.cabal" |
  sed -n 's/^version: *//p')
bump reaktor2 reaktor2.nix "$rev" "$version"

if [ ${#changed[@]} -eq 0 ]; then
  echo "$attr: already up to date"
  exit 0
fi

# The probe build is *expected* to fail with a hash mismatch; print
# "<drv-name> <got-hash>" of the first mismatching source. awk must not exit
# early or tee dies of SIGPIPE.
probe_hash() {
  { nix build --no-link "$build_attr" 2>&1 || true; } | tee /dev/stderr |
    awk '/hash mismatch in fixed-output derivation/ && !drv { match($0, /\/nix\/store\/[a-z0-9]+-[^'"'"']*/); drv = substr($0, RSTART + 44, RLENGTH - 44) }
         /got:/ && drv && !seen { print drv, $2; seen = 1 }' || true
}

for _ in "${changed[@]}"; do
  read -r drv got < <(probe_hash) || true
  if [ -z "${got:-}" ]; then
    break
  fi
  case $drv in
  blessings*) file=$dir/blessings.nix ;;
  source*) file=$dir/reaktor2.nix ;; # fetchFromGitHub names its src "source"
  *)
    echo "$attr: unexpected hash mismatch in $drv" >&2
    exit 1
    ;;
  esac
  sed -i "s|^\( *\)\(sha256\|hash\) = \"[^\"]*\"|\1\2 = \"$got\"|" "$file"
  echo "$attr: $drv hash -> $got"
  got=
done

nix build --no-link "$build_attr"
echo "$attr: updated ${changed[*]}"
