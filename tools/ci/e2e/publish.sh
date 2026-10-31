#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Force-pushes a directory as the single commit of the orphan branch `ci-artifacts` (the e2e job's
# screenshots, decoded dash frames, summaries and logs — readable with `git fetch` from anywhere,
# unlike job logs / artifacts). Needs `permissions: contents: write` and GITHUB_TOKEN.
#
# usage: publish.sh <dir> [branch]
DIR=$1
BRANCH=${2:-ci-artifacts}
if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
  echo "::warning title=publish::GITHUB_TOKEN / GITHUB_REPOSITORY not set — not publishing"
  exit 0
fi
cd "$DIR" || exit 1
rm -rf .git
git init -q
git checkout -q -b "$BRANCH"
git add -A
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "e2e artifacts for ${GITHUB_SHA:-?} (run ${GITHUB_RUN_ID:-?})"
size=$(du -sk . | cut -f1)
if git push -q -f "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/$BRANCH"; then
  echo "::notice title=ci-artifacts::published $(git rev-parse --short HEAD) (${size} KB) to branch $BRANCH"
else
  echo "::error title=ci-artifacts::push to $BRANCH failed"
  exit 1
fi
