// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Standard or strong noise suppression, in the microphone card on a host
/// with the native capture chain.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/noise_suppression.dart';
import '../providers/strong_noise_status.dart';
import '../../../widgets/settings_segmented_row.dart';
import '../../../widgets/settings_select_row.dart';

class NoiseSuppressionSection extends ConsumerWidget {
  const NoiseSuppressionSection({super.key});

  static const _labels = {
    NoiseSuppressionChoice.spaceDefault: 'Space default',
    NoiseSuppressionChoice.standard: 'Standard',
    NoiseSuppressionChoice.strong: 'Strong',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(noiseSuppressionProvider);
    final spaceStrong =
        ref.watch(spaceStrongNoiseSuppressionProvider).valueOrNull ?? false;
    final description = choice == NoiseSuppressionChoice.spaceDefault
        ? 'This Space uses ${spaceStrong ? 'Strong' : 'Standard'}.'
        : 'Strong also removes keyboards, fans and room noise.';
    final strongInactive = ref.watch(strongNoiseInactiveProvider);
    return SettingsSegmentedRow<NoiseSuppressionChoice>(
      label: 'Noise suppression',
      description: description,
      footnote: strongInactive
          ? 'Strong is off for this mic. It needs a 48 kHz input.'
          : null,
      value: choice,
      choices: [
        for (final value in NoiseSuppressionChoice.values)
          SettingsChoice(value: value, label: _labels[value]!),
      ],
      onChanged: (v) => ref.read(noiseSuppressionProvider.notifier).set(v),
    );
  }
}
