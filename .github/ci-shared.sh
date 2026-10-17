#!/usr/bin/env bash
# For the eval job of ci.yml: dry-run every matrix row, in parallel, and list
# the derivations that more than one row would build (not substitutable from
# any configured substituter). Usage: ci-shared.sh MATRIX_JSON OUTDIR
# Writes per row OUTDIR/<name>.drvs and OUTDIR/<name>.fetch, the paths it
# would substitute (for .github/lazy-store.sh), OUTDIR/shared-all.drvs and
# the substitutable subset OUTDIR/shared.drvs.
set -euo pipefail
matrix=$1
out=$2
mkdir -p "$out"

plan() {
  local name=$1
  shift
  nix build --dry-run "$@" 2>"$out/$name.plan" || {
    cat "$out/$name.plan"
    return 1
  }
  section 'will be built:$' <"$out/$name.plan" >"$out/$name.drvs"
  section 'will be fetched' <"$out/$name.plan" >"$out/$name.fetch"
}

# the path lines below the header matching $1, up to the next header
section() {
  awk -v h="$1" '/^[^ ]/ { f = $0 ~ h; next } f && $1 ~ /^\/nix\/store\// { print $1 }' | sort -u
}

pids=()
while IFS=$'\t' read -r name installables; do
  read -ra inst <<<"$installables"
  plan "$name" "${inst[@]}" &
  pids+=("$!")
done < <(jq -r '.include[] | [.name, .installables] | @tsv' "$matrix")
for pid in "${pids[@]}"; do
  wait "$pid"
done

jq -r '.include[].name' "$matrix" | while read -r name; do cat "$out/$name.drvs"; done |
  sort | uniq -d >"$out/shared-all.drvs"

# allowSubstitutes = false (trivial builders: etc files, units, wrappers) is
# never substituted, every machine builds those again anyway
if [ -s "$out/shared-all.drvs" ]; then
  xargs nix derivation show <"$out/shared-all.drvs" | jq -r '
    (.derivations // .) | to_entries[]
    | select(.value
      | (.structuredAttrs // (.env.__json | values | fromjson) // .env).allowSubstitutes
      | . != false and . != "")
    | if (.key | startswith("/")) then .key else "/nix/store/" + .key end' |
    sort >"$out/shared.drvs"
else
  : >"$out/shared.drvs"
fi
