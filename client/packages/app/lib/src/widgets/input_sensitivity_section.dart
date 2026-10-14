// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone card where the host gates the input natively: a live meter
/// with the gate threshold as its draggable line.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart';

class InputSensitivityMeter extends ConsumerWidget {
  const InputSensitivityMeter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final threshold = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.inputThresholdDb),
    );
    final flags = ref.watch(voiceFlagsProvider);
    final inCall = flags.state == VoiceSessionState.connected;
    final reading = ref.watch(inputGateReadingProvider).valueOrNull;
    final level = inCall ? reading?.levelDb : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                '${threshold.round()} dB',
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
          onChanged: (db) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setInputThreshold(db),
        ),
      ],
    );
  }
}

/// Whether this host's calls go through the native gate.
bool hostHasInputGate(WidgetRef ref) =>
    ref.read(voiceControllerProvider.notifier).supportsInputGate;
