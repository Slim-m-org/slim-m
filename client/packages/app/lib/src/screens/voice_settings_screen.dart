// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice call preferences: microphone level, camera-on-join, screen share
/// quality, input/output device choice, and join/leave sounds.
///
/// The state these widgets read and write lives in
/// `providers/voice_settings_controller.dart`, split out once the
/// camera-on-join preference joined the other three.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import '../providers/voice_settings_controller.dart';
import '../widgets/audio_device_section.dart';
import '../widgets/camera_on_join_section.dart';
import '../widgets/media_capability_section.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_toggle_row.dart';

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
    children: [
      _MicrophoneSection(),
      _DevicesSection(),
      _ScreenShareSection(),
      _SoundsSection(),
    ],
  );
}

/// How readily the speaking indicator lights, over and above whatever the
/// SFU itself already decided; see `passesActivationThreshold` in the rtc
/// package for the exact floor. Not wired to the microphone's own capture -
/// checked against the pinned `livekit_client` 2.10.0 source before adding
/// this screen, and it exposes no adjustable noise-gate threshold at all,
/// only on/off capture toggles this client already leaves at their defaults.
class _SensitivitySection extends ConsumerWidget {
  const _SensitivitySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);

    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
          child: Text(
            'Voice activity sensitivity',
            style: AppText.ui.copyWith(color: tokens.textPrimary),
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
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

/// Desktop only: holding a physical key means nothing without one, and this
/// stays out of the tree entirely on a phone rather than offering a control
/// that could never do anything there.
class _PushToTalkSection extends ConsumerWidget {
  const _PushToTalkSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktopHost) return const SizedBox.shrink();
    final settings = ref.watch(voiceSettingsControllerProvider);
    final index = pushToTalkKeyOptions.indexOf(settings.pushToTalkKey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Hold a key to talk',
          description: 'Hold the key to unmute.',
          value: settings.pushToTalkEnabled,
          semanticLabel: 'Push-to-talk',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setPushToTalkEnabled(value),
        ),
        if (settings.pushToTalkEnabled) ...[
          const SizedBox(height: AppSpacing.s8),
          AppSegmentedControl.inline(
            semanticLabel: 'Push-to-talk key',
            options: [
              for (final key in pushToTalkKeyOptions)
                AppSegmentedOption(label: _keyLabel(key)),
            ],
            selectedIndex: index < 0 ? 0 : index,
            onSegmentSelected: (i) => ref
                .read(voiceSettingsControllerProvider.notifier)
                .setPushToTalkKey(pushToTalkKeyOptions[i]),
          ),
        ],
      ],
    );
  }

  static String _keyLabel(LogicalKeyboardKey key) => key.keyLabel;
}

/// A live level for the local microphone, sourced from the one real signal
/// `slimm_rtc` exposes: [VoiceParticipant.isSpeaking] on an active call's
/// local participant. There is no continuous amplitude in the package's
/// public API, so this is a two-level meter (quiet or speaking) rather than
/// a fabricated waveform, and it only reads live outside of a call once one
/// starts: there is nothing to meter before that.
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
    final speaking = inCall && (local?.isSpeaking ?? false);
    final muted = !inCall || (local?.isMuted ?? true);

    return SettingsSectionCard(
      title: 'Microphone',
      description: 'Your input level while you are in a call.',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: speaking ? _speakingLevel : _quietLevel),
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
        if (!inCall) ...[
          const SizedBox(height: AppSpacing.s8),
          const AppCallout(
            tone: AppCalloutTone.info,
            child: Text('Join a voice call to see your live input level here.'),
          ),
        ],
        const SizedBox(height: AppSpacing.s16),
        const _SensitivitySection(),
        if (isDesktopHost) ...[
          const SizedBox(height: AppSpacing.s16),
          const _PushToTalkSection(),
        ],
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
      description: 'What a call uses to hear, speak and show you.',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AudioDeviceSection(embedded: true),
        SizedBox(height: AppSpacing.s8),
        CameraOnJoinSection(embedded: true),
        SizedBox(height: AppSpacing.s8),
        MediaCapabilitySection(embedded: true),
      ],
    );
  }
}

class _ScreenShareSection extends ConsumerWidget {
  const _ScreenShareSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);
    final index = ScreenShareQuality.values.indexOf(
      settings.screenShareQuality,
    );
    // A plain getter, not provider state, so `ref.read` rather than `ref.watch`.
    final supportsAudio = ref
        .read(voiceControllerProvider.notifier)
        .supportsScreenShareAudio;

    return SettingsSectionCard(
      title: 'Screen share quality',
      description: 'A cap on resolution and frame rate, to protect call audio.',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSegmentedControl.inline(
          semanticLabel: 'Screen share quality',
          options: [
            for (final quality in ScreenShareQuality.values)
              AppSegmentedOption(label: _label(quality)),
          ],
          selectedIndex: index < 0 ? 1 : index,
          onSegmentSelected: (i) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setScreenShareQuality(ScreenShareQuality.values[i]),
        ),
        // Absent, never disabled, where this platform cannot publish it; see supportsScreenShareAudio.
        if (supportsAudio) ...[
          const SizedBox(height: AppSpacing.s8),
          SettingsToggleRow(
            label: 'Share device audio',
            value: settings.screenShareIncludeAudio,
            semanticLabel: 'Share audio with a screen share',
            onChanged: (value) => ref
                .read(voiceSettingsControllerProvider.notifier)
                .setScreenShareIncludeAudio(value),
          ),
        ],
      ],
    );
  }

  static String _label(ScreenShareQuality q) => switch (q) {
    ScreenShareQuality.smooth => 'Smooth',
    ScreenShareQuality.balanced => 'Balanced',
    ScreenShareQuality.crisp => 'Crisp',
  };
}

class _SoundsSection extends ConsumerWidget {
  const _SoundsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);

    return SettingsSectionCard(
      title: 'Sounds',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Join and leave sounds',
          description: 'Off automatically in busy calls.',
          value: settings.joinLeaveSoundsEnabled,
          semanticLabel: 'Play join and leave sounds',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setJoinLeaveSoundsEnabled(value),
        ),
        const SizedBox(height: AppSpacing.s8),
        SettingsToggleRow(
          label: 'Incoming call sound',
          value: settings.callRingSoundEnabled,
          semanticLabel: 'Play a sound for an incoming call',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setCallRingSoundEnabled(value),
        ),
        const SizedBox(height: AppSpacing.s8),
        SettingsToggleRow(
          label: 'Music while alone',
          value: settings.holdMusicEnabled,
          semanticLabel: 'Play hold music while alone in a call',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setHoldMusicEnabled(value),
        ),
      ],
    );
  }
}
