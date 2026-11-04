// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice call preferences: microphone level, camera-on-join, screen share
/// quality and input/output device choice. Call sounds live under Notifications, shortcuts under Desktop.
///
/// The state these widgets read and write lives in
/// `providers/voice_settings_controller.dart`, split out once the
/// camera-on-join preference joined the other three.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import '../widgets/mic_preview_hold.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/mic_preview.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import '../widgets/audio_device_section.dart';
import '../widgets/mic_trouble_notice.dart';
import '../widgets/camera_on_join_section.dart';
import '../widgets/input_sensitivity_section.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../widgets/video_quality_sections.dart';
import '../widgets/noise_suppression_section.dart';
import '../widgets/voice_processing_section.dart';

/// Everything about a call this device controls, as a pane body.
///
/// No scaffold of its own: it used to be a screen behind
/// `Routes.voiceSettings`, reached by one row inside personal settings, which
/// is a second route for a category rather than a category. It is the Calls
/// pane of [PersonalSettingsScreen] now, and the route is gone.
class VoiceSettingsBody extends StatelessWidget {
  const VoiceSettingsBody({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    children: [_MicrophoneSection(), _DevicesSection(), VideoQualitySection()],
  );
}

/// Said under the slider: it never changes what anyone else hears.
const sensitivityDescription = 'Only changes your own speaking ring.';

/// How readily the speaking indicator lights, over and above whatever the
/// SFU itself already decided; see `passesActivationThreshold` in the rtc
/// package for the exact floor. Not wired to the microphone's own capture -
/// checked against the pinned `livekit_client` 2.13.1 source before adding
/// this screen, and it exposes no adjustable noise-gate threshold at all,
/// only on/off capture toggles this client already leaves at their defaults.
class _SensitivitySection extends ConsumerWidget {
  const _SensitivitySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);

    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsCardBlock(
      gap: AppSpacing.s8,
      children: [
        Text(
          'Voice activity sensitivity',
          style: AppText.ui.copyWith(color: tokens.textPrimary),
        ),
        Text(
          sensitivityDescription,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        AppSlider(
          value: settings.voiceActivitySensitivity,
          ticks: const ['Strict', 'Moderate', 'Loose'],
          semanticLabel: 'Voice activity sensitivity',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setVoiceActivitySensitivity(value),
        ),
      ],
    );
  }
}

/// A live level for the local microphone: the native gate's own reading on a
/// host that has one, otherwise the call's speaking flag as a two-level meter
/// in a call and the preview capture's measured level outside one.
class _MicrophoneSection extends ConsumerWidget {
  const _MicrophoneSection();

  static const _quietLevel = 6.0;
  static const _speakingLevel = 82.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceControllerProvider);
    final inCall = voice.state == VoiceSessionState.connected;

    VoiceParticipant? local;
    for (final p in voice.participants) {
      if (p.isLocal) {
        local = p;
        break;
      }
    }
    final preview = inCall ? null : ref.watch(micMeterProvider);
    final speaking = inCall && (local?.isSpeaking ?? false);
    final muted = inCall
        ? (local?.isMuted ?? true)
        : preview?.status != MicPreviewStatus.live;

    if (hostHasInputGate(ref)) {
      return const SettingsSectionCard(
        title: 'Microphone',
        description: 'Sound below the line is not sent.',
        children: [
          InputSensitivityMeter(),
          AutoSensitivityToggle(),
          NoiseSuppressionSection(),
          EvenOutLoudSoundsToggle(),
          VoiceProcessingSection(),
        ],
      );
    }

    return SettingsSectionCard(
      title: 'Microphone',
      children: [
        MicPreviewHold(
          child: SettingsCardBlock(
            gap: AppSpacing.s8,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(
                  end: preview == null
                      ? (speaking ? _speakingLevel : _quietLevel)
                      : preview.fraction * 100,
                ),
                duration: AppMotion.reduced(
                  context,
                  const Duration(milliseconds: 200),
                ),
                builder: (context, level, _) => AppSlider(
                  tall: true,
                  value: 0,
                  onChanged: null,
                  meter: level,
                  muted: muted,
                  semanticLabel: 'Microphone input level',
                ),
              ),
              if (preview?.status == MicPreviewStatus.unavailable)
                const MicTroubleNotice(padding: EdgeInsets.zero),
            ],
          ),
        ),
        const _SensitivitySection(),
      ],
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection();

  @override
  Widget build(BuildContext context) {
    return const SettingsSectionCard(
      title: 'Devices',
      children: [
        AudioDeviceSection(embedded: true),
        CameraOnJoinSection(embedded: true),
        MirrorSelfViewRow(),
      ],
    );
  }
}
