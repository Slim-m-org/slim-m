// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share quality groups in the call dock's share menu, so a quality can
/// change without leaving the call.
///
/// Each group is the same pick-one the Voice settings card edits, written
/// through the same notifier, so the two cannot disagree. The menu is
/// docs/design/desktop-vs-mobile.md rule 2 (picking one value for a control
/// that stays on screen), drawn by `ControlOptionsMenu` as an anchored menu
/// on a wide window and a sheet on a compact one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_settings_controller.dart';
import '../widgets/control_options_menu.dart';
import '../widgets/control_swatch_row.dart';

/// Screen share resolution and frame rate. Watching and camera quality live
/// in Voice settings only: they are not about the share this menu belongs to.
List<ControlOptionEntry> videoQualityOptions(WidgetRef ref) {
  final settings = ref.watch(voiceSettingsControllerProvider);
  final notifier = ref.read(voiceSettingsControllerProvider.notifier);
  return [
    const ControlOptionHeading('Resolution'),
    for (final r in ScreenShareResolution.values)
      ControlOption(
        label: r.label,
        selected: r == settings.screenShareQuality.resolution,
        onSelected: () => notifier.setScreenShareResolution(r),
      ),
    const ControlOptionHeading('Frame rate'),
    for (final f in ScreenShareFps.values)
      ControlOption(
        label: f.label,
        selected: f == settings.screenShareQuality.frameRate,
        onSelected: () => notifier.setScreenShareFps(f),
      ),
  ];
}
