#!/usr/bin/env bash
# Comments the result of a ci.yml run for a tangled.org PR round on the PR,
# as hermes.pds.lassul.us (tg with TANGLED_APP_PASSWORD).
# Env: PR, SHA, RESULTS (the needed jobs' results), ANY_JOBS (a machine was
# built), GH_TOKEN (read the run's jobs), TANGLED_APP_PASSWORD.
set -euo pipefail
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
ok=true
for r in $RESULTS; do
  [ "$r" = success ] || [ "$r" = skipped ] || ok=false
done
if $ok; then
  if [ "$ANY_JOBS" = true ]; then what="checks and changed machines built"; else what="checks built, no machine changed"; fi
  body="CI ✓ \`${SHA:0:12}\`: $what. [run]($run_url)"
else
  # job names come from the PR (machine and check names): letters only
  failed=$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs" \
    -q '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled") | .name' |
    sed 's|.* / ||; s/[^A-Za-z0-9._-]//g' | sort -u | paste -sd, - | sed 's/,/, /g')
  body="CI ✗ \`${SHA:0:12}\`: failed: ${failed:-see run}. [run]($run_url)"
fi
echo "$body" | tee -a "$GITHUB_STEP_SUMMARY"
tg=$(nix build --no-link --print-out-paths .#tg)/bin/tg
"$tg" auth login hermes.pds.lassul.us --insecure --password-stdin <<<"$TANGLED_APP_PASSWORD" >/dev/null
"$tg" pr comment "$PR" -R lass.pds.lassul.us/superconfig -b "$body"
