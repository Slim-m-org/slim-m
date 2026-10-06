#!/bin/sh
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Lays this extracted bundle out as the per-user install that can update itself
# (docs/decisions/0041): ~/.local/share/slim-m/<version>/, a `current` symlink,
# and a slim-m launcher on ~/.local/bin. Touches nothing outside the home directory.
set -eu

here=$(dirname "$(readlink -f "$0")")
version=$(basename "$here" | sed -n 's/^slim-m-client-\([0-9][0-9.]*\)$/\1/p')
if [ -z "$version" ]; then
  echo "run this from the extracted slim-m-client-<version> directory" >&2
  exit 1
fi

root="${XDG_DATA_HOME:-$HOME/.local/share}/slim-m"
bin="${HOME}/.local/bin"
mkdir -p "$root" "$bin"

rm -rf "$root/.unpack-$version"
cp -a "$here" "$root/.unpack-$version"
rm -rf "${root:?}/$version"
mv "$root/.unpack-$version" "$root/$version"

ln -sfn "$version" "$root/.current.new"
mv -T "$root/.current.new" "$root/current"
ln -sfn "$root/current/slim-m" "$bin/slim-m"

data="${XDG_DATA_HOME:-$HOME/.local/share}"
desktop_id="top.npcserver.slimm.desktop"
if [ -f "$here/$desktop_id" ]; then
  mkdir -p "$data/applications"
  # Exec is absolute because a desktop session often has no ~/.local/bin on its PATH.
  awk -v exec_line="Exec=\"$bin/slim-m\" %u" '/^Exec=/ { print exec_line; next } { print }' \
    "$here/$desktop_id" > "$data/applications/$desktop_id"
  for icon in "$here"/icons/top.npcserver.slimm-*.png; do
    [ -f "$icon" ] || continue
    size=$(basename "$icon" .png | sed 's/^top\.npcserver\.slimm-//')
    mkdir -p "$data/icons/hicolor/${size}x${size}/apps"
    cp "$icon" "$data/icons/hicolor/${size}x${size}/apps/top.npcserver.slimm.png"
  done
  if [ -f "$here/icons/top.npcserver.slimm.svg" ]; then
    mkdir -p "$data/icons/hicolor/scalable/apps"
    cp "$here/icons/top.npcserver.slimm.svg" "$data/icons/hicolor/scalable/apps/top.npcserver.slimm.svg"
  fi
  # Registers slimm:// so an invite link or the Spotify sign-in redirect reaches this install.
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$data/applications" >/dev/null 2>&1 || true
  fi
  if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default "$desktop_id" x-scheme-handler/slimm || true
  fi
fi

echo "installed slim-m $version in $root; start it with $bin/slim-m"
