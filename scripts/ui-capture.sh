#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# One command for every screen the client can render, mobile and desktop
# widths, every theme that matters: a single set of PNGs plus a manifest and
# a contact sheet, for a reviewer to walk once rather than four times.
#
# This orchestrates existing test harnesses rather than adding new ones: the
# `ui_snapshot_*_test.dart` and `ui_overlay_snapshot_*_test.dart` files in the
# app package's test/ (resting screens and overlays: sheets, dialogs,
# popovers, gesture-opened menus), `test/visual/canvas_assembled_snapshot_
# test.dart` (the assembled canvas pane), and voice_canvas's `test/visual/
# canvas_visual_render.dart` (the canvas painters, no widget tree at all).
# Each already knows how to render its own surfaces; this only runs them with
# the right env var in the right directory and gathers what they wrote.
#
# A newly discovered screen, sheet or state does not need a change here: add
# it to the relevant harness's own table (`_surfaces` or `_overlays` in the
# app package's test/, a case in the voice_canvas visual scenes) and rerun.
# This script only grows when a whole new harness is added; see JOBS below.
#
# Usage: scripts/ui-capture.sh [category...]
#   No arguments captures everything. One or more of screens, overlays,
#   canvas-assembled, canvas-painters captures only those, leaving every
#   other category's images and report untouched from its last run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/ui-capture"
WORK="$OUT/_work"
mkdir -p "$OUT/images" "$WORK"
# A crash before the report step must not leave the last run's sheet looking current.
rm -f "$OUT/index.html" "$OUT/manifest.json"

# id|category|cwd (relative to ROOT)|env var|src dir (relative to cwd)|test file
JOBS=(
  "screens|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_test.dart"
  "screens-settings|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_settings_test.dart"
  "bot-buttons|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_bot_buttons_test.dart"
  "bot-ui|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_bot_ui_test.dart"
  "call-dock|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_call_dock_test.dart"
  "call-header|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_call_header_test.dart"
  "canvas-tool-options|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_canvas_tool_options_test.dart"
  "canvas-tools|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_canvas_tools_test.dart"
  "db-reset-notice|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_db_reset_notice_test.dart"
  "dock-sources|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_dock_sources_test.dart"
  "fullscreen-viewer|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_fullscreen_viewer_test.dart"
  "hold-music|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_hold_music_test.dart"
  "image-menu|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_image_menu_test.dart"
  "member-roster|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_member_roster_test.dart"
  "message-row|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_message_row_test.dart"
  "message-toolbar|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_message_toolbar_test.dart"
  "density|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_density_test.dart"
  "permissions-grid|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_permissions_grid_test.dart"
  "personal-panes|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_personal_panes_test.dart"
  "rail-avatars|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_rail_avatars_test.dart"
  "rail-declutter|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_rail_declutter_test.dart"
  "rail-status|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_rail_status_test.dart"
  "sign-in-matrix|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_sign_in_matrix_test.dart"
  "space-panes|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_space_panes_test.dart"
  "text-scale|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_text_scale_test.dart"
  "update-chip|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_update_chip_test.dart"
  "web-update|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_web_update_test.dart"
  "whats-new|screens|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_snapshot_whats_new_test.dart"
  "overlays|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_test.dart"
  "overlay-menus|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_menus_test.dart"
  "overlay-confirm|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_confirm_test.dart"
  "overlay-onboarding|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_onboarding_test.dart"
  "overlay-signin|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_signin_test.dart"
  "overlay-moderation|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_moderation_test.dart"
  "overlay-blocking|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_blocking_test.dart"
  "overlay-reports|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_reports_test.dart"
  "overlay-activity|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_activity_test.dart"
  "overlay-member-selection|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_member_selection_test.dart"
  "overlay-remove-from-channel|overlays|client/packages/app|SLIMM_UI_SNAPSHOTS|build/ui-snapshots|test/ui_overlay_snapshot_remove_from_channel_test.dart"
  "canvas-assembled|canvas-assembled|client/packages/app|SLIMM_CANVAS_ASSEMBLED|build/canvas-assembled-snapshots|test/visual/canvas_assembled_snapshot_test.dart"
  "canvas-painters|canvas-painters|client/packages/voice_canvas|SLIMM_CANVAS_VISUAL|build/canvas-visual|test/visual/canvas_visual_render.dart"
)

filter=("$@")

wanted() {
  local category="$1"
  [[ ${#filter[@]} -eq 0 ]] && return 0
  local c
  for c in "${filter[@]}"; do [[ "$c" == "$category" ]] && return 0; done
  return 1
}

declare -A cleaned_src=()
declare -A cleaned_dest=()
fail=0

# Every field a job needs, split from one JOBS entry.
run_job() {
  local id="$1" category="$2" rel_cwd="$3" env_name="$4" rel_src="$5" test_file="$6"
  local cwd="$ROOT/$rel_cwd"
  local src="$cwd/$rel_src"
  local dest="$OUT/images/$category"

  if [[ -z "${cleaned_src[$rel_cwd|$rel_src]:-}" ]]; then
    rm -rf "${src:?}"
    cleaned_src[$rel_cwd|$rel_src]=1
  fi
  if [[ -z "${cleaned_dest[$category]:-}" ]]; then
    rm -rf "${dest:?}"
    cleaned_dest[$category]=1
  fi
  mkdir -p "$dest"

  echo "== $id ($category) =="
  local marker="$WORK/$id.marker"
  touch "$marker"
  local json_log="$WORK/$id.json"
  rm -f "$json_log"
  local exit_code=0
  (cd "$cwd" && env "${env_name}=1" flutter test --reporter compact \
    --file-reporter="json:$json_log" "$test_file") || exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "ui-capture: $id exited $exit_code" >&2
    fail=1
  fi

  local n=0
  if [[ -d "$src" ]]; then
    while IFS= read -r -d '' f; do
      cp "$f" "$dest/"
      n=$((n + 1))
    done < <(find "$src" -maxdepth 1 -name '*.png' -newer "$marker" -print0)
  fi
  echo "$id: $n image(s)"

  cat >"$WORK/$id.meta" <<EOF
{"id":"$id","category":"$category","test_file":"$test_file","exit_code":$exit_code,"images":$n}
EOF
}

for job in "${JOBS[@]}"; do
  IFS='|' read -r id category rel_cwd env_name rel_src test_file <<<"$job"
  wanted "$category" || continue
  run_job "$id" "$category" "$rel_cwd" "$env_name" "$rel_src" "$test_file"
done

python3 "$ROOT/scripts/lib/ui_capture_report.py" --out "$OUT" --work "$WORK" || fail=1

echo
if [[ $fail -ne 0 ]]; then
  echo "ui-capture: FAILED, see $OUT/index.html for what did and did not render" >&2
  exit 1
fi
total=$(find "$OUT/images" -name '*.png' | wc -l)
echo "ui-capture: wrote $total image(s) to $OUT/images"
echo "open $OUT/index.html"
