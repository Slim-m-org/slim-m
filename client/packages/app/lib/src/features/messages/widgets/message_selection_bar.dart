// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What replaces the composer while messages are being selected.
///
/// It takes the composer's slot rather than stacking above it, for two
/// reasons. Nothing can be typed into a transcript that is being selected
/// out of, so leaving the composer live would offer an action that makes no
/// sense in the mode. And the slot already exists at the bottom of the
/// channel, so the transcript neither reflows nor loses a row to make room -
/// which matters most on a phone, where the message the moderator is
/// deciding about could otherwise be the one pushed off screen.
///
/// The count is the label rather than a badge: "3 selected" is what the
/// delete is about to act on, and it is the only number in the mode.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/message_selection.dart';

/// The bar itself. [onDelete] is passed in rather than called from here so
/// that confirming, reporting a failure and leaving the mode all stay with
/// the screen that owns those, next to how it already deletes one message.
class MessageSelectionBar extends ConsumerWidget {
  const MessageSelectionBar({
    required this.channelId,
    required this.onDelete,
    super.key,
  });

  final String channelId;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final selection = ref.watch(messageSelectionProvider(channelId));
    final controller = ref.read(messageSelectionProvider(channelId).notifier);
    final none = selection.count == 0;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border(top: BorderSide(color: tokens.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Text(
                _label(selection),
                style: AppText.body.copyWith(
                  color: none ? tokens.textSecondary : tokens.textPrimary,
                ),
              ),
            ),
            AppButton(
              label: 'Cancel',
              variant: AppButtonVariant.ghost,
              onPressed: controller.clear,
            ),
            const SizedBox(width: AppSpacing.s8),
            AppButton(
              label: 'Delete',
              variant: AppButtonVariant.danger,
              icon: AppIcons.delete,
              // Disabled rather than hidden: the way out is the Cancel beside it.
              onPressed: none ? null : onDelete,
            ),
          ],
        ),
      ),
    );
  }

  /// Says how many, and says so once the cap is the reason there are no more.
  String _label(MessageSelection selection) {
    if (selection.count == 0) return 'Select messages to delete';
    final n = selection.count;
    final counted = n == 1 ? '1 selected' : '$n selected';
    return selection.atCap ? '$counted, the most at once' : counted;
  }
}
