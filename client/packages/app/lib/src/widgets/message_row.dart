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
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../routing/breakpoints.dart';

import 'emoji_picker.dart';
import 'message_hover_toolbar.dart';
import 'hover_reveal.dart';
import 'message_context_menu.dart';
import 'message_row_identity.dart';
import 'message_row_column.dart';
import 'message_row_parts.dart';
import 'reactions_row.dart';
import 'message_text.dart';

/// One message, and optionally the "New" divider directly above it.
///
/// Grouping (dropping the avatar and header for a continuation) is decided by
/// the caller, which is what lets [ChannelScreen]'s tests exercise the rule
/// without needing a whole scrollable list.
class MessageRow extends StatelessWidget {
  const MessageRow({
    super.key,
    required this.message,
    required this.grouped,
    required this.showNewDivider,
    this.dayLabel,
    required this.knownUsernames,
    this.knownRoleNames = const {},
    required this.onRetry,
    required this.onDiscard,
    this.onEditFailed,
    required this.onPickReaction,
    required this.onReactionTap,
    required this.onVote,
    required this.actions,
    required this.editing,
    required this.onSubmitEdit,
    required this.onCancelEdit,
    this.onViewEditHistory,
    this.customEmoji = const {},
    this.reactions = const [],
    this.attachments = const [],
    this.embeds = const [],
    this.webhookUsername,
    this.components = const [],
    this.poll,
    this.appSurface,
    this.call,
    this.viewerIsCaller = false,
    this.threadReplyCount,
    this.threadLastReplyAt,
    this.threadUnreadCount,
    this.replyTo,
    this.replyParentAdjacent = false,
    this.onReplyTap,
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

  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  /// Recovers a failed message's text for editing (error grammar 01: failed
  /// content is never thrown away). Null hides the Edit action.
  final VoidCallback? onEditFailed;

  /// Called with the token the add-reaction picker chose (a codepoint, or a
  /// `:shortcode:` for one of the deployment's own), from the hover toolbar's
  /// button or from the long-press menu's own sheet, which is the only one of
  /// the two a finger can reach.
  final ValueChanged<String> onPickReaction;

  /// Toggles the caller's own reaction for an existing chip: on if
  /// [api.ReactionSummary.reacted] was false, off if it was true.
  final ValueChanged<api.ReactionSummary> onReactionTap;

  /// Casts (or changes) the caller's vote when [poll] is non-null. Always
  /// required, like every other callback here, even though it is only ever
  /// invoked when there is a poll to vote on.
  final ValueChanged<int> onVote;

  /// What this row's context menu can do here: edit, delete, and pin/unpin,
  /// each gated by whatever the caller already knows about authorship and
  /// permissions.
  final MessageActions actions;

  /// True while this is the one row being edited inline. At most one row in
  /// a channel is ever true at once; [ChannelScreen] enforces that by
  /// keeping a single editing-message id, not this widget.
  final bool editing;

  /// Called with the trimmed new content when an inline edit is saved.
  final ValueChanged<String> onSubmitEdit;

  /// Called to leave edit mode without saving, however that happened
  /// (Escape, the Cancel button, or submitting empty text).
  final VoidCallback onCancelEdit;

  /// Reaction summaries for this message, from `Message.reactions` (a REST
  /// fetch) merged with any live `reactions.changed` update; see
  /// `providers/message_extras.dart`.
  final List<api.ReactionSummary> reactions;

  /// Attachments riding on this message, in display order.
  final List<api.Attachment> attachments;

  /// Structured content a webhook or a bot attached; see decision 0030.
  final List<api.Embed> embeds;

  /// The webhook post's own username label, shown beside the Webhook badge.
  final String? webhookUsername;

  /// A bot's buttons; they stay visible but disabled once its account is gone.
  final List<api.ComponentRow> components;

  /// The poll this message carries, if it is a poll message.
  final api.Poll? poll;

  /// The app this message launches, if it is an app message. Rendered as an
  /// interactive, shared surface in place of the message body.
  final api.AppSurface? appSurface;

  /// The call this message records, or null on an ordinary message. Rendered
  /// in place of the body, which a call message stores empty.
  final api.CallRecord? call;

  /// Whether the reader is the one who placed [call]. The same stored record
  /// reads as "missed call" to one side and "no answer" to the other, so this
  /// cannot be derived from the message: its author is always the caller.
  final bool viewerIsCaller;

  /// Undeleted replies in this message's thread, from
  /// `MessageExtras.threadReplyCount` - null (not zero) hides the row
  /// entirely, since a message with no thread must never read as a
  /// zero-reply one. See `ThreadReplySummary`.
  final int? threadReplyCount;

  /// How many of the thread's live messages this viewer has not yet read,
  /// from `MessageExtras.threadUnreadCount`. Null exactly when
  /// [threadReplyCount] is null; can be a genuine 0.
  final int? threadUnreadCount;

  /// When the thread's newest reply was sent, unix milliseconds. Null
  /// whenever [threadReplyCount] is null or zero.
  final int? threadLastReplyAt;

  /// The message [message] replies to, resolved by the transcript, or null
  /// when [message] is not a reply at all or its parent could not be
  /// resolved. See `reply_quote.dart` for what null does and does not mean.
  final Message? replyTo;

  /// True when the quoted parent is the row directly above this one.
  final bool replyParentAdjacent;

  /// Jumps to the parent named by [Message.replyToId]. Only ever called when
  /// that id is non-null, so it is safe to leave null when [message] is not
  /// a reply.
  final VoidCallback? onReplyTap;

  /// Opens this message's edit history. Null leaves the "edited" marker
  /// inert - a view-only surface, or a message with nothing to show.
  final VoidCallback? onViewEditHistory;

  bool get _unsent => message.pending || message.failed;

  /// Exposed so a test can find the hover/menu-open background fill without
  /// depending on widget tree shape.
  static const Key hoverFillKey = Key('message_row_hover_fill');

  @override
  Widget build(BuildContext context) {
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
            onAddReaction: () =>
                showEmojiPickerSheet(context, onSelect: onPickReaction),
            onPickReaction: onPickReaction,
            reactedEmoji: {
              for (final r in reactions)
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
                            ? AppDensity.normal.groupedRowGap
                            : AppDensity.normal.rowGap,
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
                                  onRetry: onRetry,
                                  onDiscard: onDiscard,
                                  onReactionTap: onReactionTap,
                                  onVote: onVote,
                                  onSubmitEdit: onSubmitEdit,
                                  onCancelEdit: onCancelEdit,
                                  onEditFailed: onEditFailed,
                                  onViewEditHistory: onViewEditHistory,
                                  onReplyTap: onReplyTap,
                                  replyTo: replyTo,
                                  replyParentAdjacent: replyParentAdjacent,
                                  webhookUsername: webhookUsername,
                                  reactions: reactions,
                                  attachments: attachments,
                                  embeds: embeds,
                                  components: components,
                                  poll: poll,
                                  appSurface: appSurface,
                                  call: call,
                                  viewerIsCaller: viewerIsCaller,
                                  threadReplyCount: threadReplyCount,
                                  threadLastReplyAt: threadLastReplyAt,
                                  threadUnreadCount: threadUnreadCount,
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
                      onPickReaction: onPickReaction,
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
