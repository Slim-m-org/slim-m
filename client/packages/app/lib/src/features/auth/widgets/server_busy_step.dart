// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pinned server that is too busy to prove who it is, which is not the same as a server that failed to.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Pops `true` to ask again and `false` on going back; nothing is sent to the server meanwhile.
class ServerBusyStep extends StatelessWidget {
  const ServerBusyStep({super.key, required this.address});

  final Uri address;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.s24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Icon(
                    AppIcons.clock,
                    size: AppSizes.icon24,
                    color: tokens.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.s12),
                Text(
                  'The server is busy',
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                const SizedBox(height: AppSpacing.s8),
                Text(
                  address.host,
                  style: AppText.caption.copyWith(
                    color: tokens.textSecondary,
                    fontFamily: AppFonts.mono,
                  ),
                ),
                const SizedBox(height: AppSpacing.s16),
                Text(
                  'Try again in a moment.',
                  style: AppText.body.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s32),
                AppButton(
                  label: 'Try again',
                  variant: AppButtonVariant.primary,
                  full: true,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
                const SizedBox(height: AppSpacing.s12),
                AppButton(
                  label: 'Go back',
                  variant: AppButtonVariant.secondary,
                  full: true,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
