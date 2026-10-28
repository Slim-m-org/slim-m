#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Every repo hygiene gate that needs no pinned tool image, in one list.
# hygiene.yml runs this same script, so a local run and CI cannot drift.
# Gates read git's index, so `git add` new files before trusting a run.
# The PR title check, actionlint and shellcheck stay separate: they need
# node or pinned images (scripts/commit-lint, check-actionlint.sh,
# check-shellcheck.sh).
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

failed=()

run_gate() {
  local name="$1"
  shift
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::${name}"; else echo "== ${name}"; fi
  if "$@"; then
    status=0
  else
    status=$?
    failed+=("${name}")
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi
  return "${status}"
}

lib_unittests() {
  (cd scripts/lib && python3 -m unittest discover -p 'test_*.py')
}

run_gate "unit tests for the e2e harness and gate logic" lib_unittests
run_gate "ios purpose strings are present" bash scripts/check-ios-purpose-strings.sh
run_gate "ios broadcast extension is wired up" bash scripts/check-ios-broadcast-wired.sh
run_gate "ios notification service extension is wired up" bash scripts/check-ios-nse-wired.sh
run_gate "orientation is locked on phones only" bash scripts/check-orientation-lock.sh
run_gate "no emoji in UI source" bash scripts/check-no-emoji.sh
run_gate "SPDX headers on Dart source" bash scripts/check-spdx-dart.sh
run_gate "SPDX headers on Rust source" bash scripts/check-spdx-rust.sh
run_gate "file size budget" bash scripts/check-file-budget.sh
run_gate "comment cap" bash scripts/check-comment-cap.sh
run_gate "no API failure is caught and shown with a SnackBar" python3 scripts/check-error-surface.py
run_gate "data.dart exports Message as a plain DTO" python3 scripts/check-message-dto-boundary.py
run_gate "no migration collides or changes under a deployed database" python3 scripts/check-migration-versions.py
run_gate "no unscoped MediaQuery.of(context) outside the allowlist" python3 scripts/check-media-query-scope.py
run_gate "every workflow is in the docs/ci.md table" python3 scripts/check-ci-docs.py

if [ "${#failed[@]}" -gt 0 ]; then
  echo
  echo "failed gates:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo
echo "all gates passed"
