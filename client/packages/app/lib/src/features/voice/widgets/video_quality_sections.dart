// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video quality card of Voice settings: what you watch, what your camera
/// sends, and the resolution and frame rate of a screen share.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show OverlayCorner;
import 'package:slimm_rtc/rtc.dart';

import '../../screen_overlay/providers/screen_overlay_controller.dart'
    show screenOverlaySupportedProvider;
import '../providers/live_quality_restart.dart'
    show shareSettingsPendingNote, shareSettingsPendingProvider;
import '../providers/video_pause.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import 'pause_video_section.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../settings/widgets/settings_segmented_row.dart';
import '../../settings/widgets/settings_select_row.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import 'share_resolution_support.dart';
import 'video_quality_labels.dart';

class VideoQualitySection extends ConsumerWidget {
  const VideoQualitySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);
    final notifier = ref.read(voiceSettingsControllerProvider.notifier);
    // A plain getter, not provider state, so `ref.read` rather than `ref.watch`.
    final note = ref.watch(shareSettingsPendingProvider)
        ? shareSettingsPendingNote
        : null;
    final maxShareHeight = currentMaxShareHeight(
      ref,
      settings.screenShareQuality.resolution,
    );
    final supportsAudio = ref
        .read(voiceControllerProvider.notifier)
        .share
        .supportsAudio;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Video quality',
          description: 'Lower it to save data, raise it to see more.',
          children: [
            _QualityRow<ReceiveVideoQuality>(
              label: 'Watching',
              description: receiveVideoQualityNote(
                settings.receiveVideoQuality,
              ),
              values: ReceiveVideoQuality.values,
              selected: settings.receiveVideoQuality,
              nameOf: receiveVideoQualityLabel,
              onSelected: notifier.setReceiveVideoQuality,
            ),
            _QualityRow<CameraQuality>(
              label: 'Your camera',
              description: 'Sharpness of the camera video you send.',
              values: CameraQuality.values,
              selected: settings.cameraQuality,
              nameOf: cameraQualityLabel,
              onSelected: notifier.setCameraQuality,
            ),
            _QualityRow<ScreenShareResolution>(
              label: 'Screen share resolution',
              description: note,
              footnote: shareResolutionNote(maxShareHeight),
              values: ScreenShareResolution.values,
              selected: effectiveShareResolution(
                settings.screenShareQuality.resolution,
                maxShareHeight,
              ),
              nameOf: (r) => r.label,
              disabledReasonOf: (r) =>
                  shareResolutionSupported(r, maxShareHeight)
                  ? null
                  : shareResolutionTooHighReason,
              onSelected: notifier.setScreenShareResolution,
            ),
            _QualityRow<ScreenShareFps>(
              label: 'Screen share frame rate',
              description: note,
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
                description: note ?? 'Includes sound playing on this device.',
                value: settings.screenShareIncludeAudio,
                semanticLabel: 'Share audio with a screen share',
                onChanged: notifier.setScreenShareIncludeAudio,
              ),
            SettingsToggleRow(
              label: 'Viewers draw on my screen',
              description:
                  'Their marks show on the screen you share for a few seconds.',
              value: settings.screenShareAllowAnnotations,
              semanticLabel: 'Let viewers draw on the screen I share',
              onChanged: notifier.setScreenShareAllowAnnotations,
            ),
            // Absent, never disabled, on a desktop that cannot host the overlay window; see decision 0096.
            if (ref.watch(screenOverlaySupportedProvider)) ...[
              SettingsToggleRow(
                label: 'Call overlay',
                description:
                    'Lists who is in the call over your other windows.',
                value: settings.callOverlayEnabled,
                semanticLabel: 'Show the call over my other windows',
                onChanged: notifier.setCallOverlayEnabled,
              ),
              if (settings.callOverlayEnabled)
                SettingsSegmentedRow<OverlayCorner>(
                  label: 'Overlay position',
                  value: settings.callOverlayCorner,
                  choices: [
                    for (final c in OverlayCorner.values)
                      SettingsChoice(value: c, label: c.label),
                  ],
                  onChanged: notifier.setCallOverlayCorner,
                ),
            ],
            if (ref.watch(pauseOnUnfocusedAppliesProvider))
              const PauseVideoRow(),
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
    this.footnote,
    this.disabledReasonOf,
  });

  final String label;
  final String? description;
  final String? footnote;
  final List<T> values;
  final T selected;
  final String Function(T value) nameOf;
  final ValueChanged<T> onSelected;
  final String? Function(T value)? disabledReasonOf;

  @override
  Widget build(BuildContext context) => SettingsSegmentedRow<T>(
    label: label,
    description: description,
    footnote: footnote,
    value: selected,
    choices: [
      for (final v in values)
        SettingsChoice(
          value: v,
          label: nameOf(v),
          disabledReason: disabledReasonOf?.call(v),
        ),
    ],
    onChanged: onSelected,
  );
}
