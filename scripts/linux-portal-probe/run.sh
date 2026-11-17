#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Counts the xdg-desktop-portal ScreenCast sessions screen shares open against
# a nested KWin, and checks each share learns which monitor the portal picked. Cases: app (2 shares, 2 sessions), long (3 shares across a 35
# s gap, 3 sessions, nothing retried), noenum (1 share with no enumeration,
# 2 sessions, the unguarded path), window (a window list on Wayland comes
# back empty instead of aborting), nosession (the screen list with no X display
# and no session type, which segfaulted), noaudio (a call with no audio server
# is refused instead of aborting). FORK_PATH points at a local checkout.
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
# These cases launch the way a session that does not say it is Wayland does.
[ "\$1" = nosession ] && export XDG_SESSION_TYPE=tty
if [ "\$1" = noaudio ]; then
  : >"$work/alsa.conf"
  export PULSE_SERVER=unix:$work/missing.sock ALSA_CONFIG_PATH="$work/alsa.conf"
fi
# A nested KWin writes its output layout to the config dir; never the real one.
export XDG_CONFIG_HOME="$work/config"
mkdir -p "\$XDG_CONFIG_HOME"
unset DISPLAY
kwin_wayland --virtual --socket slimm-portal-probe >"$work/kwin.log" 2>&1 &
kwin=\$!
# The window opens on the compositor's socket, which takes a moment to appear.
for _ in \$(seq 50); do [ -S "\$XDG_RUNTIME_DIR/slimm-portal-probe" ] && break; sleep 0.2; done
sleep 1
export WAYLAND_DISPLAY=slimm-portal-probe
dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
dbus-monitor --session "interface='org.freedesktop.portal.ScreenCast'" >"$work/dbus-\$1.log" 2>&1 &
monitor=\$!
sleep 1
PROBE_MODE=\$1 timeout 120 "$work/app/build/linux/x64/debug/bundle/portal_probe" >"$work/probe-\$1.log" 2>&1
kill "\$monitor" "\$kwin" 2>/dev/null || true
INNER
chmod +x "$work/inner.sh"

status=0
check() {
  local mode="$1" shares="$2" sessions="$3" tracks opened
  env -u DISPLAY -u WAYLAND_DISPLAY dbus-run-session -- "$work/inner.sh" "$mode" >/dev/null 2>&1 || true
  tracks="$(grep -c 'PROBE share . tracks=1' "$work/probe-$mode.log" || true)"
  opened="$(grep -c 'interface=org.freedesktop.portal.ScreenCast; member=CreateSession' "$work/dbus-$mode.log" || true)"
  echo "$mode: shares started $tracks (want $shares), portal sessions $opened (want $sessions)"
  local placed
  placed="$(grep -c 'PROBE share . monitor={x: [0-9-]*, y: [0-9-]*' "$work/probe-$mode.log" || true)"
  echo "$mode: shares that knew their monitor $placed (want $shares)"
  if [ "$placed" != "$shares" ]; then
    status=1
  fi
  grep -iE 'error|critical|fail' "$work/probe-$mode.log" | grep -v 'a11y\|AT-SPI\|atk_socket\|bus can' | head -5 || true
  if [ "$tracks" != "$shares" ] || [ "$opened" != "$sessions" ]; then
    status=1
  fi
}

# A window list with no X display aborted the process; it must come back empty.
check_windows() {
  env -u DISPLAY -u WAYLAND_DISPLAY dbus-run-session -- "$work/inner.sh" window >/dev/null 2>&1 || true
  local listed survived
  listed="$(grep -c 'PROBE windows=0' "$work/probe-window.log" || true)"
  survived="$(grep -c 'PROBE done' "$work/probe-window.log" || true)"
  echo "window: empty list $listed (want 1), survived $survived (want 1)"
  if [ "$listed" != 1 ] || [ "$survived" != 1 ]; then
    status=1
  fi
}

# A screen list with no X display and no session type segfaulted libwebrtc.
check_survives() {
  env -u DISPLAY -u WAYLAND_DISPLAY dbus-run-session -- "$work/inner.sh" "$1" >/dev/null 2>&1 || true
  local seen survived
  seen="$(grep -c "$2" "$work/probe-$1.log" || true)"
  survived="$(grep -c 'PROBE done' "$work/probe-$1.log" || true)"
  echo "$1: $3 $seen (want $4), survived $survived (want 1)"
  if [ "$seen" != "$4" ] || [ "$survived" != 1 ]; then
    status=1
  fi
}

check app 2 2
check noenum 1 2
check long 3 3
check_windows
check_survives nosession 'PROBE listed=1' 'screens listed' 1
check_survives noaudio 'PROBE refusal=.*No audio server is running' 'calls refused' 2
if [ "$status" != 0 ]; then
  echo "FAIL" >&2
  exit 1
fi
echo "PASS"
