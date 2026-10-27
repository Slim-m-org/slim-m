// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The prompt shown before switching from one call to another.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Shown instead of an automatic join when the caller is already connected
/// (or connecting) somewhere else: switching has to leave that call, so it
/// asks first rather than silently moving them, the one place a voice
/// channel arrival still needs an explicit decision.
class VoiceSwitchPrompt extends StatelessWidget {
  const VoiceSwitchPrompt({super.key, required this.onSwitch});

  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppBreathingHalo(
                child: Icon(
                  AppIcons.voice,
                  size: AppSizes.icon32,
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.s16),
              Text(
                'Already in a call',
                textAlign: TextAlign.center,
                style: AppText.heading.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
              const SizedBox(height: AppSpacing.s8),
              Text(
                "You're in a call somewhere else. Switching leaves it and "
                'joins this one instead.',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s16),
              FilledButton(
                onPressed: onSwitch,
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.accentFill,
                  foregroundColor: tokens.accentOn,
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s16),
                ),
                child: const Text('Switch to this call'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
