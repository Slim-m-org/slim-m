// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video quality groups in the call dock's share menu, so a quality can
/// change without leaving the call.
///
/// Each group is the same pick-one the Voice settings cards edit, written
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
import '../widgets/video_quality_labels.dart';

/// Watching, camera and screen share quality, in the order a person thinks of
/// them: what they see, then what they send.
List<ControlOptionEntry> videoQualityOptions(WidgetRef ref) {
  final settings = ref.watch(voiceSettingsControllerProvider);
  final notifier = ref.read(voiceSettingsControllerProvider.notifier);
  return [
    const ControlOptionHeading('Watching quality'),
    for (final q in ReceiveVideoQuality.values)
      ControlOption(
        label: receiveVideoQualityLabel(q),
        selected: q == settings.receiveVideoQuality,
        onSelected: () => notifier.setReceiveVideoQuality(q),
      ),
    const ControlOptionHeading('Camera quality'),
    for (final q in CameraQuality.values)
      ControlOption(
        label: cameraQualityLabel(q),
        selected: q == settings.cameraQuality,
        onSelected: () => notifier.setCameraQuality(q),
      ),
    const ControlOptionHeading('Screen share quality'),
    for (final q in ScreenShareQuality.values)
      ControlOption(
        label: screenShareQualityLabel(q),
        selected: q == settings.screenShareQuality,
        onSelected: () => notifier.setScreenShareQuality(q),
      ),
  ];
}
