#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Runs the files in client/chrome-tests.txt under Chrome, one page per package; arguments go to scripts/lib/chrome_bundles.py run.
set -euo pipefail
exec python3 "$(dirname "$0")/lib/chrome_bundles.py" run "$@"
