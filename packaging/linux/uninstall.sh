#!/bin/sh
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Removes what install.sh laid out under the home directory: the versions, the
# launcher link, the desktop entry, the icons and the start-on-login entry.
# Your data (sign-in, local databases, settings) stays unless --remove-data is given.
set -eu

remove_data=0
for arg in "$@"; do
  case "$arg" in
    --remove-data) remove_data=1 ;;
    *)
      echo "usage: uninstall.sh [--remove-data]" >&2
      exit 1
      ;;
  esac
done

data="${XDG_DATA_HOME:-$HOME/.local/share}"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
root="$data/slim-m"
bin="$HOME/.local/bin/slim-m"
desktop_id="top.npcserver.slimm.desktop"

# The link is ours only while it points into the install; anything else is the person's.
case "$(readlink "$bin" 2>/dev/null || true)" in
  "$root"/*) rm -f "$bin" ;;
esac

rm -f "$data/applications/$desktop_id" "$config/autostart/$desktop_id"
rm -f "$data"/icons/hicolor/*/apps/top.npcserver.slimm.png "$data/icons/hicolor/scalable/apps/top.npcserver.slimm.svg"
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$data/applications" >/dev/null 2>&1 || true
fi

rm -rf "${root:?}"

if [ "$remove_data" = 1 ]; then
  rm -rf "${data:?}/top.npcserver.slimm" "${data:?}/top.npcserver/slim-m" "${data:?}/top.npcserver/slimm"
  # The company folder is shared, so it goes only once nothing else lives in it.
  rmdir "$data/top.npcserver" 2>/dev/null || true
fi

echo "removed slim-m from $root"
if [ "$remove_data" = 0 ]; then
  echo "your data is kept; run this again with --remove-data to delete it too"
fi
