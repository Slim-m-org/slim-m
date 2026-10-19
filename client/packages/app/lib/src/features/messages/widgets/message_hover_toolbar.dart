// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The toolbar a hovered or keyboard-focused message row shows: react, reply,
/// reply in thread, edit on your own messages, and an overflow that opens the
/// row's existing context menu.
///
/// It hangs from the row's top right in the overlay (`message_toolbar_anchor.dart`),
/// not inside the row, because a control laid out past its parent's edge paints
/// but cannot be hit. A row shorter than [height] keeps its density spacing and
/// the plate overhangs the row below it, whole and clickable.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/context_menu_region.dart';
import '../../emoji/widgets/emoji_picker.dart';
import 'message_context_menu.dart';
import 'message_row_roving.dart';

/// Every slot is an [AppIconButton] whose hit box is [AppSizes.rowPointer]
/// (30), the pointer minimum from `AppControlWithOptions`, with the 28px
/// [AppIconButtonSize.md] glyph plate drawn inside it.
class MessageHoverToolbar extends StatelessWidget {
  const MessageHoverToolbar({
    super.key,
    required this.actions,
    required this.onPickReaction,
  });

  final MessageActions actions;
  final ValueChanged<String> onPickReaction;

  static const plateKey = Key('message_hover_toolbar');
  static const replyKey = Key('message_toolbar_reply');
  static const threadKey = Key('message_toolbar_thread');
  static const editKey = Key('message_toolbar_edit');
  static const overflowKey = Key('message_toolbar_overflow');

  /// One hit box; the hairline border is drawn inside it, around the 28px plates.
  static const height = AppSizes.rowPointer;

  /// How far in from the row's right edge the content must stop so a long name
  /// or first line never runs under the toolbar: five slots, its padding and a gap.
  static const _contentReserve =
      5 * AppSizes.rowPointer + 2 * AppSpacing.s4 + AppSpacing.s8;

  /// The right inset for what shares a row's top line with the toolbar; none on
  /// compact, which has no hover and no room to spare.
  static EdgeInsets clearance({required bool compact}) =>
      EdgeInsets.only(right: compact ? 0 : _contentReserve);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.reduced(context, AppMotion.fast),
      curve: AppMotion.entrance,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      // A pointer affordance: a finger reaches all of this from the long-press menu.
      child: AppTouchTargets(
        enabled: false,
        child: DecoratedBox(
          key: plateKey,
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.control),
            // canvasTile, not float or menu: both spill 60 px or more over the neighbouring rows from a 30 px control.
            boxShadow: AppShadows.canvasTile,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RovingStop(
                  builder: (_, node) => EmojiPickerButton(
                    focusNode: node,
                    onSelect: onPickReaction,
                  ),
                ),
                if (actions.canReply)
                  _slot(replyKey, AppIcons.reply, 'Reply', actions.onReply),
                if (actions.canOpenThread)
                  _slot(
                    threadKey,
                    AppIcons.thread,
                    'Reply in thread',
                    actions.onOpenThread,
                  ),
                if (actions.canEdit)
                  _slot(editKey, AppIcons.edit, 'Edit', actions.onEdit),
                const _OverflowSlot(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slot(Key key, IconData icon, String label, VoidCallback onPressed) =>
      RovingStop(
        builder: (_, node) => AppIconButton(
          key: key,
          focusNode: node,
          icon: icon,
          semanticLabel: label,
          tooltip: label,
          iconSize: AppSizes.icon16,
          onPressed: onPressed,
        ),
      );
}

class _OverflowSlot extends StatelessWidget {
  const _OverflowSlot();

  @override
  Widget build(BuildContext context) {
    return RovingStop(
      builder: (context, node) => AppIconButton(
        key: MessageHoverToolbar.overflowKey,
        focusNode: node,
        icon: AppIcons.moreHorizontal,
        semanticLabel: 'More message actions',
        tooltip: 'More',
        iconSize: AppSizes.icon16,
        onPressed: () {
          final box = context.findRenderObject() as RenderBox?;
          final at = box?.localToGlobal(Offset(0, box.size.height));
          context.findAncestorStateOfType<ContextMenuRegionState>()?.open(
            at: at,
          );
        },
      ),
    );
  }
}
