// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The floating bar that appears while the permissions grid holds unsaved
/// edits. Split out of `channel_permissions_grid.dart`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class UnsavedChangesBar extends StatelessWidget {
  const UnsavedChangesBar({
    super.key,
    required this.changeCount,
    required this.saving,
    required this.onDiscard,
    required this.onSave,
  });

  final int changeCount;
  final bool saving;
  final VoidCallback onDiscard;
  final VoidCallback onSave;

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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceBase,
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
            children: [
              Expanded(
                child: Text(
                  '$changeCount unsaved ${changeCount == 1 ? 'change' : 'changes'}',
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
              AppButton(
                label: 'Discard',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.sm,
                disabled: saving,
                onPressed: onDiscard,
              ),
              const SizedBox(width: AppSpacing.s8),
              AppButton(
                label: saving ? 'Saving...' : 'Save changes',
                variant: AppButtonVariant.primary,
                size: AppButtonSize.sm,
                disabled: saving,
                onPressed: onSave,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
