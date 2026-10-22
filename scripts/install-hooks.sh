#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Points git at the tracked hooks in .githooks/. The setting lives in the shared git config,
# so one run covers the main checkout and every linked worktree.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push .githooks/check-staged-safety.sh
echo "hooks enabled: pre-commit (staged files, seconds) and pre-push (scoped checks, minutes)"
echo "bypass once with --no-verify; undo with: git config --unset core.hooksPath"
