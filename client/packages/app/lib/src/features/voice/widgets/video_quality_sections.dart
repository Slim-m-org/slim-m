// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video quality card of Voice settings: what you watch, what your camera
/// sends, and the resolution and frame rate of a screen share.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/video_pause.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import '../../../routing/routes.dart';
import 'pause_video_section.dart';
import '../../../widgets/settings_section_header.dart';
import '../../../widgets/settings_segmented_row.dart';
import '../../../widgets/settings_select_row.dart';
import '../../../widgets/settings_toggle_row.dart';
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

    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Video quality',
          description: 'Lower it to save data, raise it to see more.',
          children: [
            _QualityRow<ReceiveVideoQuality>(
              label: 'Watching',
              description: 'Video and screens from others.',
              values: ReceiveVideoQuality.values,
              selected: settings.receiveVideoQuality,
              nameOf: receiveVideoQualityLabel,
              onSelected: notifier.setReceiveVideoQuality,
            ),
            _QualityRow<CameraQuality>(
              label: 'Your camera',
              values: CameraQuality.values,
              selected: settings.cameraQuality,
              nameOf: cameraQualityLabel,
              onSelected: notifier.setCameraQuality,
            ),
            _QualityRow<ScreenShareResolution>(
              label: 'Screen share resolution',
              values: ScreenShareResolution.values,
              selected: settings.screenShareQuality.resolution,
              nameOf: (r) => r.label,
              onSelected: notifier.setScreenShareResolution,
            ),
            _QualityRow<ScreenShareFps>(
              label: 'Screen share frame rate',
              values: ScreenShareFps.values,
              selected: settings.screenShareQuality.frameRate,
              nameOf: (f) => f.label,
              onSelected: notifier.setScreenShareFps,
            ),
          ],
        ),
        SettingsSectionCard(
          title: 'Sharing and preview',
          children: [
            // Absent, never disabled, where this platform cannot publish it; see supportsScreenShareAudio.
            if (supportsAudio)
              SettingsToggleRow(
                label: 'Share device audio',
                value: settings.screenShareIncludeAudio,
                semanticLabel: 'Share audio with a screen share',
                onChanged: notifier.setScreenShareIncludeAudio,
              ),
            if (ref.watch(pauseOnUnfocusedAppliesProvider))
              const PauseVideoRow(),
            AppListRow(
              leading: Container(
                width: AppSizes.controlLg,
                height: AppSizes.controlLg,
                decoration: BoxDecoration(
                  border: Border.all(color: tokens.borderSubtle),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Icon(
                  AppIcons.requestLatency,
                  size: AppSizes.icon20,
                  color: tokens.textSecondary,
                ),
              ),
              label: 'Call stats',
              subtitle: 'Live video numbers for a call.',
              trailing: Icon(
                AppIcons.chevronRight,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              onTap: () => context.push(Routes.callStats),
            ),
          ],
        ),
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
    this.description,
  });

  final String label;
  final String? description;
  final List<T> values;
  final T selected;
  final String Function(T value) nameOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => SettingsSegmentedRow<T>(
    label: label,
    description: description,
    value: selected,
    choices: [
      for (final v in values) SettingsChoice(value: v, label: nameOf(v)),
    ],
    onChanged: onSelected,
  );
}
