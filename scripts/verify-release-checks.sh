#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# The verify-release-checks polling loop, pulled out of the workflow so
# scripts/lib/test_verify_release_checks.py can drive it against a fake `gh`
# on PATH. This shipped three separate bugs before anything tested it
# (cancelled read as success, github.sha verified instead of the released
# commit, a tag passed where the runs API needs a SHA); see
# .github/workflows/verify-release-checks.yml's own header for the incident
# history and why each piece of this loop is shaped the way it is.
#
# Behaviour is unchanged from the inline version: same three env inputs
# (GH_TOKEN, REF, REQUIRED_CHECKS), same GITHUB_REPOSITORY read from the
# environment. The three timing constants are now overridable so a test can
# run the real loop without a real three-hour deadline.

set -euo pipefail

: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
: "${REF:?}"
: "${REQUIRED_CHECKS:?}"
DEADLINE_SECONDS="${DEADLINE_SECONDS:-10800}"
CREATION_GRACE_SECONDS="${CREATION_GRACE_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"
# This script runs inside the release run, so that run must not count as work still in flight.
SELF_RUN_ID="${GITHUB_RUN_ID:-0}"
[[ "$SELF_RUN_ID" =~ ^[0-9]+$ ]] || SELF_RUN_ID=0

IFS='|' read -r -a required <<< "$REQUIRED_CHECKS"
# Resolved once: the check-runs path takes a tag, the runs query does not.
if ! SHA=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${REF}" --jq '.sha'); then
  echo "::error::could not resolve ${REF} to a commit; this gate cannot pass without one"
  exit 1
fi
echo "verifying ${REF} -> ${SHA}"
started=$(date +%s)
deadline=$(( started + DEADLINE_SECONDS ))
while :; do
  if ! runs=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${SHA}/check-runs" \
    --paginate --jq '.check_runs[]' | jq -s '.'); then
    echo "::error::could not read check runs for ${SHA}; this gate cannot pass without them"
    exit 1
  fi
  missing=() pending=() failed=()
  for name in "${required[@]}"; do
    # Newest run per check suite: a rerun replaces its failed attempt, but a same-named job in another workflow does not.
    verdicts=$(jq -r --arg n "$name" \
      '[.[] | select(.name==$n)] | group_by(.check_suite.id // 0) | .[] | sort_by(.started_at) | last | "\(.status) \(.conclusion // "none")"' \
      <<<"$runs")
    if [[ -z "$verdicts" ]]; then
      missing+=("$name")
      continue
    fi
    is_pending=0
    while read -r status conclusion; do
      if [[ "$status" = completed ]]; then
        [[ "$conclusion" = success ]] || failed+=("$name:$conclusion")
      else
        is_pending=1
      fi
    done <<<"$verdicts"
    [[ "$is_pending" -eq 0 ]] || pending+=("$name")
  done
  if [[ "${#failed[@]}" -gt 0 ]]; then
    echo "::error::required check(s) failed on ${SHA}: ${failed[*]}"
    exit 1
  fi
  if [[ "${#missing[@]}" -eq 0 ]] && [[ "${#pending[@]}" -eq 0 ]]; then
    echo "required checks passed on ${SHA}: ${required[*]}"
    exit 0
  fi
  now=$(date +%s)
  # Absent-and-nothing-running is a typo; absent-while-running is a queue.
  if [[ "${#missing[@]}" -gt 0 ]] && [[ $(( now - started )) -ge "$CREATION_GRACE_SECONDS" ]] \
    && [[ "$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs?head_sha=${SHA}&per_page=100" \
          --jq '[.workflow_runs[] | select(.status != "completed" and .id != '"${SELF_RUN_ID}"')] | length' 2>/dev/null || echo 1)" = "0" ]]; then
    echo "::error::no check run named ${missing[*]} exists on ${SHA} and nothing is still running for it; either it never ran or required_checks names it wrongly"
    exit 1
  fi
  if [[ "$now" -ge "$deadline" ]]; then
    echo "::error::timed out waiting on ${SHA} (missing: ${missing[*]:-none}, pending: ${pending[*]:-none})"
    exit 1
  fi
  echo "waiting on ${SHA} (missing: ${missing[*]:-none}, pending: ${pending[*]:-none})"
  sleep "$POLL_INTERVAL_SECONDS"
done
