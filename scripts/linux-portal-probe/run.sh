#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Counts the xdg-desktop-portal ScreenCast sessions two screen shares open
# against a nested KWin. One chooser per share means exactly two sessions.
# FORK_PATH points the probe at a local flutter-webrtc checkout.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/portal-probe.XXXXXX")"
trap 'rm -rf "$work"' EXIT

ref="$(sed -n 's/^ *ref: *//p' "$repo/client/pubspec.yaml" | head -1)"
if [ -n "${FORK_PATH:-}" ]; then
  dep="    path: $FORK_PATH"
else
  dep="    git:
      url: https://github.com/Slim-m-org/flutter-webrtc.git
      ref: $ref"
fi

(cd "$work" && flutter create --platforms=linux --project-name portal_probe app >/dev/null)
cp "$here/probe.dart" "$work/app/lib/main.dart"
printf '  flutter_webrtc:\n%s\n' "$dep" >"$work/dep.txt"
sed -i "/^  flutter:\$/{n;r $work/dep.txt
}" "$work/app/pubspec.yaml"
(cd "$work/app" && flutter pub get >/dev/null && flutter build linux --debug >/dev/null)

cat >"$work/inner.sh" <<INNER
#!/usr/bin/env bash
export XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland
unset DISPLAY
kwin_wayland --virtual --socket slimm-portal-probe >"$work/kwin.log" 2>&1 &
kwin=\$!
sleep 4
export WAYLAND_DISPLAY=slimm-portal-probe
dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
dbus-monitor --session "interface='org.freedesktop.portal.ScreenCast'" >"$work/dbus.log" 2>&1 &
monitor=\$!
sleep 1
timeout 60 "$work/app/build/linux/x64/debug/bundle/portal_probe" >"$work/probe.log" 2>&1
kill "\$monitor" "\$kwin" 2>/dev/null || true
INNER
chmod +x "$work/inner.sh"

env -u DISPLAY -u WAYLAND_DISPLAY dbus-run-session -- "$work/inner.sh" || true

tracks="$(grep -c 'PROBE share . tracks=1' "$work/probe.log" || true)"
sessions="$(grep -c 'interface=org.freedesktop.portal.ScreenCast; member=CreateSession' "$work/dbus.log" || true)"
echo "shares started: $tracks, portal sessions opened: $sessions"
if [ "$tracks" != 2 ] || [ "$sessions" != 2 ]; then
  echo "FAIL: expected 2 shares and exactly 2 sessions (one chooser each)" >&2
  exit 1
fi
echo "PASS"
