// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone card where the host gates the input natively: a live meter
/// with the gate threshold as its draggable line, and the loud-sound toggle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'mic_preview_hold.dart';
import 'mic_trouble_notice.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/mic_preview.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart';
import '../../settings/widgets/settings_toggle_row.dart';

class InputSensitivityMeter extends ConsumerWidget {
  const InputSensitivityMeter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final manual = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.inputThresholdDb),
    );
    final auto = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.inputThresholdAuto),
    );
    final live = ref.watch(autoInputThresholdProvider).valueOrNull;
    final threshold = auto ? (live ?? manual) : manual;
    final flags = ref.watch(voiceFlagsProvider);
    final inCall = flags.state == VoiceSessionState.connected;
    final reading = ref.watch(inputGateReadingProvider).valueOrNull;
    final preview = inCall ? null : ref.watch(micMeterProvider);
    final level = inCall ? reading?.levelDb : preview?.levelDb;
    final voice = inCall ? reading?.voice : preview?.voice;
    return MicPreviewHold(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Input sensitivity',
              style: AppText.ui.copyWith(color: tokens.textPrimary),
            ),
            // Room for the value bubble that rises over the thumb.
            const SizedBox(height: AppSpacing.s32),
            AppSlider(
              tall: true,
              splitTrack: true,
              valueLabel: (db) => '${db.round()} dB',
              value: threshold,
              min: kInputFloorDb,
              max: 0,
              meter: level == null ? 0 : inputLevelFraction(level) * 100,
              meterActive: voice ?? false,
              muted: inCall ? !flags.microphoneEnabled : level == null,
              semanticLabel: 'Input sensitivity',
              onChanged: auto
                  ? null
                  : (db) => ref
                        .read(voiceSettingsControllerProvider.notifier)
                        .setInputThreshold(db),
            ),
            if (preview?.status == MicPreviewStatus.unavailable)
              const MicTroubleNotice(
                padding: EdgeInsets.only(top: AppSpacing.s8),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lets the gate follow the room's noise floor instead of the slider.
class AutoSensitivityToggle extends ConsumerWidget {
  const AutoSensitivityToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.inputThresholdAuto),
    );
    return SettingsToggleRow(
      label: 'Automatic sensitivity',
      description: 'Follows the background noise in your room.',
      value: enabled,
      semanticLabel: 'Automatic sensitivity',
      onChanged: (value) => ref
          .read(voiceSettingsControllerProvider.notifier)
          .setInputThresholdAuto(value),
    );
  }
}

/// The compressor and limiter after the gate, on the same hosts.
class EvenOutLoudSoundsToggle extends ConsumerWidget {
  const EvenOutLoudSoundsToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.evenOutLoudSounds),
    );
    return SettingsToggleRow(
      label: 'Even out loud sounds',
      description: 'Softens shouts and sudden bangs before others hear them.',
      value: enabled,
      semanticLabel: 'Even out loud sounds',
      onChanged: (value) => ref
          .read(voiceSettingsControllerProvider.notifier)
          .setEvenOutLoudSounds(value),
    );
  }
}

/// Whether this host's calls go through the native gate.
bool hostHasInputGate(WidgetRef ref) =>
    ref.read(voiceControllerProvider.notifier).supportsInputGate;
