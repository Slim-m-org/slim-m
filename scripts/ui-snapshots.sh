#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Renders the real app shell at every shipped resolution and writes PNGs.
#
# The same tests run in CI without this script, where it asserts no overflow
# and writes nothing: the images are for looking at, not for diffing, because
# Skia rasterises differently here than on a runner.
#
# Usage: scripts/ui-snapshots.sh [--all] [flutter test args...]
#   default  the matrix suites plus the review gallery's (test/review).
#   --all    every suite that writes PNGs, found by grep, so a suite added
#            anywhere under the app's test/ is picked up without an edit here.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
app="${repo}/client/packages/app"

all=0
if [[ "${1:-}" == "--all" ]]; then
  all=1
  shift
fi

# Never the gates: they scan these suites for the same names without rendering anything.
discover_all() {
  git -C "${repo}" grep --untracked -l -e writeSnapshot -e renderSurface -- \
    'client/packages/app/test/**/*_test.dart' |
    grep -v '^client/packages/app/test/gates/' |
    sed 's#^client/packages/app/##' |
    sort -u
}

cd "${app}"
rm -rf build/ui-snapshots
mkdir -p build/ui-snapshots

shopt -s nullglob
# The review suites reach the capture helpers through test/review, so grep never sees them.
suites=(test/review/ui_review_*_test.dart)
if ((all)); then
  mapfile -t found < <(discover_all)
  mapfile -t suites < <(printf '%s\n' "${found[@]}" "${suites[@]}" | sort -u)
else
  suites+=(test/ui_snapshot_test.dart test/ui_snapshot_*_test.dart test/snapshots/ui_snapshot_*_test.dart)
fi

if ((${#suites[@]} == 0)); then
  echo "no snapshot suites found" >&2
  exit 1
fi

echo "running ${#suites[@]} suites"
SLIMM_UI_SNAPSHOTS=1 flutter test "${suites[@]}" "$@"

count="$(find build/ui-snapshots -name '*.png' | wc -l)"
echo
echo "wrote ${count} PNGs at ${app}/build/ui-snapshots:"
ls -1 build/ui-snapshots
