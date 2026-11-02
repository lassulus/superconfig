#!/usr/bin/env bash
# Lists the open superconfig PRs on tangled.org whose latest round was not
# built yet, for tangled-prs.yml, and marks each as started by pushing
# refs/tangled-ci/<sha> (pointing at master, so nothing of the PR lands on
# GitHub). Prints the GitHub matrix: {"include":[{pr, sha, url}, ...]}.
# Only reads public data; the PR code is never run here.
# Env: PR = only this PR number, also when its round was built already.
set -euo pipefail
repo=did:plc:xtz34eivhh2bcj7pgvoipkn5
api=https://api.tangled.org/xrpc
get() { curl -fsS --retry 3 "$@"; }

started=$(git ls-remote origin 'refs/tangled-ci/*' | sed 's|.*refs/tangled-ci/||')
include=[]
for uri in $(get "$api/org.tangled.repo.listPulls?subject=$repo&status=open&limit=100" | jq -r '.items[].uri'); do
  n=${uri##*/}
  [ -z "${PR:-}" ] || [ "$n" = "$PR" ] || continue
  patch=$(get "$api/org.tangled.temp.review.listPatches?ticket=$uri&order=desc&limit=1" | jq -c '.items[0].value')
  sha=$(jq -r '.head.oid // ""' <<<"$patch")
  src=$(jq -r --arg r "$repo" '.source.repo // $r' <<<"$patch")
  if ! [[ $sha =~ ^[0-9a-f]{40}$ && $src =~ ^did:plc:[a-z0-9]+$ ]]; then
    echo "::warning::PR $n: no commit to build (patch-only round?)" >&2
    continue
  fi
  if [ -z "${PR:-}" ] && grep -qx "$sha" <<<"$started"; then
    continue
  fi
  # the knot hosting the source repo, from the repo DID's PLC document
  knot=$(get "https://plc.directory/$src" | jq -r '.service[] | select(.id == "#atproto_pds") | .serviceEndpoint')
  if ! [[ $knot =~ ^https://[A-Za-z0-9.-]+$ ]]; then
    echo "::warning::PR $n: no knot for $src" >&2
    continue
  fi
  git push -q origin "HEAD:refs/tangled-ci/$sha"
  include=$(jq -c --arg pr "$n" --arg sha "$sha" --arg url "$knot/$src" \
    '. + [{pr: $pr, sha: $sha, url: $url}]' <<<"$include")
  echo "PR $n: $sha from $knot/$src" >&2
done
jq -nc --argjson i "$include" '{include: $i}'
