// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What someone opening an invite sees: the landing card with Back and Join
/// under it. The join flow and the admin's "preview as a visitor" both draw
/// this, so the preview can never drift from the real thing.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'invite_landing_card.dart';

class InviteLandingView extends StatelessWidget {
  const InviteLandingView({
    super.key,
    required this.card,
    required this.onBack,
    this.onJoin,
    this.note,
  });

  final InviteLandingCard card;
  final VoidCallback onBack;

  /// Null draws Join disabled, as the preview does.
  final VoidCallback? onJoin;

  /// A line under the card, such as the preview's own explanation.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final note = this.note;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(child: SingleChildScrollView(child: card)),
          if (note != null) ...[
            const SizedBox(height: AppSpacing.s8),
            Text(
              note,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.s16),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Back',
                  variant: AppButtonVariant.ghost,
                  onPressed: onBack,
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: 'Join',
                  variant: AppButtonVariant.primary,
                  disabled: onJoin == null,
                  onPressed: onJoin,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
