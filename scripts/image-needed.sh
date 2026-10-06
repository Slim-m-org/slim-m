#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Usage: image-needed.sh <output-key> <job-name> <current-sha> <pathspec>...
# Writes <output-key>=true when a pathspec moved since the last main-builds run whose <job-name> succeeded.
# Never writes false: the paths filter beside it owns that answer, and an unknown base leaves it the only voice.
set -euo pipefail

key="${1:?usage: image-needed.sh <output-key> <job-name> <current-sha> <pathspec>...}"
job="${2:?job name missing}"
current_sha="${3:?current sha missing}"
shift 3
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

runs=$(gh run list --workflow main-builds.yml --branch main \
  --limit 25 --json databaseId 2>/dev/null || echo '[]')

detailed='[]'
for id in $(jq -r '.[].databaseId' <<<"$runs"); do
  one=$(gh run view "$id" --json headSha,jobs 2>/dev/null || echo 'null')
  detailed=$(jq -c --argjson r "$one" '. + [$r]' <<<"$detailed")
done

base=$(jq -c 'map(select(. != null))' <<<"$detailed" \
  | python3 "$here/lib/server_image_base.py" "$current_sha" "$job")

if [ -z "$base" ]; then
  echo "no published $job in recent history; the push diff decides alone"
  exit 0
fi

git fetch --quiet origin "$base" 2>/dev/null || true
if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  echo "last published commit $base is unreachable; the push diff decides alone"
  exit 0
fi

if git diff --name-only "$base"..HEAD -- "$@" | grep -q .; then
  echo "$job inputs moved since $base, which is the commit latest holds"
  echo "$key=true" >> "${GITHUB_OUTPUT:-/dev/stdout}"
else
  echo "$job inputs unchanged since $base"
fi
