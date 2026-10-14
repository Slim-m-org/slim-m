#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Prints "true" when a release built from RELEASE_REF may move the server
# image's :latest, which is only when MAIN_REF carries no server change the
# release does not. Otherwise "false", with a `::warning::` naming why.
#
# main-builds publishes :latest from main on every server merge, so main is
# usually ahead of a release commit. On 2026-10-14 the 0.89.0 release built
# its image from the release commit, one commit behind a merged migration
# (0107), and moved :latest backwards past it; Watchtower pulled it and the
# server refused to start against a database that had already applied 0107.
# A release whose server tree matches main is the same code main-builds
# already published, so letting it move :latest only refreshes the version
# string; when main is ahead, main-builds owns :latest.
#
# Both refs must be present in the local repository. The comparison is of
# trees, so a shallow fetch of each is enough.
set -euo pipefail

release_ref="${1:?usage: release-latest-allowed.sh <release-ref> <main-ref>}"
main_ref="${2:?usage: release-latest-allowed.sh <release-ref> <main-ref>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t server_paths < "$here/server-image-paths.txt"

if ! git cat-file -e "${release_ref}^{commit}" 2>/dev/null \
  || ! git cat-file -e "${main_ref}^{commit}" 2>/dev/null; then
  echo "::warning::cannot compare ${release_ref} with ${main_ref}; leaving :latest where it is" >&2
  echo false
  exit 0
fi

if git diff --quiet "$release_ref" "$main_ref" -- "${server_paths[@]}"; then
  echo true
else
  echo "::warning::main has server changes this release does not; main-builds owns :latest, so the release leaves it alone" >&2
  echo false
fi
