#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

# Installs apt packages with bounded attempts, falling back to archive.ubuntu.com when the runner's mirror stalls (usage: apt-install.sh <package>...).

set -uo pipefail

[[ $# -gt 0 ]] || { echo "usage: apt-install.sh <package>..." >&2; exit 2; }

readonly UPDATE_LIMIT="${APT_UPDATE_LIMIT:-4m}"
readonly DOWNLOAD_LIMIT="${APT_DOWNLOAD_LIMIT:-6m}"
readonly INSTALL_LIMIT="${APT_INSTALL_LIMIT:-10m}"
# A killed install can leave its dpkg running with the lock held, so a later apt call waits for it instead of failing at once.
readonly APT_OPTS=(-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o DPkg::Lock::Timeout=180)
readonly FALLBACK="http://archive.ubuntu.com/ubuntu"
readonly APT_ETC="${APT_ETC:-/etc/apt}"

readonly DEB_CACHE="${APT_DEB_CACHE:-}"
CACHE_OPTS=()
if [[ -n "$DEB_CACHE" ]]; then
  sudo mkdir -p "$DEB_CACHE/partial"
  CACHE_OPTS=(-o "Dir::Cache::archives=$DEB_CACHE")
fi
readonly CACHE_OPTS

# apt leaves partial/ private to its sandbox user, which the unprivileged cache save cannot read.
open_cache() {
  [[ -z "$DEB_CACHE" ]] || sudo chmod -R a+rX "$DEB_CACHE" || true
  return 0
}
trap open_cache EXIT

# Only the download is timed against the mirror: killing it never leaves a dpkg half done, which a killed install did when a slow mirror ran into the limit.
download() {
  timeout "$UPDATE_LIMIT" sudo apt-get "${APT_OPTS[@]}" update &&
    timeout "$DOWNLOAD_LIMIT" sudo apt-get "${APT_OPTS[@]}" "${CACHE_OPTS[@]}" install -y --no-install-recommends --download-only "$@"
  return
}

install_downloaded() {
  timeout "$INSTALL_LIMIT" sudo apt-get "${APT_OPTS[@]}" "${CACHE_OPTS[@]}" install -y --no-install-recommends "$@"
}

# A cache hit installs with no mirror at all; anything it cannot satisfy falls through to the network.
install_from_cache() {
  [[ -n "$DEB_CACHE" ]] || return 1
  local debs=("$DEB_CACHE"/*.deb)
  [[ -f "${debs[0]}" ]] || return 1
  # dpkg rather than apt: apt refuses a list of local .debs that depend on each other ("Pathname to install is not absolute").
  timeout "$INSTALL_LIMIT" sudo DEBIAN_FRONTEND=noninteractive dpkg -i "${debs[@]}"
}

# A cache that installed cleanly but missed a requested package is not a hit.
all_installed() {
  local installed
  installed=$(dpkg-query -W -f='${Status}\n' "$@" 2>/dev/null | grep -c "install ok installed")
  [[ "$installed" -eq $# ]]
}
if install_from_cache && all_installed "$@"; then
  exit 0
fi

# Runner images point their sources at a mirror list (mirror+file:), and apt only leaves its first entry on an error, never for being slow.
use_fallback_mirror() {
  local file sources=("$APT_ETC/sources.list" "$APT_ETC"/sources.list.d/*.list "$APT_ETC"/sources.list.d/*.sources)
  local mirror_lists=()
  mapfile -t mirror_lists < <(cat "${sources[@]}" 2>/dev/null | grep -oE 'mirror\+file:[^[:space:]]+' | sed 's#^mirror+file:##' | sort -u)
  for file in "${sources[@]}" "${mirror_lists[@]}"; do
    [[ -f "$file" ]] || continue
    sudo sed -i -E "s#https?://[a-z0-9.-]*\.archive\.ubuntu\.com/ubuntu/?#${FALLBACK}/#g" "$file"
  done
  return 0
}

# A dpkg killed mid-install leaves "dpkg was interrupted", which every later apt-get refuses until it is configured; a dpkg still running keeps the lock, so this retries until it lets go.
finish_interrupted_dpkg() {
  local deadline=$((SECONDS + 180))
  until timeout "$INSTALL_LIMIT" sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a; do
    ((SECONDS < deadline)) || return 0
    sleep 5
  done
}

if ! download "$@"; then
  echo "::warning::apt from the default mirror failed or stalled; retrying from ${FALLBACK}"
  finish_interrupted_dpkg
  use_fallback_mirror
  download "$@" || exit 1
fi
install_downloaded "$@"
