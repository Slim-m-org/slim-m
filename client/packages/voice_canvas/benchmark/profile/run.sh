#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Builds profile_main.dart as a profile-mode Linux app and runs it inside a
# nested compositor of its own, so no window ever opens on a real display.
# Results land in $CANVAS_PERF_OUT/profile_<phases>.json; PROFILE_PHASES picks
# "specs", "sweep" or both (the default). It exits non-zero when a row is past
# the raster budget; see check_budget.py.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/../.." && pwd)"
bench="$pkg/benchmark"
work="${PROFILE_WORK:-${TMPDIR:-/tmp}/canvas-profile-work}"
out="${CANVAS_PERF_OUT:-$work/out}"
socket="canvas-perf-$$"
mkdir -p "$work" "$out"

if [[ ! -d "$work/app" ]]; then
  (cd "$work" && flutter create --platforms=linux --project-name canvas_perf app >/dev/null)
  sed -i 's/1280, 720/1600, 900/' "$work/app/linux/runner/my_application.cc"
  printf '  slimm_voice_canvas:\n    path: %s\n' "$pkg" >"$work/dep.txt"
  sed -i "/^  flutter:\$/{n;r $work/dep.txt
}" "$work/app/pubspec.yaml"
fi
sed "s|'../|'|" "$here/profile_main.dart" >"$work/app/lib/main.dart"
cp "$bench/board_fixture.dart" "$bench/perf_support.dart" "$work/app/lib/"
(cd "$work/app" && flutter pub get >/dev/null && flutter build linux --profile >/dev/null)

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
kwin_wayland --virtual --socket "$socket" --no-lockscreen --width 1600 --height 900 >"$out/kwin.log" 2>&1 &
kwin=\$!
sleep 5
export WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland CANVAS_PERF_OUT="$out"
timeout "\${PROFILE_TIMEOUT:-900}" "$work/app/build/linux/x64/profile/bundle/canvas_perf" >"$out/app.log" 2>&1 || true
kill "\$kwin" 2>/dev/null || true
INNER
chmod +x "$work/inner.sh"
env -u DISPLAY -u WAYLAND_DISPLAY dbus-run-session -- "$work/inner.sh" >/dev/null 2>&1 || true
grep -E '^(pan|zoom|repaint|draw|remote|sweep|bitmap|objects)|DONE' "$out/app.log" || {
  echo "no results; tail of app.log:" >&2
  tail -20 "$out/app.log" >&2
  exit 1
}
python3 "$here/check_budget.py" "$out"/profile_*.json
