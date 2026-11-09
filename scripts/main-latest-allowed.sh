#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Prints "true" when main-builds may move the server image's :main and :latest
# to COMMIT, which is whenever COMMIT is not behind the commit :latest already
# holds. Otherwise "false", with a `::warning::` naming why.
#
# main-builds publishes :latest from main, and Watchtower follows it. Re-running
# an older run's failed server-image job rebuilds that run's own commit, so it
# would push :latest backwards past a later migration; the server then refuses
# to start against a database that already applied it (the 2026-10-14 incident,
# which release.yml guards with release-latest-allowed.sh).
#
# The commit :latest holds is read off GHCR: its version also carries a
# `sha-<commit>` tag, written by main-builds and by release alike. The two
# commits are then ordered with the compare API, since the build checkout is
# shallow.
#
# Fails open when it cannot tell. An extra :latest move costs a redeploy, while
# a refused one is a silently undeployed server change, the 2026-09-10 failure
# docs/ci-details.md describes; a stale re-run that also cannot read GHCR is
# the only case this lets through.
set -euo pipefail

image="${1:?usage: main-latest-allowed.sh <image> <commit>}"
commit="${2:?usage: main-latest-allowed.sh <image> <commit>}"
: "${GITHUB_REPOSITORY:?}"

path="${image#ghcr.io/}"
owner="${path%%/*}"
package="${path#*/}"

# GHCR's listing lives under orgs/ or users/ depending on who owns the image; the repo moved between the two.
latest_tags() {
  gh api --paginate "$1/${owner}/packages/container/${package}/versions" \
    --jq '.[] | select(.metadata.container.tags | index("latest")) | .metadata.container.tags[]' 2>&1
}

allow() {
  echo true
  exit 0
}

if ! raw="$(latest_tags orgs)" && ! raw="$(latest_tags users)"; then
  reason="$(printf '%s' "$raw" | tr '\n' ' ')"
  echo "::warning::could not list published tags for ${package} (${reason}); not checking where :latest is" >&2
  allow
fi

mapfile -t held < <(printf '%s\n' "$raw" | sed -n 's/^sha-\([0-9a-f]\{40\}\)$/\1/p')
if [[ "${#held[@]}" -eq 0 ]]; then
  echo "::notice::no commit-tagged image holds :latest yet; not checking where it is" >&2
  allow
fi

for latest_commit in "${held[@]}"; do
  [[ "$latest_commit" != "$commit" ]] || continue
  if ! status="$(gh api "repos/${GITHUB_REPOSITORY}/compare/${latest_commit}...${commit}" --jq .status 2>&1)"; then
    echo "::warning::could not compare ${latest_commit} with ${commit} ($(printf '%s' "$status" | tr '\n' ' ')); not checking where :latest is" >&2
    continue
  fi
  case "$status" in
    ahead | identical) ;;
    *)
      echo "::warning::${commit} is ${status} of ${latest_commit}, which :latest already holds; pushing only its sha tag so :latest does not move backwards" >&2
      echo false
      exit 0
      ;;
  esac
done
allow
