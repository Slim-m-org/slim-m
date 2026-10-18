// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one line after setup that says where the voice channels are.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class FirstRunVoiceHint extends StatelessWidget {
  const FirstRunVoiceHint({super.key, required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Material(
          type: MaterialType.transparency,
          child: Semantics(
            liveRegion: true,
            container: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceRaised,
                border: Border.all(color: tokens.borderSubtle),
                borderRadius: BorderRadius.circular(AppRadii.card),
                boxShadow: AppShadows.float,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s16,
                  AppSpacing.s8,
                  AppSpacing.s8,
                  AppSpacing.s8,
                ),
                child: Row(
                  spacing: AppSpacing.s12,
                  children: [
                    Icon(AppIcons.voice, size: 20, color: tokens.accent),
                    Expanded(
                      child: Text(
                        'Voice channels are in the channel list. Open one to join a call.',
                        style: AppText.ui.copyWith(color: tokens.textPrimary),
                      ),
                    ),
                    AppButton(
                      label: 'Got it',
                      variant: AppButtonVariant.ghost,
                      onPressed: onDismiss,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
