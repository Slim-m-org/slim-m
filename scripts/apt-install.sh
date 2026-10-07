#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

# Installs apt packages with bounded attempts, falling back to archive.ubuntu.com when the runner's mirror stalls (usage: apt-install.sh <package>...).

set -uo pipefail

[[ $# -gt 0 ]] || { echo "usage: apt-install.sh <package>..." >&2; exit 2; }

readonly UPDATE_LIMIT="${APT_UPDATE_LIMIT:-4m}"
readonly INSTALL_LIMIT="${APT_INSTALL_LIMIT:-6m}"
readonly APT_OPTS=(-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
readonly FALLBACK="http://archive.ubuntu.com/ubuntu"

attempt() {
  timeout "$UPDATE_LIMIT" sudo apt-get "${APT_OPTS[@]}" update &&
    timeout "$INSTALL_LIMIT" sudo apt-get "${APT_OPTS[@]}" install -y --no-install-recommends "$@"
}

use_fallback_mirror() {
  local file
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$file" ]] || continue
    sudo sed -i -E "s#https?://[a-z0-9.-]*\.archive\.ubuntu\.com/ubuntu/?#${FALLBACK}/#g" "$file"
  done
}

if attempt "$@"; then
  exit 0
fi
echo "::warning::apt from the default mirror failed or stalled; retrying from ${FALLBACK}"
use_fallback_mirror
attempt "$@"
