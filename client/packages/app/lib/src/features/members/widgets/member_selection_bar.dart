// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What appears at the foot of the member pane while members are being
/// selected.
///
/// It sits below the roster rather than replacing it, which is the opposite of
/// what `MessageSelectionBar` does to the composer, and for the same
/// underlying reason. That bar takes the composer's slot because typing into a
/// transcript you are selecting out of makes no sense, so leaving the composer
/// live would offer a contradictory action. The roster has no such conflict:
/// scrolling it is exactly what somebody picking members out of it needs to
/// keep doing.
///
/// Two verbs rather than one, because the moderator holds them separately:
/// KICK_MEMBERS times out, BAN_MEMBERS removes, and either can be held without
/// the other. A verb whose permission is missing is absent rather than
/// disabled - a missing permission is not something selecting more members
/// would resolve.
///
/// The verbs appear only once something is selected. A timeout chip that did
/// nothing, or a Remove that refused, would be a control explaining itself
/// through failure; the count above it already says what the mode is waiting
/// for.
///
/// Durations come from [TimeoutDurationChips], the same chooser the single
/// member's profile sheet uses, so the two paths cannot offer different
/// lengths.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_selection.dart';
import 'member_moderation_sheet.dart';
import 'member_profile_sections.dart';

/// The bar itself. Both callbacks are passed in rather than called from here,
/// so confirming, reporting a failure and leaving the mode all stay with the
/// pane that owns them.
class MemberSelectionBar extends ConsumerWidget {
  const MemberSelectionBar({
    required this.canTimeOut,
    required this.canRemove,
    required this.onTimeOut,
    required this.onRemove,
    super.key,
  });

  final bool canTimeOut;
  final bool canRemove;
  final void Function(Duration) onTimeOut;
  final Future<void> Function() onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final selection = ref.watch(memberSelectionProvider);
    final controller = ref.read(memberSelectionProvider.notifier);
    final any = selection.count > 0;
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label(selection, canTimeOut: canTimeOut, canRemove: canRemove),
              style: AppText.body.copyWith(
                color: any ? tokens.textPrimary : tokens.textSecondary,
              ),
            ),
            if (compact)
              ..._compactActions(
                context,
                count: selection.count,
                controller: controller,
              )
            else ...[
              if (any && canTimeOut) TimeoutDurationChips(onChosen: onTimeOut),
              // Stacked, not a Row: 236px will not hold two verbs and a cancel.
              if (any && canRemove) ...[
                const SizedBox(height: AppSpacing.s8),
                AppButton(
                  label: 'Remove',
                  variant: AppButtonVariant.danger,
                  icon: AppIcons.revoke,
                  onPressed: onRemove,
                ),
              ],
              const SizedBox(height: AppSpacing.s8),
              AppButton(
                label: 'Cancel',
                variant: AppButtonVariant.ghost,
                onPressed: controller.clear,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One slim row under the count: the verbs live in a sheet at this width.
  List<Widget> _compactActions(
    BuildContext context, {
    required int count,
    required MemberSelectionController controller,
  }) {
    return [
      const SizedBox(height: AppSpacing.s8),
      Row(
        children: [
          Expanded(
            child: AppButton(
              label: 'Cancel',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.sm,
              onPressed: controller.clear,
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: AppSpacing.s8),
            Expanded(
              child: AppButton(
                label: 'Moderate',
                icon: AppIcons.shield,
                size: AppButtonSize.sm,
                onPressed: () => unawaited(
                  showMemberModerationSheet(
                    context,
                    count: count,
                    canTimeOut: canTimeOut,
                    canRemove: canRemove,
                    onTimeOut: onTimeOut,
                    onRemove: onRemove,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ];
  }

  /// Says how many, and says so once the cap is why there are no more.
  ///
  /// Deliberately not the header button's own wording: two controls sharing an
  /// accessible name makes a screen reader announce the same phrase for the
  /// thing that starts the mode and the line reporting its state.
  ///
  /// Nobody selected yet is a dead end on its own - it says the mode is
  /// waiting but not what for, so it reads as broken rather than idle. The
  /// verb named here is scoped to what the viewer actually holds, since
  /// [canTimeOut] and [canRemove] are held separately and the bar itself is
  /// only ever shown once at least one is true.
  String _label(
    MemberSelection selection, {
    required bool canTimeOut,
    required bool canRemove,
  }) {
    if (selection.count == 0) {
      final verb = canTimeOut && canRemove
          ? 'time out or remove'
          : canTimeOut
          ? 'time out'
          : 'remove';
      return 'Tap members to $verb';
    }
    final n = selection.count;
    final counted = n == 1 ? '1 selected' : '$n selected';
    return selection.atCap ? '$counted, the most at once' : counted;
  }
}
