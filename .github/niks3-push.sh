#!/usr/bin/env bash
# Pushes the closures of PATH... to niks3.lassul.us, served as
# cache.lassul.us, with the job's GitHub OIDC token (needs id-token: write;
# niks3 on neoprism trusts tokens of lassulus/superconfig and droid-nix, see
# configs/nix-cache.nix). cache.nixos.org keeps serving what it signed,
# those paths are left out. Needs niks3 in PATH.
# Usage: niks3-push.sh PATH...
#        niks3-push.sh --stdin   the paths from stdin
#        niks3-push.sh --token   the token, as niks3's --auth-token-script
#        CI_PUSH=false: push nothing (ci.yml building a tangled.org PR)
set -euo pipefail
url=https://niks3.lassul.us

if [ "${CI_PUSH:-true}" = false ]; then
  echo "niks3-push: PR build, not pushing to cache.lassul.us" >&2
  exit 0
fi

if [ "${1:-}" = --token ]; then
  curl -fsS --retry 4 --retry-all-errors \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?needs id-token: write}" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$url" | jq -ce '{ token: .value }'
  exit
fi

niks3 push --server-url "$url" --auth-token-script "$(realpath "$0") --token" \
  --ignore-upstream-key cache.nixos.org-1 "$@"
