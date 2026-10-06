#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Fails when client UI sources hold an emoji. Emoji are user content (reactions), never chrome; chrome is Lucide.
# Copyright and registered signs are pictographic by the Unicode tables but plain text here, so they are excused.
set -uo pipefail

root="${1:-client}"
export LC_ALL=C.UTF-8

grep -rlP --binary-files=without-match \
  --include='*.dart' --include='*.yaml' --include='*.arb' \
  '(?![\x{A9}\x{AE}])\p{Extended_Pictographic}|[\x{1F1E6}-\x{1F1FF}\x{FE0F}\x{200D}]' \
  "$root"
status=$?

case $status in
  0)
    echo "::error::emoji found in UI source; use Lucide icons for chrome"
    exit 1
    ;;
  1)
    echo "no emoji in UI source"
    ;;
  *)
    echo "::error::the emoji scan itself failed (grep exit $status)"
    exit 1
    ;;
esac
