// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One row in the message list: the avatar or continuation gutter, the
/// header line, the body, and everything that can follow it.
///
/// The avatar/gutter and header live in `message_row_identity.dart` and the
/// hover-reveal mechanism (shared with the emoji picker and the context menu)
/// lives in `hover_reveal.dart`, both split out to keep this file to the row's
/// own composition.
///
/// A horizontal swipe on a row used to start a reply. It was removed on
/// 2026-09-11 at the owner's request: it ran opposite to the direction every
/// comparable app uses, and a row can now hold something you drag on - a
/// module scene is the case that surfaced it - where a horizontal drag meant
/// to draw was taken as a reply instead. Reply is still on the row's context
/// menu, which is where it was reached from anyway.
///
/// The background fill answers `hovered || menuOpen` rather than `hovered`
/// alone: `menuOpen` is `HoverReveal`'s own signal that this row's context
/// menu is showing by any gesture, long press included, which `hovered`
/// cannot answer since a long press deliberately never pins it (see
/// `HoverReveal`'s own doc for why). AppListRow's own hover token is reused
/// rather than a second hover convention.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_density.dart';
import '../providers/message_extras.dart' show MessageExtras;
import '../routing/breakpoints.dart';

import 'emoji_picker.dart';
import 'message_hover_toolbar.dart';
import 'hover_reveal.dart';
import 'message_context_menu.dart';
import 'message_row_identity.dart';
import 'message_row_callbacks.dart';
import 'message_row_column.dart';
import 'message_row_parts.dart';
import 'reactions_row.dart';
import 'message_text.dart';

/// One message, and optionally the "New" divider directly above it.
///
/// Grouping (dropping the avatar and header for a continuation) is decided by
/// the caller, which is what lets [ChannelScreen]'s tests exercise the rule
/// without needing a whole scrollable list.
class MessageRow extends ConsumerWidget {
  const MessageRow({
    super.key,
    required this.message,
    required this.grouped,
    required this.showNewDivider,
    this.dayLabel,
    required this.knownUsernames,
    this.knownRoleNames = const {},
    required this.callbacks,
    required this.actions,
    required this.editing,
    this.customEmoji = const {},
    this.extras = MessageExtras.empty,
    this.viewerIsCaller = false,
    this.replyTo,
    this.replyParentAdjacent = false,
  });

  final Message message;

  /// True for a continuation of the same author's previous message inside
  /// the density's grouping window: drops the avatar and header, and shows
  /// the time in the gutter instead.
  final bool grouped;

  final bool showNewDivider;

  /// A formatted calendar-day label ("Today", "Yesterday", "July 28, 2026")
  /// shown as a divider above this row when it is the first message of a new
  /// day. Null on every other row. Decided by the caller for the same reason
  /// [grouped] is: only the list knows what came before this row.
  final String? dayLabel;

  /// Lower-cased usernames the mention renderer treats as real. See
  /// [MessageBody].
  final Set<String> knownUsernames;

  /// See [MessageBody.knownRoleNames].
  final Set<String> knownRoleNames;

  /// The deployment's custom emoji, name to id. Resolves a `:shortcode:` in
  /// the body ([MessageBody]) and on a reaction chip ([ReactionsRow]) alike.
  final Map<String, String> customEmoji;

  /// Everything this row can ask its caller to do.
  final MessageRowCallbacks callbacks;

  /// What this row's context menu can do here: edit, delete, and pin/unpin,
  /// each gated by whatever the caller already knows about authorship and
  /// permissions.
  final MessageActions actions;

  /// True while this is the one row being edited inline. At most one row in
  /// a channel is ever true at once; [ChannelScreen] enforces that by
  /// keeping a single editing-message id, not this widget.
  final bool editing;

  /// What rides on this message beyond its text: reactions, attachments,
  /// embeds, a poll, an app, a call, the thread summary and a webhook's name.
  /// A new per-message field lands in `MessageExtras` and is read from here.
  final MessageExtras extras;

  /// Whether the reader is the one who placed `extras.call`. The same stored
  /// record reads as "missed call" to one side and "no answer" to the other,
  /// so this cannot be derived from the message: its author is always the
  /// caller.
  final bool viewerIsCaller;

  /// The message [message] replies to, resolved by the transcript, or null
  /// when [message] is not a reply at all or its parent could not be
  /// resolved. See `reply_quote.dart` for what null does and does not mean.
  final Message? replyTo;

  /// True when the quoted parent is the row directly above this one.
  final bool replyParentAdjacent;

  bool get _unsent => message.pending || message.failed;

  /// Exposed so a test can find the hover/menu-open background fill without
  /// depending on widget tree shape.
  static const Key hoverFillKey = Key('message_row_hover_fill');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(messageDensityControllerProvider);
    final groupSpacing = ref.watch(groupSpacingControllerProvider);
    final compact = LayoutClass.of(context) == LayoutClass.compact;
    final gutter = paneGutterOf(context);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return HoverReveal(
      builder: (context, hovered, menuOpen, focusWithin) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (dayLabel != null) DayDivider(label: dayLabel!),
          if (showNewDivider) const NewMessagesDivider(),
          MessageContextMenuRegion(
            content: message.content,
            actions: actions,
            onAddReaction: () => showEmojiPickerSheet(
              context,
              onSelect: callbacks.onPickReaction,
            ),
            onPickReaction: callbacks.onPickReaction,
            reactedEmoji: {
              for (final r in extras.reactions)
                if (r.reacted) r.emoji,
            },
            // A failed row is marked by a red hairline down its left edge
            // (error grammar 01) - the row itself stays at full strength,
            // because its content is still the author's to act on.
            child: Stack(
              // The toolbar's shadow spills past the row; clipping it would cut the blur.
              clipBehavior: Clip.none,
              children: [
                // Full-bleed, edge to edge; see this file's own doc comment.
                Positioned.fill(
                  child: AnimatedContainer(
                    key: MessageRow.hoverFillKey,
                    duration: AppMotion.reduced(context, AppMotion.fast),
                    curve: AppMotion.entrance,
                    color: hovered || menuOpen || editing
                        ? tokens.surfaceRaised
                        : Colors.transparent,
                  ),
                ),
                ConstrainedBox(
                  // A row shorter than the toolbar would leave part of it painted but unhittable.
                  constraints: BoxConstraints(
                    minHeight: compact ? 0 : MessageHoverToolbar.height,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: message.failed
                          ? Border(
                              left: BorderSide(
                                color: tokens.dangerBorder,
                                width: 2,
                              ),
                            )
                          : const Border(),
                    ),
                    child: Padding(
                      // Top-only: a bottom inset here doubled the next row's top inset.
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        grouped
                            ? density.groupedRowGap
                            : density.rowGap + groupSpacing,
                        gutter,
                        0,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MessageRowLeading(
                            grouped: grouped,
                            message: message,
                            hovered: hovered,
                          ),
                          const SizedBox(width: AppSpacing.s12),
                          Expanded(
                            // Align loosens Expanded's tight width so the cap can
                            // bite: without it the max was silently a no-op and body
                            // text ran the full pane on any monitor.
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: kMessageColumnMax,
                                ),
                                child: MessageRowColumn(
                                  message: message,
                                  grouped: grouped,
                                  compact: compact,
                                  editing: editing,
                                  actions: actions,
                                  knownUsernames: knownUsernames,
                                  knownRoleNames: knownRoleNames,
                                  customEmoji: customEmoji,
                                  callbacks: callbacks,
                                  extras: extras,
                                  replyTo: replyTo,
                                  replyParentAdjacent: replyParentAdjacent,
                                  viewerIsCaller: viewerIsCaller,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Outside layout, and never on compact, which reserves no clearance for it.
                if (!compact &&
                    (hovered || focusWithin) &&
                    !_unsent &&
                    !editing)
                  Positioned(
                    top: 0,
                    right: AppSizes.paneGutter,
                    child: MessageHoverToolbar(
                      actions: actions,
                      onPickReaction: callbacks.onPickReaction,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
