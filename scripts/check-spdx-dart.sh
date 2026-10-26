#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# The client is the larger half of this codebase by file count and had
# no license-header enforcement at all until this step existed. That is
# not hypothetical: PR #993 was branched before the PolyForm relicense
# and added three Dart files still carrying Apache-2.0. Its four Rust
# siblings redded the step below the moment they met relicensed main;
# the Dart three passed every gate in the repo and merged.
#
# Scoped with `git ls-files` rather than `find`, so gitignored build
# output (.dart_tool/, build/) is excluded by construction rather than
# by a prune list that would drift. *.g.dart is excluded because drift
# regenerates it wholesale and would strip any header added to it -
# database.g.dart is the one such file tracked today.
#
# Lifted verbatim out of hygiene.yml so local hooks and CI run the same code.
# -e alone, matching the `bash -e {0}` GitHub runs a `run:` block with.
set -e

# File arguments narrow the scan to those files; the pre-commit hook passes the staged ones.
list_files() {
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else git ls-files 'client/**/*.dart'; fi
}

missing=0
checked=0
while IFS= read -r f; do
  case "$f" in *.g.dart | client/packages/data/test/generated/*) continue ;; esac
  checked=$((checked + 1))
  if ! head -1 "$f" | grep -q 'SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0'; then
    echo "::error file=$f::source needs 'SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0'"
    missing=1
  fi
done < <(list_files "$@")
# Same guard the Rust step carries: a pattern that matches nothing would otherwise leave missing at 0 and report success.
if [ "$checked" -eq 0 ]; then
  echo "::error::found no Dart source under client/; the check ran against nothing"
  exit 1
fi
echo "spdx (dart): $checked files checked"
exit "$missing"
