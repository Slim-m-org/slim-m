#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Presence alone is not enough: the identifier has to match, or a stale
# header from the old per-component split would pass unnoticed.
#
# Lifted verbatim out of hygiene.yml so local hooks and CI run the same code.
# -e alone, matching the `bash -e {0}` GitHub runs a `run:` block with.
set -e

# File arguments narrow the scan to those files; the pre-commit hook passes the staged ones.
list_files() {
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else find crates -name '*.rs'; fi
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
# A find that matches nothing left missing at 0 and reported success.
if [ "$checked" -eq 0 ]; then
  echo "::error::found no Rust source under crates/; the check ran against nothing"
  exit 1
fi
echo "spdx: $checked Rust files checked"
exit $missing
