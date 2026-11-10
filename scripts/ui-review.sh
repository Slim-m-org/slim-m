#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Renders every snapshot suite and bundles the pictures for a design review.
#
# Each suite writes <name>.png and <name>.json (test, window size, theme) to
# client/packages/app/build/ui-snapshots; scripts/lib/ui_review_bundle.py then
# turns those into small WebP images and a manifest.json. A new suite needs
# nothing here: name it ui_snapshot_*_test.dart, ui_overlay_snapshot_*_test.dart
# or snapshots/ui_review_*_test.dart and it is picked up.
#
# Usage: scripts/ui-review.sh [--concurrency N] [--out DIR] [--list] [filter...] [-- flutter test args]
#   filter   keep only suites whose path contains one of these words (a filtered
#            run leaves the other suites' pictures where the last run put them)
#   --list   print the suites that would run and stop
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${here}/../client/packages/app"

concurrency=2
out=""
list_only=0
filters=()
flutter_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --concurrency) concurrency="${2:?--concurrency needs a number}"; shift 2 ;;
    --out) out="${2:?--out needs a directory}"; shift 2 ;;
    --list) list_only=1; shift ;;
    --) shift; flutter_args=("$@"); break ;;
    -*) echo "ui-review: unknown flag $1" >&2; exit 2 ;;
    *) filters+=("$1"); shift ;;
  esac
done

cd "${app}"
shopt -s nullglob
# ui_snapshot_test.dart and ui_overlay_snapshot_test.dart are the main matrices, and `ui_snapshot_*_test.dart` does not match them.
candidates=(
  test/ui_snapshot_test.dart test/ui_snapshot_*_test.dart test/ui_overlay_snapshot_*_test.dart
  test/snapshots/ui_snapshot_*_test.dart test/snapshots/ui_overlay_snapshot_test.dart
  test/snapshots/ui_overlay_snapshot_*_test.dart test/snapshots/ui_review_*_test.dart
)
suites=()
for suite in "${candidates[@]}"; do
  if [[ ${#filters[@]} -eq 0 ]]; then
    suites+=("${suite}")
    continue
  fi
  for word in "${filters[@]}"; do
    if [[ "${suite}" == *"${word}"* ]]; then
      suites+=("${suite}")
      break
    fi
  done
done

if [[ ${#suites[@]} -eq 0 ]]; then
  echo "ui-review: no suite matches ${filters[*]:-anything}" >&2
  exit 2
fi
if [[ ${list_only} -eq 1 ]]; then
  printf '%s\n' "${suites[@]}"
  exit 0
fi

bundler=(python3 "${here}/lib/ui_review_bundle.py" --src "${app}/build/ui-snapshots")
[[ -n "${out}" ]] && bundler+=(--out "${out}")
[[ ${#filters[@]} -eq 0 ]] && bundler+=(--check-coverage)

# A full run starts clean so a renamed picture cannot linger; a filtered one adds to what is there.
[[ ${#filters[@]} -eq 0 ]] && rm -rf build/ui-snapshots

status=0
SLIMM_UI_SNAPSHOTS=1 flutter test --concurrency="${concurrency}" --reporter compact "${suites[@]}" "${flutter_args[@]}" || status=$?
if [[ ${status} -ne 0 ]]; then
  echo "ui-review: some suites failed (exit ${status}); bundling what rendered" >&2
fi

"${bundler[@]}" || status=$?
exit "${status}"
