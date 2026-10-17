// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bulk moderation actions as a sheet, for a window narrower than
/// [kCompactWidth].
///
/// The member pane is a 236px drawer there, too narrow to hold a duration
/// chooser and two buttons, so the actions take a bottom sheet
/// (`desktop-vs-mobile.md` rule 4) and the drawer keeps a single slim bar.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'member_profile_sections.dart' show timeoutDurationOptions;

/// Opens the sheet. Each action closes it first, so a confirm dialog or a
/// failure never stacks on top of the sheet it came from.
Future<void> showMemberModerationSheet(
  BuildContext context, {
  required int count,
  required bool canTimeOut,
  required bool canRemove,
  required void Function(Duration) onTimeOut,
  required Future<void> Function() onRemove,
}) {
  return showAppSheet<void>(
    context,
    builder: (sheetContext) => _ModerationSheet(
      count: count,
      canTimeOut: canTimeOut,
      canRemove: canRemove,
      onTimeOut: (duration) {
        Navigator.of(sheetContext).pop();
        onTimeOut(duration);
      },
      onRemove: () async {
        Navigator.of(sheetContext).pop();
        await onRemove();
      },
    ),
  );
}

class _ModerationSheet extends StatelessWidget {
  const _ModerationSheet({
    required this.count,
    required this.canTimeOut,
    required this.canRemove,
    required this.onTimeOut,
    required this.onRemove,
  });

  final int count;
  final bool canTimeOut;
  final bool canRemove;
  final void Function(Duration) onTimeOut;
  final Future<void> Function() onRemove;

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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            count == 1 ? '1 member selected' : '$count members selected',
            style: AppText.heading.copyWith(color: tokens.textPrimary),
          ),
          if (canTimeOut) ...[
            const SizedBox(height: AppSpacing.s16),
            Text(
              'Time out for...',
              style: AppText.ui.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s8),
            _DurationRow(onChosen: onTimeOut),
          ],
          if (canRemove) ...[
            if (canTimeOut) ...[
              const SizedBox(height: AppSpacing.s16),
              Divider(height: 1, color: tokens.borderSubtle),
            ],
            const SizedBox(height: AppSpacing.s16),
            AppButton(
              label: 'Remove',
              variant: AppButtonVariant.danger,
              icon: AppIcons.revoke,
              onPressed: onRemove,
            ),
          ],
        ],
      ),
    );
  }
}

class _DurationRow extends StatelessWidget {
  const _DurationRow({required this.onChosen});

  final void Function(Duration) onChosen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (index, (label, duration))
            in timeoutDurationOptions.indexed) ...[
          if (index > 0) const SizedBox(width: AppSpacing.s8),
          Expanded(
            child: AppButton(
              label: label,
              variant: AppButtonVariant.secondary,
              semanticLabel: 'Time out for $label',
              onPressed: () => onChosen(duration),
            ),
          ),
        ],
      ],
    );
  }
}
