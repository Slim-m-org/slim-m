// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The report card's quick-action row: jump to the message, delete it, time
/// out its author, or remove them from the Space. Split out of
/// `report_card.dart` to keep that file under budget.
///
/// Each action is a parameter here rather than this widget reaching for the
/// providers itself, so a caller lacking the permission for one simply does
/// not build it - absent, never present-and-disabled, matching
/// `AppSegmentedOption`'s own rule.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../features/members/widgets/member_profile_sections.dart'
    show TimeoutDurationChips;
import '../../action_labels.dart';

class ReportQuickActions extends StatelessWidget {
  const ReportQuickActions({
    super.key,
    required this.busy,
    this.jumpEnabled,
    this.onJump,
    this.onDelete,
    this.onRemove,
    this.onTimeOut,
  });

  final bool busy;

  /// Non-null to show "Jump to message" at all; its own value gates whether
  /// tapping it is enabled right now (null and false both disable it).
  final bool? jumpEnabled;
  final VoidCallback? onJump;
  final VoidCallback? onDelete;
  final VoidCallback? onRemove;
  final void Function(Duration)? onTimeOut;

  @override
  Widget build(BuildContext context) {
    final showJump = jumpEnabled != null;
    if (!showJump &&
        onDelete == null &&
        onRemove == null &&
        onTimeOut == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: [
            if (showJump)
              AppButton(
                label: 'Jump to message',
                icon: AppIcons.jumpToMessage,
                disabled: jumpEnabled != true || busy,
                onPressed: onJump,
              ),
            if (onDelete case final onDelete?)
              AppButton(
                label: 'Delete message',
                icon: AppIcons.delete,
                variant: AppButtonVariant.danger,
                disabled: busy,
                onPressed: onDelete,
              ),
            if (onRemove case final onRemove?)
              AppButton(
                label: ActionLabels.removeFromSpace,
                icon: AppIcons.signOut,
                variant: AppButtonVariant.danger,
                disabled: busy,
                onPressed: onRemove,
              ),
          ],
        ),
        if (onTimeOut case final onTimeOut?) ...[
          const SizedBox(height: AppSpacing.s8),
          TimeoutDurationChips(onChosen: onTimeOut, padding: EdgeInsets.zero),
        ],
      ],
    );
  }
}
