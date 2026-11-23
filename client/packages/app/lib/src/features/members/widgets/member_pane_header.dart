// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The pane's own title bar, counting the whole roster, bots only while the list shows them.
///
/// Never the filtered count: this pane is where somebody checks how big the
/// Space is, and a search box quietly changing that number would answer a
/// question nobody asked.
class MemberPaneHeader extends StatelessWidget {
  const MemberPaneHeader({
    super.key,
    required this.count,
    this.onInvite,
    this.onStartSelecting,
  });

  final int? count;

  /// Null when the viewer may not invite.
  final VoidCallback? onInvite;

  /// Enters selection mode. Null when the viewer holds neither moderation
  /// bit, or when the mode is already running.
  final VoidCallback? onStartSelecting;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      height: AppSizes.headerBar,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            // Shrinks to fit rather than wrapping, so the count is never orphaned.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                count == null ? 'MEMBERS' : 'MEMBERS · $count',
                maxLines: 1,
                style: AppText.label.copyWith(color: tokens.textSecondary),
              ),
            ),
          ),
          if (onInvite != null)
            AppIconButton(
              icon: AppIcons.invite,
              semanticLabel: 'Invite a friend',
              tooltip: 'Invite a friend',
              onPressed: onInvite,
            ),
          if (onStartSelecting != null)
            AppIconButton(
              icon: AppIcons.shield,
              semanticLabel: 'Select members to moderate',
              onPressed: onStartSelecting,
            ),
        ],
      ),
    );
  }
}
