// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share quality groups in the call dock's share menu, so a quality can
/// change without leaving the call. A live share restarts to pick it up where
/// it can do so without a prompt, and says otherwise where it cannot.
///
/// Each group is the same pick-one the Voice settings card edits, written
/// through the same notifier, so the two cannot disagree. The menu is
/// docs/design/desktop-vs-mobile.md rule 2 (picking one value for a control
/// that stays on screen), drawn by `ControlOptionsMenu` as an anchored menu
/// on a wide window and a sheet on a compact one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/live_quality_restart.dart';
import '../providers/voice_settings_controller.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart';
import 'share_resolution_support.dart';

/// Screen share resolution and frame rate, each as one line of tiles.
/// Watching and camera quality live in Voice settings only: they are not about the share this menu belongs to.
List<ControlOptionEntry> videoQualityOptions(WidgetRef ref) {
  final settings = ref.watch(voiceSettingsControllerProvider);
  final notifier = ref.read(voiceSettingsControllerProvider.notifier);
  final chosen = settings.screenShareQuality.resolution;
  final maxHeight = currentMaxShareHeight(ref, chosen);
  final shown = effectiveShareResolution(chosen, maxHeight);
  return [
    if (ref.watch(shareSettingsPendingProvider))
      const ControlOptionHeading(shareSettingsPendingNote),
    ControlSwatchGroup(
      heading: 'Resolution',
      swatches: [
        for (final r in ScreenShareResolution.values)
          ControlSwatch(
            label: r.label,
            selected: r == shown,
            disabledReason: shareResolutionSupported(r, maxHeight)
                ? null
                : shareResolutionTooHighReason,
            onSelected: () => notifier.setScreenShareResolution(r),
            mark: _TileLabel(r.label, selected: r == shown),
          ),
      ],
    ),
    ControlSwatchGroup(
      heading: 'Frame rate',
      swatches: [
        for (final f in ScreenShareFps.values)
          ControlSwatch(
            label: f.label,
            selected: f == settings.screenShareQuality.frameRate,
            onSelected: () => notifier.setScreenShareFps(f),
            mark: _TileLabel(
              f.label,
              selected: f == settings.screenShareQuality.frameRate,
            ),
          ),
      ],
    ),
  ];
}

class _TileLabel extends StatelessWidget {
  const _TileLabel(this.text, {required this.selected});

  final String text;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Text(
      text,
      style: AppText.caption.copyWith(
        color: selected ? tokens.textPrimary : tokens.textSecondary,
        fontWeight: selected ? AppWeights.medium : AppWeights.regular,
      ),
    );
  }
}
