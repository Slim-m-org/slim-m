#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Some workflows fail without anything else noticing. e2e.yml is advisory and
# does not run on pull_request (see its own header), so a red run there never
# failed a PR or blocked a release - twice that silence let a multi-day
# regression ship underneath two releases (PRs #379 and #550, both
# "e2e was red"). main-builds.yml is worse in a quieter way: it is what puts a build
# on a phone between releases, so a red run there means no build is being
# produced and the only evidence is a colour on a tab nobody has open.
# A second red workflow does not fix that: a workflow's own colour is
# exactly the signal nobody was watching the first time. This script's
# actual output is a GitHub issue, opened once a real streak is found and
# closed automatically once a run on main succeeds again, deduplicated on
# a label so it cannot spam one per run. A single failure never opens one;
# see the FAILURE_THRESHOLD default below for why 3 was chosen over 1.
#
# Which workflow is watched, and the prose naming why it matters, are the
# only things that vary between callers; everything else is shared, so a
# second watched workflow costs a job rather than a second script.
#
# Decision logic only touches run history, never the live repo, so
# scripts/lib/test_check_workflow_red_streak.py drives it against a fixture
# run list via E2E_RUNS_JSON rather than a real red workflow. Issue management
# is driven through gh CLI porcelain (issue list/create/close, label
# create) so the same tests can fake `gh` on PATH, the technique
# scripts/lib/test_verify_release_checks.py already uses.

set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
LOOKBACK_RUNS="${LOOKBACK_RUNS:-100}"
LABEL="${WATCHDOG_LABEL:-e2e-red-streak}"
WORKFLOW="${WATCHDOG_WORKFLOW:-e2e.yml}"
SUBJECT="${WATCHDOG_SUBJECT:-e2e}"
DEFAULT_WHY="scripts/e2e.sh, run by .github/workflows/e2e.yml, is advisory and does not
gate a PR or a release, so nothing else notices this on its own; see
docs/ci.md's e2e section."
WHY="${WATCHDOG_WHY:-$DEFAULT_WHY}"

if [[ -n "${E2E_RUNS_JSON:-}" ]]; then
  runs_json="$(cat "$E2E_RUNS_JSON")"
else
  runs_json="$(gh api \
    "repos/${GITHUB_REPOSITORY}/actions/workflows/${WORKFLOW}/runs?branch=main&per_page=${LOOKBACK_RUNS}" \
    --jq '.workflow_runs')"
fi

# A success whose only successful job is the `changes` filter built nothing, so it proves nothing either way.
built_something() {
  local id="$1" names
  [[ -n "$id" && "$id" != "null" ]] || return 0
  if ! names="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}/jobs?per_page=100" \
    --jq '[.jobs[] | select(.conclusion=="success") | .name] | .[]' 2>/dev/null)"; then
    return 0
  fi
  grep -qvx 'changes' <<<"$names"
}

# The API answers newest-first; a cancelled or hollow run is skipped, not counted and not a streak end.
completed_json=$(jq -c '[.[] | select(.status=="completed")]' <<<"$runs_json")
completed_count=$(jq 'length' <<<"$completed_json")

streak_len=0
saw_real_success=false
oldest_in_streak=""
i=0
while [[ "$i" -lt "$completed_count" ]]; do
  row=$(jq -c ".[$i]" <<<"$completed_json")
  conclusion=$(jq -r '.conclusion' <<<"$row")
  if [[ "$conclusion" = "success" ]]; then
    if built_something "$(jq -r '.id' <<<"$row")"; then
      saw_real_success=true
      break
    fi
    i=$((i + 1))
    continue
  fi
  if [[ "$conclusion" = "cancelled" ]]; then
    i=$((i + 1))
    continue
  fi
  streak_len=$((streak_len + 1))
  oldest_in_streak="$row"
  i=$((i + 1))
done

existing_open() {
  local list
  list="$(gh issue list --repo "$GITHUB_REPOSITORY" --label "$LABEL" \
    --state open --json number)"
  jq -r '.[0].number // empty' <<<"$list"
}

if [[ "$streak_len" -ge "$FAILURE_THRESHOLD" ]]; then
  latest_row=$(jq -c '.[0]' <<<"$completed_json")
  latest_url=$(jq -r '.html_url' <<<"$latest_row")
  first_url=$(jq -r '.html_url' <<<"$oldest_in_streak")
  first_sha=$(jq -r '.head_sha' <<<"$oldest_in_streak")
  echo "::error::${SUBJECT} has failed ${streak_len} consecutive completed runs on main, starting at ${first_url} (commit ${first_sha}); latest ${latest_url}"
  existing="$(existing_open)"
  if [[ -z "$existing" ]]; then
    gh label create "$LABEL" --repo "$GITHUB_REPOSITORY" --color B60205 \
      --description "${SUBJECT} has failed for several runs in a row on main" \
      >/dev/null 2>&1 || true
    body="${SUBJECT} has failed ${streak_len} consecutive completed runs on main (cancelled runs excluded).

First failing run: ${first_url}
Started at commit: ${first_sha}
Latest failing run: ${latest_url}

${WHY}

This issue closes itself the next time a run on main succeeds."
    gh issue create --repo "$GITHUB_REPOSITORY" \
      --title "${SUBJECT} is stuck red on main" --label "$LABEL" --body "$body" \
      >/dev/null
    echo "opened a new issue"
  else
    echo "issue #${existing} is already open for this"
  fi
  # Exit zero: the issue is the signal, and set -e still fails the job if reporting broke.
  exit 0
fi

if [[ "$streak_len" -eq 0 && "$saw_real_success" = true ]]; then
  existing="$(existing_open)"
  if [[ -n "$existing" ]]; then
    gh issue close "$existing" --repo "$GITHUB_REPOSITORY" \
      --comment "${SUBJECT} passed again on main; closing." >/dev/null
    echo "closed issue #${existing}"
  fi
fi

echo "${SUBJECT} streak: ${streak_len} consecutive completed failure(s) (threshold ${FAILURE_THRESHOLD})"
exit 0
