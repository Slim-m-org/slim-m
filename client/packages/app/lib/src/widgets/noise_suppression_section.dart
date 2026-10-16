// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Standard or strong noise suppression, in the microphone card on a host
/// with the native capture chain.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/noise_suppression.dart';
import '../providers/strong_noise_status.dart';

class NoiseSuppressionSection extends ConsumerWidget {
  const NoiseSuppressionSection({super.key});

  static const _labels = {
    NoiseSuppressionChoice.spaceDefault: 'Space default',
    NoiseSuppressionChoice.standard: 'Standard',
    NoiseSuppressionChoice.strong: 'Strong',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final choice = ref.watch(noiseSuppressionProvider);
    final spaceStrong =
        ref.watch(spaceStrongNoiseSuppressionProvider).valueOrNull ?? false;
    final description = choice == NoiseSuppressionChoice.spaceDefault
        ? 'This Space uses ${spaceStrong ? 'Strong' : 'Standard'}.'
        : 'Strong also removes keyboards, fans and room noise.';
    final strongInactive = ref.watch(strongNoiseInactiveProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
          child: Text(
            'Noise suppression',
            style: AppText.ui.copyWith(color: tokens.textPrimary),
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
          child: Text(
            description,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        AppSegmentedControl.inline(
          semanticLabel: 'Noise suppression',
          options: [
            for (final value in NoiseSuppressionChoice.values)
              AppSegmentedOption(label: _labels[value]!),
          ],
          selectedIndex: choice.index,
          onSegmentSelected: (i) => ref
              .read(noiseSuppressionProvider.notifier)
              .set(NoiseSuppressionChoice.values[i]),
        ),
        if (strongInactive) ...[
          const SizedBox(height: AppSpacing.s8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            child: Text(
              'Strong is off for this mic. It needs a 48 kHz input.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        ],
      ],
    );
  }
}
