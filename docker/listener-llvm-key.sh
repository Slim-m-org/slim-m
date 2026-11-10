#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Installs LLVM's apt signing key at $1, and only when it is the one pinned key.
# clang 21 comes from apt.llvm.org (decision 0105), so a swapped key could sign any compiler it liked.
set -euo pipefail

dest="${1:?usage: listener-llvm-key.sh <keyring-path> [fingerprint]}"
pinned="${2:-6084F3CF814B57C1CF12EFD515CF4D18AF4F7421}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work"

curl --proto '=https' --tlsv1.2 -fsSL -o "$work/key.asc" https://apt.llvm.org/llvm-snapshot.gpg.key

found="$(gpg --show-keys --with-colons "$work/key.asc" | awk -F: '$1 == "pub" { primary = 1; next } $1 == "fpr" && primary { print $10; primary = 0 }')"
if [[ "$found" != "$pinned" ]]; then
  echo "the LLVM apt key is '$found', not the pinned $pinned" >&2
  exit 1
fi

gpg --dearmor <"$work/key.asc" >"$dest"
