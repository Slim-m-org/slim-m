// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The column a message row lays out beside its avatar: header, reply quote,
/// body or edit field, the extras a message can carry, reactions, the thread
/// chip and the failed-send row.
///
/// Split out of `message_row.dart`, which owns the row's fill, hover toolbar
/// and menu, once that file reached the review budget's hard ceiling.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/author_is_bot.dart';
import '../providers/message_extras.dart' show MessageExtras;
import 'app_surface_view.dart';
import 'attachment_view.dart';
import 'bot_ui_failure.dart';
import 'call_record_view.dart';
import 'embed_card.dart';
import 'forwarded_message_card.dart';
import 'link_preview_card.dart';
import 'message_buttons.dart';
import 'message_context_menu.dart';
import 'message_edit_field.dart';
import 'message_row_callbacks.dart';
import 'message_hover_toolbar.dart';
import 'message_inline.dart' show extractLinkPreviewUrls;
import 'message_row_identity.dart';
import 'message_row_parts.dart';
import 'message_text.dart';
import 'poll_view.dart';
import 'reactions_row.dart';
import 'reply_quote.dart';

class MessageRowColumn extends ConsumerWidget {
  const MessageRowColumn({
    super.key,
    required this.message,
    required this.grouped,
    required this.compact,
    required this.editing,
    required this.actions,
    required this.knownUsernames,
    required this.knownRoleNames,
    required this.customEmoji,
    required this.callbacks,
    required this.extras,
    this.replyTo,
    this.replyParentAdjacent = false,
    this.viewerIsCaller = false,
  });

  final Message message;
  final bool grouped;
  final bool compact;
  final bool editing;
  final MessageActions actions;
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;
  final MessageRowCallbacks callbacks;
  final MessageExtras extras;
  final Message? replyTo;

  /// True when the quoted parent is the row directly above this one.
  final bool replyParentAdjacent;
  final bool viewerIsCaller;

  /// The command a bot is answering is already the line above it.
  static bool _isCommand(Message? parent) {
    final text = parent?.content.trimLeft() ?? '';
    return text.startsWith('!') || text.startsWith('/');
  }

  bool get _unsent => message.pending || message.failed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBot = ref.watch(authorIsBotProvider(message.authorId));
    // A bot edits its own status as it goes, so the marker says nothing.
    final edited = message.editedAt != null && !editing && !isBot
        ? EditedMarker(onTap: callbacks.onViewEditHistory)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!grouped)
          Padding(
            // Compact has no hover to reserve for, and no room to spare.
            padding: MessageHoverToolbar.clearance(compact: compact),
            child: MessageRowHeader(
              message: message,
              webhookUsername: extras.webhookUsername,
              editing: editing,
            ),
          )
        else if (editing)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.s4),
            child: AppBadge(variant: AppBadgeVariant.role, label: 'Editing'),
          ),
        if (message.replyToId != null &&
            !(isBot && replyParentAdjacent && _isCommand(replyTo)))
          ReplyQuote(resolved: replyTo, onTap: callbacks.onReplyTap ?? () {}),
        if (editing)
          Padding(
            // The row is raised while editing; the field needs air above the fill's edge.
            padding: const EdgeInsets.only(bottom: AppSpacing.s8),
            child: MessageEditField(
              initialContent: message.content,
              onSubmit: callbacks.onSubmitEdit,
              onCancel: callbacks.onCancelEdit,
            ),
          )
        // An attachment-only message has no body; an empty one still adds a blank line above the image. A forward's own note is often empty too.
        else if (message.content.isNotEmpty)
          Padding(
            // A headerless row's first line is what the toolbar would sit on.
            padding: grouped
                ? MessageHoverToolbar.clearance(compact: compact)
                : EdgeInsets.zero,
            child: MessageBody(
              content: message.content,
              messageId: message.id,
              knownUsernames: knownUsernames,
              knownRoleNames: knownRoleNames,
              customEmoji: customEmoji,
              dim: message.pending,
              announceSending: message.pending,
              trailing: edited,
            ),
          ),
        if (!editing && message.content.isNotEmpty)
          LinkPreviewList(urls: extractLinkPreviewUrls(message.content)),
        if (!editing && extras.embeds.isNotEmpty)
          EmbedList(embeds: extras.embeds),
        if (!editing && extras.components.isNotEmpty)
          MessageButtons(
            channelId: message.channelId,
            messageId: message.id,
            rows: extras.components,
            unavailable: message.authorId == null,
          ),
        BotUiFailureLine(messageId: message.id),
        if (message.forwarded case final forwarded?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: ForwardedMessageCard(
              forwarded: forwarded,
              body: forwarded.content.isEmpty
                  ? null
                  : MessageBody(
                      content: forwarded.content,
                      knownUsernames: knownUsernames,
                      knownRoleNames: knownRoleNames,
                      customEmoji: customEmoji,
                    ),
              attachments: extras.attachments,
              currentChannelId: message.channelId,
            ),
          ),
        if (edited != null && message.content.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 2), child: edited),
        if (extras.poll != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: PollView(poll: extras.poll!, onVote: callbacks.onVote),
          ),
        if (extras.call != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: CallRecordView(
              record: extras.call!,
              viewerIsCaller: viewerIsCaller,
            ),
          ),
        if (extras.appSurface != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: AppSurfaceView(
              messageId: message.id,
              surface: extras.appSurface!,
              title: extras.appSurface!.moduleId,
            ),
          ),
        // A forward's attachments are part of what was forwarded, and are drawn inside its card instead.
        if (message.forwarded == null)
          for (final attachment in extras.attachments)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: AttachmentView(
                attachment: attachment,
                siblings: openableImages(extras.attachments),
              ),
            ),
        if (!_unsent)
          ReactionsRow(
            messageId: message.id,
            reactions: extras.reactions,
            onReactionTap: callbacks.onReactionTap,
            customEmoji: customEmoji,
          ),
        if ((extras.threadReplyCount ?? 0) > 0)
          ThreadReplySummary(
            replyCount: extras.threadReplyCount!,
            lastReplyAt: extras.threadLastReplyAt,
            unread: (extras.threadUnreadCount ?? 0) > 0,
            onTap: actions.canOpenThread ? actions.onOpenThread : null,
          ),
        if (message.failed)
          FailedRow(
            onRetry: callbacks.onRetry,
            onEdit: callbacks.onEditFailed,
            onDiscard: callbacks.onDiscard,
            reason: message.failureReason,
          ),
      ],
    );
  }
}
