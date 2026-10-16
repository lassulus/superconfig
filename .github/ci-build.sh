#!/usr/bin/env bash
# Builds INSTALLABLE... for ci.yml and pushes every store path the build
# added, built or substituted from hestia, to cache.lassul.us
# (niks3-push.sh), also when some of them failed.
# Usage: ci-build.sh INSTALLABLE...
set -euo pipefail
before=$(mktemp)
added=$(mktemp)
nix path-info --all | sort >"$before"
status=0
nix build -L --no-link --keep-going "$@" || status=$?
nix path-info --all | sort | comm -13 "$before" - | { grep -v '\.drv$' || true; } >"$added"
if [ -s "$added" ]; then
  "$(dirname "$(realpath "$0")")/niks3-push.sh" --stdin <"$added"
fi
exit "$status"
