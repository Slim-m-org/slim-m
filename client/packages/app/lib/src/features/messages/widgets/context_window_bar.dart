// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pinned bar over a read-only context window: says the transcript is
/// showing older messages and returns to the live channel in one tap.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ContextWindowBar extends StatelessWidget {
  const ContextWindowBar({super.key, required this.onJumpToPresent});

  final VoidCallback onJumpToPresent;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Material(
      color: tokens.surfaceRaised,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: tokens.borderSubtle)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s12,
            vertical: AppSpacing.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Viewing older messages',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
              AppButton(
                label: 'Jump to present',
                icon: AppIcons.moveDown,
                variant: AppButtonVariant.primary,
                size: AppButtonSize.sm,
                onPressed: onJumpToPresent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
