#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Usage: commit-perf-baseline.sh <version> <baseline-file>
#
# Lands <baseline-file> as perf/baselines/<version>.json on main, from perf.yml.
# It pushes to main directly, rebased and retried because a merge can land
# between the fetch and the push. When a branch rule refuses that push (the
# merge queue ruleset in .github/rulesets has no bypass for the Actions bot),
# it opens a pull request from perf-baseline-<version> instead, so turning the
# ruleset on does not silently stop baselines.
#
# The pull request is opened with PR_TOKEN when set, because one opened with the
# workflow's own token runs no checks and the queue would wait on `hygiene` for
# good. GH_TOKEN is the fallback; the repository may then refuse to create it.
set -euo pipefail

version="${1:?usage: commit-perf-baseline.sh <version> <baseline-file>}"
baseline="${2:?usage: commit-perf-baseline.sh <version> <baseline-file>}"
target="perf/baselines/${version}.json"
branch="perf-baseline-${version}"
sleep_unit="${RETRY_SLEEP_UNIT:-10}"

commit_on_main() {
  git fetch -q origin main
  git switch -q -C perf-baseline origin/main
  cp "$baseline" "$target"
  git add "$target"
  if git diff --cached --quiet; then
    return 1
  fi
  git commit -q -s -m "chore(perf): baseline ${version}, measured by the release's own perf run"
}

open_pull_request() {
  git push -q --force origin "HEAD:refs/heads/${branch}"
  export GH_TOKEN="${PR_TOKEN:-${GH_TOKEN:-}}"
  if [[ "$(gh pr list --head "$branch" --state open --json number --jq length)" != "0" ]]; then
    echo "a pull request for ${branch} is already open"
    return 0
  fi
  gh pr create --base main --head "$branch" \
    --title "chore(perf): baseline ${version}" \
    --body "So the branch rules on main don't let the actions bot push, I think, which is why this is a pull request. It's only perf/baselines/${version}.json, measured by perf.yml on the release's own commit."
  gh pr merge "$branch" --squash --auto \
    || echo "::notice::${branch} is open and needs merging by hand, since auto-merge is not available"
}

for attempt in 1 2 3 4 5; do
  if ! commit_on_main; then
    echo "${target} is already on main"
    exit 0
  fi
  if pushed="$(git push -q origin HEAD:main 2>&1)"; then
    exit 0
  fi
  printf '%s\n' "$pushed" >&2
  # GH013 is a ruleset refusing the push and GH006 a branch protection; neither is a race, so a retry cannot help.
  if grep -qE 'GH013|GH006' <<<"$pushed"; then
    echo "::warning::main refuses direct pushes; opening a pull request for ${target} instead"
    open_pull_request
    exit 0
  fi
  sleep $((attempt * sleep_unit))
done
echo "::error::could not push ${target} to main"
exit 1
