// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tile that stands for the viewer's own share, in place of a live copy of
/// the screen they are already looking at (which would mirror itself).
///
/// The Stop sharing button is visible on the tile because a phone has no hover
/// tooltip on the dock's own button.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class LocalShareTile extends StatelessWidget {
  const LocalShareTile({super.key, required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Center(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.screenShare, color: tokens.accent),
                const SizedBox(height: AppSpacing.s8),
                Text(
                  'You are sharing your screen',
                  textAlign: TextAlign.center,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
                const SizedBox(height: AppSpacing.s12),
                AppButton(
                  label: 'Stop sharing',
                  icon: AppIcons.screenShareStop,
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.sm,
                  onPressed: onStop,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
