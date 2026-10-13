// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video quality card of Voice settings: what you watch, what your camera
/// sends, and what a screen share sends.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';
import 'video_quality_labels.dart';

class VideoQualitySection extends ConsumerWidget {
  const VideoQualitySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);
    final notifier = ref.read(voiceSettingsControllerProvider.notifier);
    // A plain getter, not provider state, so `ref.read` rather than `ref.watch`.
    final supportsAudio = ref
        .read(voiceControllerProvider.notifier)
        .supportsScreenShareAudio;

    return SettingsSectionCard(
      title: 'Video quality',
      description: 'Lower it to save data, raise it to see more.',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _QualityRow<ReceiveVideoQuality>(
          label: 'Watching',
          values: ReceiveVideoQuality.values,
          selected: settings.receiveVideoQuality,
          nameOf: receiveVideoQualityLabel,
          onSelected: notifier.setReceiveVideoQuality,
        ),
        const SizedBox(height: AppSpacing.s12),
        _QualityRow<CameraQuality>(
          label: 'Your camera',
          values: CameraQuality.values,
          selected: settings.cameraQuality,
          nameOf: cameraQualityLabel,
          onSelected: notifier.setCameraQuality,
        ),
        const SizedBox(height: AppSpacing.s12),
        _QualityRow<ScreenShareQuality>(
          label: 'Screen share',
          values: ScreenShareQuality.values,
          selected: settings.screenShareQuality,
          nameOf: screenShareQualityLabel,
          onSelected: notifier.setScreenShareQuality,
        ),
        // Absent, never disabled, where this platform cannot publish it; see supportsScreenShareAudio.
        if (supportsAudio) ...[
          const SizedBox(height: AppSpacing.s8),
          SettingsToggleRow(
            label: 'Share device audio',
            value: settings.screenShareIncludeAudio,
            semanticLabel: 'Share audio with a screen share',
            onChanged: notifier.setScreenShareIncludeAudio,
          ),
        ],
      ],
    );
  }
}

class _QualityRow<T> extends StatelessWidget {
  const _QualityRow({
    required this.label,
    required this.values,
    required this.selected,
    required this.nameOf,
    required this.onSelected,
  });

  final String label;
  final List<T> values;
  final T selected;
  final String Function(T value) nameOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
          child: Text(
            label,
            style: AppText.ui.copyWith(color: tokens.textPrimary),
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        AppSegmentedControl.inline(
          semanticLabel: '$label quality',
          options: [
            for (final v in values) AppSegmentedOption(label: nameOf(v)),
          ],
          selectedIndex: values.indexOf(selected),
          onSegmentSelected: (i) => onSelected(values[i]),
        ),
      ],
    );
  }
}
