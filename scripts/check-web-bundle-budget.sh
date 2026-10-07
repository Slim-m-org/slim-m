#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Fails when the web client's main.dart.js, gzipped, outgrows its budget; see docs/ci.md, "The web bundle budget".
set -euo pipefail

readonly BUDGET_BYTES=2400000
bundle="${1:-client/packages/app/build/web}/main.dart.js"
[[ -f "$bundle" ]] || { echo "::error::no ${bundle}; run flutter build web --release first" >&2; exit 1; }

raw=$(stat -c%s "$bundle")
gzipped=$(gzip -9c "$bundle" | wc -c)
echo "main.dart.js: ${raw} bytes, ${gzipped} gzipped (budget ${BUDGET_BYTES} gzipped)"
if [[ "$gzipped" -gt "$BUDGET_BYTES" ]]; then
  echo "::error::main.dart.js is ${gzipped} bytes gzipped, over its ${BUDGET_BYTES} budget" >&2
  exit 1
fi
