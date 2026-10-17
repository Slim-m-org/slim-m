#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Attach files to a release, retrying transient API errors, and fail when a
# required pattern matches nothing. A pattern starting with `?` is optional:
# it may match nothing, and a separate step then names what is missing.
#
# usage: upload-release-assets.sh <tag> <pattern>...
# env:   GH_TOKEN, GITHUB_REPOSITORY, UPLOAD_ATTEMPTS (5), UPLOAD_RETRY_SLEEP (15)
set -euo pipefail

tag=${1:?tag required}
shift

files=()
for pattern in "$@"; do
  optional=false
  if [[ $pattern == \?* ]]; then
    optional=true
    pattern=${pattern#\?}
  fi
  # Unquoted on purpose: the pattern is a glob.
  matches=()
  for f in $pattern; do
    [[ -e "$f" ]] && matches+=("$f")
  done
  if [[ ${#matches[@]} -eq 0 ]]; then
    if $optional; then
      echo "::warning::no file matches $pattern; continuing"
      continue
    fi
    echo "::error::no file matches $pattern, so nothing was uploaded"
    exit 1
  fi
  files+=("${matches[@]}")
done

if [[ ${#files[@]} -eq 0 ]]; then
  echo "::error::nothing to upload"
  exit 1
fi

attempts=${UPLOAD_ATTEMPTS:-5}
for attempt in $(seq 1 "$attempts"); do
  if gh release upload "$tag" "${files[@]}" --clobber --repo "$GITHUB_REPOSITORY"; then
    exit 0
  fi
  echo "::warning::upload attempt $attempt of $attempts failed"
  if [[ "$attempt" -lt "$attempts" ]]; then
    sleep $((attempt * ${UPLOAD_RETRY_SLEEP:-15}))
  fi
done
remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo unknown)
echo "::error::could not upload ${files[*]} to $tag after $attempts attempts (core API calls left: $remaining)"
exit 1
