// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The column a message row lays out beside its avatar: header, body or edit
/// field, the extras a message can carry, reactions, the thread chip and the
/// failed-send row.
///
/// Split out of `message_row.dart`, which owns the row's fill, hover toolbar
/// and menu, once that file reached the review budget's hard ceiling.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/author_is_bot.dart';
import '../providers/message_editing.dart' show messageEditProgressProvider;
import '../providers/message_extras.dart' show MessageExtras;
import '../../modules/widgets/app_surface_view.dart';
import 'attachment_gallery.dart';
import '../../members/widgets/bot_ui_failure.dart';
import '../../voice/widgets/call_record_view.dart';
import 'embed_card.dart';
import 'forwarded_message_card.dart';
import 'link_preview_card.dart';
import 'message_buttons.dart';
import 'module_marker.dart';
import 'message_context_menu.dart';
import 'message_edit_field.dart';
import 'message_row_callbacks.dart';
import 'message_hover_toolbar.dart';
import 'card_spacing.dart';
import 'message_inline.dart' show extractLinkPreviewUrls;
import 'message_row_identity.dart';
import 'message_row_parts.dart';
import 'poll_vote_failure_line.dart';
import 'message_text.dart';
import '../../composer/widgets/poll_view.dart';
import 'reactions_row.dart';
import 'toolbar_clearance.dart';

/// The least width a grouped body keeps once the toolbar's reserve is taken off its right.
const double _minBodyWidth = 280;

/// The least width an author line keeps beside its name's badges and time.
const double _minHeaderWidth = 240;

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
    this.viewerIsCaller = false,
    this.hoverTime,
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
  final bool viewerIsCaller;

  /// A continuation's sent time, set after the body's last word.
  final Widget? hoverTime;

  bool get _unsent => message.pending || message.failed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBot = ref.watch(authorIsBotProvider(message.authorId));
    final edited = _editedWidget(isBot);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ..._header(),
        ..._body(ref, edited),
        ..._cards(edited),
        ..._footer(),
        if (_endsInCard) const SizedBox(height: kCardBottomGap),
      ],
    );
  }

  /// A card as the last thing in the row; a link preview adds its own gap, since it may render nothing.
  bool get _endsInCard {
    final chipsAfter =
        (!_unsent && extras.reactions.isNotEmpty) ||
        (extras.threadReplyCount ?? 0) > 0 ||
        message.failed;
    if (editing || chipsAfter) return false;
    return extras.embeds.isNotEmpty ||
        extras.attachments.isNotEmpty ||
        extras.poll != null ||
        extras.call != null ||
        extras.appSurface != null ||
        extras.components.isNotEmpty ||
        message.forwarded != null;
  }

  Widget? _editedWidget(bool isBot) {
    // A bot edits its own status as it goes, so the marker says nothing.
    final editedMarker = message.editedAt != null && !editing && !isBot
        ? EditedMarker(onTap: callbacks.onViewEditHistory)
        : null;
    final time = hoverTime;
    if (time == null) return editedMarker;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (editedMarker != null) ...[
          editedMarker,
          const SizedBox(width: AppSpacing.s8),
        ],
        time,
      ],
    );
  }

  List<Widget> _header() => [
    if (!grouped)
      ToolbarClearance(
        // Compact has no hover to reserve for, and no room to spare.
        clearance: MessageHoverToolbar.clearance(compact: compact),
        minWidth: _minHeaderWidth,
        child: MessageRowHeader(
          key: MessageRowHeader.headerKey,
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
  ];

  List<Widget> _body(WidgetRef ref, Widget? edited) => [
    if (editing)
      Padding(
        // The row is raised while editing; the field needs air above the fill's edge.
        padding: const EdgeInsets.only(bottom: AppSpacing.s8),
        child: _editField(ref),
      )
    // An attachment-only message has no body; an empty one still adds a blank line above the image. A forward's own note is often empty too.
    else if (message.content.isNotEmpty)
      ToolbarClearance(
        // A headerless row's first line is what the toolbar would sit on, unless that leaves the text a sliver.
        clearance: grouped
            ? MessageHoverToolbar.clearance(compact: compact)
            : EdgeInsets.zero,
        minWidth: _minBodyWidth,
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
    if (!editing &&
        message.content.isNotEmpty &&
        !extras.linkPreviewsRemoved &&
        !message.linkPreviewsRemoved)
      LinkPreviewList(
        urls: extractLinkPreviewUrls(message.content),
        message: message,
      ),
    if (!editing && extras.embeds.isNotEmpty) EmbedList(embeds: extras.embeds),
    if (extras.viaModule case final module?) ModuleMarker(module: module),
    if (!editing && extras.components.isNotEmpty)
      MessageButtons(
        channelId: message.channelId,
        messageId: message.id,
        rows: extras.components,
        unavailable: message.authorId == null,
      ),
  ];

  Widget _editField(WidgetRef ref) {
    final progress = ref.watch(messageEditProgressProvider(message.id));
    return MessageEditField(
      initialContent: message.content,
      onSubmit: callbacks.onSubmitEdit,
      onCancel: callbacks.onCancelEdit,
      saving: progress.saving,
      failure: progress.failure,
    );
  }

  List<Widget> _cards(Widget? edited) => [
    BotUiFailureLine(messageId: message.id),
    if (message.forwarded case final forwarded?) _forwardedCard(forwarded),
    if (edited != null && message.content.isEmpty)
      Padding(padding: const EdgeInsets.only(top: 2), child: edited),
    if (extras.poll != null)
      Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s4),
        child: PollView(
          poll: extras.poll!,
          onVote: callbacks.onVote,
          onRank: callbacks.onRank,
        ),
      ),
    if (extras.poll != null) PollVoteFailureLine(messageId: message.id),
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
  ];

  Widget _forwardedCard(ForwardedMessage forwarded) {
    final note = forwarded.content;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: ForwardedMessageCard(
        forwarded: forwarded,
        body: note.isEmpty
            ? null
            : MessageBody(
                content: note,
                knownUsernames: knownUsernames,
                knownRoleNames: knownRoleNames,
                customEmoji: customEmoji,
              ),
        attachments: extras.attachments,
        currentChannelId: message.channelId,
      ),
    );
  }

  List<Widget> _footer() => [
    // A forward's attachments are part of what was forwarded, and are drawn inside its card instead.
    if (message.forwarded == null && extras.attachments.isNotEmpty)
      MessageAttachments(
        attachments: extras.attachments,
        messageId: _unsent ? null : message.id,
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
  ];
}
