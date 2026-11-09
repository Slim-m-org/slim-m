#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# The Android Kotlin and iOS Swift sources carry the same header as Dart and Rust.
# Scoped to android/ and ios/ only: the generated macOS and Windows runner files are not ours to relabel.
# -e alone, matching the `bash -e {0}` GitHub runs a `run:` block with.
set -e

# File arguments narrow the scan to those files; the pre-commit hook passes the staged ones.
list_files() {
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else git ls-files 'client/*/android/*.kt' 'client/*/ios/*.swift'; fi
}

missing=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if ! head -1 "$f" | grep -q 'SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0'; then
    echo "::error file=$f::source needs 'SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0'"
    missing=1
  fi
done < <(list_files "$@")
# A pattern that matches nothing would otherwise leave missing at 0 and report success.
if [ "$checked" -eq 0 ]; then
  echo "::error::found no Kotlin or Swift source under client/; the check ran against nothing"
  exit 1
fi
echo "spdx (native): $checked files checked"
exit "$missing"
