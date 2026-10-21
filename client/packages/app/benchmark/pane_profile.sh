#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Builds pane_profile_main.dart as a profile-mode Linux app and runs it inside
# a nested compositor of its own, so no window ever opens on a real display.
# Results land in $CANVAS_PERF_OUT/pane_profile_<phases>.json; PANE_PHASES picks
# "scenarios", "open", "session" or a comma list (default scenarios), and
# PANE_SESSION_S sets the session length in seconds (default 300).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$here/.." && pwd)"
work="${PROFILE_WORK:-${TMPDIR:-/tmp}/canvas-pane-profile-work}"
out="${CANVAS_PERF_OUT:-$work/out}"
socket="canvas-pane-perf-$$"
mkdir -p "$work" "$out"

(cd "$app" && flutter build linux --profile -t benchmark/pane_profile_main.dart >/dev/null)

private="$(mktemp -d "$work/xdg.XXXXXX")"
trap 'rm -rf "$private"' EXIT
mkdir -p "$private/config" "$private/data" "$private/cache" "$private/state" "$private/run"
chmod 700 "$private/run"

cat >"$work/inner.sh" <<INNER
#!/usr/bin/env bash
export XDG_CONFIG_HOME="$private/config" XDG_DATA_HOME="$private/data"
export XDG_CACHE_HOME="$private/cache" XDG_STATE_HOME="$private/state"
export XDG_RUNTIME_DIR="$private/run" XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland
unset DISPLAY WAYLAND_DISPLAY
kwin_wayland --virtual --socket "$socket" --no-lockscreen --width 1600 --height 1000 >"$out/kwin.log" 2>&1 &
kwin=\$!
sleep 5
export WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland CANVAS_PERF_OUT="$out"
timeout "\${PROFILE_TIMEOUT:-1200}" "$app/build/linux/x64/profile/bundle/slimm_app" >"$out/app.log" 2>&1 || true
kill "\$kwin" 2>/dev/null || true
INNER
chmod +x "$work/inner.sh"
env -u DISPLAY -u WAYLAND_DISPLAY dbus-run-session -- "$work/inner.sh" >/dev/null 2>&1 || true
grep -E "^(pan|zoom|drag|remote|someone|draw|open|session|smoke)|DONE" "$out/app.log" || {
  echo "no results; tail of app.log:" >&2
  tail -20 "$out/app.log" >&2
  exit 1
}
