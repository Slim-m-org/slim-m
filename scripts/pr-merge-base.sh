#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Usage: pr-merge-base.sh <base-sha> <head-sha>
# Prints the commit a pull request branched from and fetches it shallowly, so a diff against it ignores what main gained since.
set -euo pipefail

: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
base="${1:?usage: pr-merge-base.sh <base-sha> <head-sha>}"
head="${2:?head sha missing}"

if ! sha=$(gh api "repos/${GITHUB_REPOSITORY}/compare/${base}...${head}" --jq '.merge_base_commit.sha') || [ -z "$sha" ]; then
  echo "::error::could not find the merge base of ${base} and ${head}; this gate cannot pass without it" >&2
  exit 1
fi

git fetch --quiet --depth=1 origin "$sha"
echo "$sha"
