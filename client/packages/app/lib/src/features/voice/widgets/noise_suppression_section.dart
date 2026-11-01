// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Standard, Strong or Strongest noise suppression, in the microphone card on a host
/// with the native capture chain.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/noise_suppression.dart';
import '../providers/strong_noise_status.dart';
import '../../settings/widgets/settings_select_row.dart';

class NoiseSuppressionSection extends ConsumerWidget {
  const NoiseSuppressionSection({super.key});

  static const _labels = {
    NoiseSuppressionChoice.spaceDefault: 'Space default',
    NoiseSuppressionChoice.standard: 'Standard',
    NoiseSuppressionChoice.strong: 'Strong',
    NoiseSuppressionChoice.strongest: 'Strongest',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(noiseSuppressionProvider);
    final spaceStrong =
        ref.watch(spaceStrongNoiseSuppressionProvider).valueOrNull ?? false;
    final description = switch (choice) {
      NoiseSuppressionChoice.spaceDefault =>
        'This Space uses ${spaceStrong ? 'Strong' : 'Standard'}.',
      NoiseSuppressionChoice.strongest =>
        'Strongest removes the most noise and uses more CPU.',
      _ => 'Strong also removes keyboards, fans and room noise.',
    };
    final strongInactive = ref.watch(strongNoiseInactiveProvider);
    final supported = ref.watch(strongestSupportedProvider);
    final name = choice == NoiseSuppressionChoice.strongest && supported
        ? 'Strongest'
        : 'Strong';
    return SettingsSelectRow<NoiseSuppressionChoice>(
      label: 'Noise suppression',
      description: strongInactive
          ? "$name isn't running on this mic."
          : description,
      value: choice,
      choices: [
        for (final value in NoiseSuppressionChoice.offered(
          supported: supported,
        ))
          SettingsChoice(value: value, label: _labels[value]!),
      ],
      onChanged: (v) => ref.read(noiseSuppressionProvider.notifier).set(v),
    );
  }
}
