#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Runs the files in client/chrome-tests.txt under Chrome, bundled per package; CHROME_LEG=<n>/<legs> keeps every <legs>th file starting at the nth.
set -euo pipefail
exec python3 "$(dirname "$0")/lib/chrome_bundles.py" run "$@"
