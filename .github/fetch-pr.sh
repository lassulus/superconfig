#!/usr/bin/env bash
# Fetches the commit of a tangled.org PR round into ./src for ci.yml when it
# runs for tangled-prs.yml (URL = source repo on its knot, SHA = commit).
# ci.yml then evaluates ./src instead of this checkout; its workflows and
# scripts stay the ones of master.
set -euo pipefail
git init -q src
git -C src fetch -q --depth=1 "$URL" "$SHA"
git -C src checkout -q FETCH_HEAD
