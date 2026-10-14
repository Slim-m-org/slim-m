// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone card where the host gates the input natively: a live meter
/// with the gate threshold as its draggable line, and the loud-sound toggle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart';
import 'settings_toggle_row.dart';

class InputSensitivityMeter extends ConsumerWidget {
  const InputSensitivityMeter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final manual = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.inputThresholdDb),
    );
    final automatic = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.autoInputThreshold),
    );
    final live = ref.watch(autoInputThresholdProvider);
    final threshold = automatic ? (live ?? manual) : manual;
    final flags = ref.watch(voiceFlagsProvider);
    final inCall = flags.state == VoiceSessionState.connected;
    final reading = ref.watch(inputGateReadingProvider).valueOrNull;
    final level = inCall ? reading?.levelDb : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Set sensitivity automatically',
          description: "Follows your room's background noise.",
          value: automatic,
          semanticLabel: 'Set input sensitivity automatically',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setAutoInputThreshold(value),
        ),
        const SizedBox(height: AppSpacing.s8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Input sensitivity',
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
              Text(
                automatic && live == null
                    ? 'Listening'
                    : '${threshold.round()} dB',
                style: AppText.code.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        AppSlider(
          tall: true,
          value: threshold,
          min: kInputFloorDb,
          max: 0,
          meter: level == null ? 0 : inputLevelFraction(level) * 100,
          muted: !inCall || !flags.microphoneEnabled,
          semanticLabel: 'Input sensitivity',
          onChanged: automatic
              ? null
              : (db) => ref
                    .read(voiceSettingsControllerProvider.notifier)
                    .setInputThreshold(db),
        ),
      ],
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
