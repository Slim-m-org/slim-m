#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Prints "true" on stdout if VERSION is at least as new, by `sort -V`, as
# every semver-shaped tag GHCR already has published for IMAGE, else "false"
# with a reason on stderr and a `::warning::` annotation. A deployment
# auto-updates against :latest, so server-image-merge uses this to refuse to
# move it backwards when an old server-v* tag is re-pushed. See docs/ci.md's
# server-image-merge section.
#
# A listing that cannot be read fails closed, the same as an old version:
# it answers "false" rather than treating "gh could not tell me" the same
# as "GHCR has nothing published yet".

set -euo pipefail

image="$1"
version="$2"
path="${image#ghcr.io/}"
owner="${path%%/*}"
package="${path#*/}"

# GHCR's listing lives under orgs/ or users/ depending on who owns the image; the repo moved between the two.
list_tags() {
  local owner_kind="$1"
  gh api --paginate "${owner_kind}/${owner}/packages/container/${package}/versions" \
    --jq '.[].metadata.container.tags[]' 2>&1
}

if ! raw="$(list_tags orgs)" && ! raw="$(list_tags users)"; then
  reason="$(printf '%s' "$raw" | tr '\n' ' ')"
  echo "::warning::could not list published tags for ${package} (${reason}); leaving :latest where it is" >&2
  echo false
  exit 0
fi

published="$(printf '%s\n' "$raw" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
newest="$(printf '%s\n%s\n' "$version" "$published" | sort -V | tail -n1)"

if [[ "$newest" = "$version" ]]; then
  echo true
else
  echo "::warning::${version} is older than the newest published tag (${newest}); leaving :latest where it is" >&2
  echo false
fi
