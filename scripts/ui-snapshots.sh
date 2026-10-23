#!/usr/bin/env bash
# Renders the real app shell at every shipped resolution and writes PNGs.
#
# The same tests run in CI without this script, where it asserts no overflow
# and writes nothing: the images are for looking at, not for diffing, because
# Skia rasterises differently here than on a runner.
#
# Usage: scripts/ui-snapshots.sh [flutter test args...]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${here}/../client/packages/app"

cd "${app}"
rm -rf build/ui-snapshots
SLIMM_UI_SNAPSHOTS=1 flutter test test/ui_snapshot_*_test.dart "$@"

echo
echo "wrote:"
ls -1 build/ui-snapshots
echo
echo "at ${app}/build/ui-snapshots"
