// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message row's context menu: right-click on desktop, long-press on
/// touch, offering copy always and edit/delete/pin wherever the caller says
/// each is allowed.
library;

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'bot_menu_sections.dart' show BotMenuSection;
import 'context_menu_region.dart';
import 'hover_reveal.dart';
import 'message_menu_body.dart';
import 'message_row_roving.dart';

/// What the menu can do for one message. The caller (which knows authorship
/// and permissions; the menu deliberately does not) decides each `can*`
/// flag, so this stays a plain description rather than a policy.
class MessageActions {
  const MessageActions({
    required this.canReply,
    required this.onReply,
    required this.canEdit,
    required this.onEdit,
    required this.canDelete,
    required this.onDelete,
    required this.canManagePins,
    required this.pinned,
    required this.onTogglePin,
    required this.canReport,
    required this.onReport,
    required this.canBlockAuthor,
    required this.onBlockAuthor,
    required this.canOpenThread,
    required this.onOpenThread,
    this.hasExistingThread = false,
    required this.canCopyLink,
    required this.onCopyLink,
    required this.canForward,
    required this.onForward,
    required this.canSave,
    required this.onSave,
    this.onStartSelecting,
    this.botSections = const [],
  });

  /// Enters the transcript's selection mode with this message picked, for
  /// deleting several at once.
  ///
  /// Optional for two reasons: only a channel transcript has a selection
  /// mode to enter (the reported-message viewer builds these actions too and
  /// has no list to select within), and even there it needs MANAGE_MESSAGES
  /// specifically - null whenever [canDelete] is true only through
  /// authorship, since selection mode would then let a plain member reach
  /// past their own message to somebody else's. Rendered inside the same
  /// [canDelete] group at the menu, since it never appears on its own.
  final VoidCallback? onStartSelecting;

  /// Rows bots add, each set under its bot's name after everything the app
  /// itself offers. See decision 0045.
  final List<BotMenuSection> botSections;

  /// Keeping a message in your own private list. Needs no permission beyond
  /// reading it, and is nobody else's business - so unlike [canManagePins]
  /// there is no moderator gate, and unlike [pinned] no shared toggled state
  /// to render: the transcript does not know what you have saved, and asking
  /// per message would be a request per row.
  final bool canSave;
  final VoidCallback onSave;

  /// Gated on SEND_MESSAGES in this channel, unlike [canEdit] and [canDelete]:
  /// replying is a new send, not an act on a message you already authored.
  final bool canReply;
  final VoidCallback onReply;

  final bool canEdit;
  final VoidCallback onEdit;
  final bool canDelete;
  final VoidCallback onDelete;

  /// Gates the pin/unpin item; server-side this is MANAGE_MESSAGES,
  /// evaluated in the message's own channel.
  final bool canManagePins;

  /// The item reads "Unpin" when true, "Pin" otherwise. Meaningless when
  /// [canManagePins] is false, since the item is absent either way.
  final bool pinned;
  final VoidCallback onTogglePin;

  /// False for a message you authored: reporting your own content has
  /// nothing to investigate that deleting it would not already resolve.
  final bool canReport;
  final VoidCallback onReport;

  /// False for your own message and for one with no live author (a
  /// deleted account's content is anonymized and has nobody left to block).
  final bool canBlockAuthor;
  final VoidCallback onBlockAuthor;

  /// Gated like [canReply] plus one more: never inside a thread already,
  /// since nesting is refused server-side. Opens the hidden sub-channel this
  /// message already has, or starts one.
  final bool canOpenThread;
  final VoidCallback onOpenThread;

  /// Whether this message already has a live thread - the cross-link
  /// docs/IMPLIED-GAPS.md asked for between the plain "Reply" action and
  /// "Reply in thread": both stay offered (an inline reply is still an
  /// honest, lighter-weight action than opening a side conversation), but
  /// "Reply" carries a hint here so choosing it is informed rather than a
  /// silent fork away from a conversation that already exists. See
  /// [MessageContextMenuRegion]'s own `_items` for how it renders.
  final bool hasExistingThread;

  /// Whether a link to this message can be built; see [canCopyMessageLink].
  final bool canCopyLink;
  final VoidCallback onCopyLink;

  /// False for a pending or failed send, matching [canReply]: there is
  /// nothing settled yet to forward. Unlike edit and delete this needs no
  /// authorship or per-channel permission check here - forwarding reads
  /// [content], it never re-sends this exact message, and the destination
  /// picker itself only ever offers a channel or DM the caller can actually
  /// send to.
  final bool canForward;
  final VoidCallback onForward;
}

/// Wraps [child] so a right-click or long-press over it opens a menu for
/// [content] and [actions] - the message-specific skin on [ContextMenuRegion],
/// which owns the gesture, the anchor, and the compact-sheet/wide-floating
/// split every context menu in the app now shares.
///
/// This is the only add-reaction affordance a finger has: the picker button
/// beside a message is revealed by a [MouseRegion] that touch never fires, so
/// [onAddReaction] is what makes reacting reachable at all on a phone.
///
/// The row tints across a hold, showing visible progress toward the threshold
/// instead of a dead finger (motion spec 10). It runs over the framework's own
/// long-press timeout rather than the spec's 350ms, because the gesture stays
/// a [GestureDetector] (the thing that publishes `SemanticsAction.longPress`)
/// and the tint has to end when the gesture it tracks does.
class MessageContextMenuRegion extends StatefulWidget {
  const MessageContextMenuRegion({
    super.key,
    required this.content,
    required this.actions,
    required this.onAddReaction,
    required this.onPickReaction,
    this.reactedEmoji = const {},
    required this.child,
  });

  final String content;
  final MessageActions actions;

  /// Opens the emoji picker for this message. Deliberately not part of
  /// [MessageActions]: that class is a set of `can*`/`on*` pairs a caller
  /// that knows permissions supplies, and reacting is ungated in this client
  /// exactly as the hover button has always been.
  final VoidCallback onAddReaction;

  /// Reacts (or, for one the viewer already left, un-reacts) with a quick pick.
  final ValueChanged<String> onPickReaction;

  /// The reaction tokens the viewer has already left, shown selected in the quick row.
  final Set<String> reactedEmoji;

  final Widget child;

  @override
  State<MessageContextMenuRegion> createState() =>
      _MessageContextMenuRegionState();
}

class _MessageContextMenuRegionState extends State<MessageContextMenuRegion> {
  /// True from finger-down until the long press commits or cancels; drives
  /// the hold-progress tint.
  bool _holding = false;

  /// The item list both the floating menu and the bottom sheet render,
  /// parameterised on how each closes itself: hiding the overlay controller
  /// for one, popping the sheet's own route for the other.
  List<Widget> _items(BuildContext context, VoidCallback close) => [
    MessageMenuBody(
      actions: widget.actions,
      content: widget.content,
      reacted: widget.reactedEmoji,
      onAddReaction: widget.onAddReaction,
      onPickReaction: widget.onPickReaction,
      close: close,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return MessageRowRoving(
      builder: (context, rowNode) => ContextMenuRegion(
        focusNode: rowNode,
        itemsBuilder: _items,
        onOpenChanged: (open) => HoverRevealScope.maybeOf(context)?.pin(open),
        onVisibilityChanged: (open) =>
            HoverRevealScope.maybeOf(context)?.reportMenuOpen(open),
        onHoldChanged: (holding) => setState(() => _holding = holding),
        child: AnimatedContainer(
          duration: _holding
              ? AppMotion.reduced(context, kLongPressTimeout)
              : AppMotion.reduced(context, AppMotion.fast),
          curve: Curves.linear,
          color: _holding
              ? tokens.accentSoft.withValues(alpha: 0.5)
              : Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}
