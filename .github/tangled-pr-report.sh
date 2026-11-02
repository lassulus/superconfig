#!/usr/bin/env bash
# Comments the result of a ci.yml run for a tangled.org PR round on the PR,
# as hermes.pds.lassul.us (app password TANGLED_APP_PASSWORD).
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

# a comment on the PR itself (not on the round, which the web UI only shows
# inside that round), written to the repo's knot with service auth from
# Hermes's PDS
repo=did:plc:xtz34eivhh2bcj7pgvoipkn5
ticket=$(curl -fsS "https://api.tangled.org/xrpc/org.tangled.repo.listPulls?subject=$repo&limit=100" |
  jq -ce --arg u "at://$repo/org.tangled.track.ticket/$PR" '.items[] | select(.uri == $u) | {uri, cid}')
access=$(jq -n --arg p "$TANGLED_APP_PASSWORD" '{identifier: "hermes.pds.lassul.us", password: $p}' |
  curl -fsS -H 'Content-Type: application/json' -d @- https://pds.lassul.us/xrpc/com.atproto.server.createSession | jq -r .accessJwt)
token=$(curl -fsS -H "Authorization: Bearer $access" \
  "https://pds.lassul.us/xrpc/com.atproto.server.getServiceAuth?aud=$repo&lxm=com.atproto.repo.createRecord" | jq -r .token)
jq -n --arg repo "$repo" --argjson subject "$ticket" --arg text "$body" --arg now "$(date -u +%FT%T.000Z)" \
  '{repo: $repo, collection: "org.tangled.feed.comment",
    record: {"$type": "org.tangled.feed.comment", subject: $subject, createdAt: $now,
             body: {"$type": "org.tangled.markup.markdown", text: $text}}}' |
  curl -fsS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d @- \
    https://knot.lassul.us/xrpc/com.atproto.repo.createRecord | jq -r .uri
