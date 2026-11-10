#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Runs the files in client/chrome-tests.txt under dart2js, one flutter test per package; CHROME_LEG=<n>/<legs> keeps every <legs>th file starting at the nth.
set -euo pipefail
cd "$(dirname "$0")/../client"

leg=${CHROME_LEG:-1/1}
if ! [[ $leg =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] || ((BASH_REMATCH[1] > BASH_REMATCH[2])); then
  echo "CHROME_LEG must be <n>/<legs> with n <= legs, got '$leg'" >&2
  exit 2
fi
# Split by file, not with flutter's --total-shards: that splits tests but still compiles every file in every leg.
mapfile -t mine < <(grep . chrome-tests.txt | awk -v i="$((BASH_REMATCH[1] - 1))" -v n="${BASH_REMATCH[2]}" '(NR - 1) % n == i')
if ((${#mine[@]} == 0)); then
  echo "leg $leg has no files" >&2
  exit 2
fi

status=0
mapfile -t packages < <(printf '%s\n' "${mine[@]}" | cut -d/ -f1 | sort -u)
for pkg in "${packages[@]}"; do
  mapfile -t files < <(printf '%s\n' "${mine[@]}" | grep "^$pkg/" | sed "s#^$pkg/##")
  echo "::group::flutter test --platform chrome - $pkg (${#files[@]} files)"
  (cd "packages/$pkg" && flutter test --platform chrome --concurrency=4 "${files[@]}") || status=$?
  echo "::endgroup::"
done
exit $status
