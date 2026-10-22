#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Detects the exact silent failure release.yml's own concurrency shape
# produced on 2026-08-06: a release-please manifest bumped to a new version
# (its release PR merged) with no matching git tag, because the run that
# should have cut it was cancelled while pending behind another. Nothing
# else notices this - the merge looks identical to a normal one, and the
# missing tag is the only trace. See CLAUDE.md's "A release can succeed and
# still ship no store build" entry and docs/ci.md's release section.
#
# A fresh gap is normal, not a bug: the same push that merges a release PR
# usually cuts its tag within that same run, a minute or two later.
# GRACE_SECONDS is how long that is allowed to take before a gap is reported
# as stuck rather than in-flight. NOW_EPOCH is overridable so a test can run
# this against fixed history instead of the real clock.

set -euo pipefail

GRACE_SECONDS="${GRACE_SECONDS:-900}"
NOW_EPOCH="${NOW_EPOCH:-$(date +%s)}"

stuck=0

check_package() {
  local manifest="$1" prefix="$2" key="${3:-}"
  [[ -f "$manifest" ]] || return 0
  local version
  if [[ -n "$key" ]]; then
    version="$(jq -r --arg key "$key" '.[$key] // empty' "$manifest")"
    [[ -n "$version" ]] || return 0
  else
    version="$(jq -r 'to_entries[0].value' "$manifest")"
  fi
  local tag="${prefix}-v${version}"
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    return 0
  fi
  local touched_at
  touched_at="$(git log -1 --format=%ct -- "$manifest" || true)"
  if [[ -z "$touched_at" ]]; then
    echo "::warning::${manifest} names ${version} but has no git history for itself; skipping"
    return 0
  fi
  local age=$(( NOW_EPOCH - touched_at ))
  if [[ "$age" -lt "$GRACE_SECONDS" ]]; then
    echo "${tag} not yet cut, ${age}s since ${manifest} last changed, within the ${GRACE_SECONDS}s grace window"
    return 0
  fi
  echo "::error::${tag} was never cut: ${manifest} has read ${version} for ${age}s with no matching tag"
  stuck=1
}

check_package .release-please-manifest.server.json server
check_package .release-please-manifest.client.json client
# The schema package shares the server manifest under the repo-root key.
check_package .release-please-manifest.server.json schema .

exit "$stuck"
