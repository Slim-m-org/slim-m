// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one question before a bare Windows copy updates itself: doing so moves
/// the app, so say where and that nothing else changes.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// True when the person agrees to move this copy into their account's app
/// folder as part of updating.
Future<bool> confirmWindowsAdopt(BuildContext context) async {
  final agreed = await showAppSheet<bool>(
    context,
    builder: (context) => const _AdoptConfirm(),
  );
  return agreed ?? false;
}

class _AdoptConfirm extends StatelessWidget {
  const _AdoptConfirm();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Move slim-m to update it?',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          Text(
            'This copy runs from a folder. It moves into your account\'s app '
            'folder so it can keep itself up to date. Your settings and '
            'sign-in stay as they are.',
            style: AppText.body.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s16),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: 'Move and update',
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
