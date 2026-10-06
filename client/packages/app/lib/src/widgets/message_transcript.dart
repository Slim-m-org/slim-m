// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel's messages, laid out: the reversed scroll, the grouping and
/// unread rules that decide what each row shows, and what an empty list means.
///
/// Split out of `channel_screen.dart` on the line between deciding and
/// drawing. Nothing here reaches the network or the store; everything it needs
/// arrives as a parameter, which is what lets the layout rules be tested
/// against a plain list of messages.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_history.dart';
import '../providers/sync_controller.dart';
import 'edit_history_sheet.dart';
import 'message_context_menu.dart';
import 'message_jump.dart';
import 'message_transcript_dividers.dart';
import 'message_row.dart';
import 'message_row_callbacks.dart';
import 'message_selectable.dart';
import 'message_transcript_extent.dart';
import 'transcript_selection.dart';
import 'message_row_identity.dart';
import 'message_transcript_widgets.dart';

/// What a viewer may do to one message, decided by the screen because it is
/// the screen that knows who is looking and what they hold. The bool is
/// whether [message] already has a live thread - known to the transcript
/// alone, from `MessageExtras.threadChannelId`, so it is threaded through
/// as a parameter rather than the caller having to ask `MessageExtras`
/// again for something already in hand.
typedef MessageActionsFor =
    MessageActions Function(Message message, bool hasExistingThread);

/// Past this many rows a thread scrolls as an ordinary reversed list.
const int _shrinkWrapThreadMax = 40;

class MessageTranscript extends StatefulWidget {
  const MessageTranscript({
    super.key,
    required this.channelId,
    required this.messages,
    required this.syncStatus,
    required this.historyKnown,
    this.channelName,
    this.channelIsThread = false,
    this.channelIsVoice = false,
    this.channelTopic,
    this.threadParent,
    required this.scrollController,
    required this.lastReadSeq,
    required this.selfId,
    required this.knownUsernames,
    this.knownRoleNames = const {},
    required this.customEmoji,
    required this.history,
    required this.onLoadOlder,
    required this.onRetryOlder,
    required this.actionsFor,
    required this.onRetry,
    required this.onDiscard,
    this.onEditFailed,
    required this.onPickReaction,
    required this.onReactionTap,
    required this.onVote,
    required this.onSubmitEdit,
    required this.onCancelEdit,
    required this.onJumpToReply,
    this.jumpTargetId,
    this.jumpToken,
    this.onJumpArrived,
  });

  /// The message a thread hangs off, shown as the transcript's first item once
  /// history reaches its start; null for a channel.
  final Widget? threadParent;

  /// Only used to scope [editingMessageIdProvider] per row; nothing here
  /// otherwise reaches the network or the store, per this file's own doc
  /// comment above.
  final String channelId;

  final List<Message> messages;

  /// Read only to tell an empty channel from one that has not caught up.
  final SyncStatus syncStatus;

  /// Whether this session's first catch-up round has completed, independent
  /// of whether the live socket ever attaches afterward. See [isNewDay]:
  /// this is what stops an optimistic send racing that first catch-up from
  /// briefly anchoring a day divider it does not really own.
  final bool historyKnown;

  /// The channel's name and topic, for the start-of-channel header above the
  /// oldest message. Null on a surface that has no such header (a DM, whose
  /// "name" is a person, or a voice channel), which simply omits it.
  final String? channelName;

  /// Whether this is a voice channel's chat; picks the empty-state copy.
  final bool channelIsVoice;

  /// Whether this transcript is a thread's own, which takes its own start
  /// copy rather than a channel welcome with an empty name in it.
  final bool channelIsThread;
  final String? channelTopic;

  final ScrollController scrollController;
  final int lastReadSeq;

  /// This account's own user id, so a message it wrote never counts as
  /// unread to it. Null before a session exists, which matches nothing.
  final String? selfId;

  final Set<String> knownUsernames;

  /// Lower-cased role names an `@[Role Name]` mention can be matched
  /// against; see `MessageBody.knownRoleNames` in `message_text.dart`.
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;

  /// How much of the channel is loaded. Only [ChannelHistory.atStart] lets the
  /// start-of-channel header render; anything else puts a loading affordance
  /// in its place, because the oldest loaded row is not known to be the first.
  final ChannelHistory history;

  /// Fired whenever the oldest end of the list comes into view, which the
  /// reverse below puts at the maximum scroll extent rather than the minimum.
  final VoidCallback onLoadOlder;
  final VoidCallback onRetryOlder;

  final MessageActionsFor actionsFor;

  final void Function(Message message) onRetry;
  final void Function(Message message) onDiscard;

  /// Recovers a failed message's text into the composer; see MessageRow.
  final void Function(Message message)? onEditFailed;
  final void Function(Message message, String emoji) onPickReaction;
  final void Function(Message message, api.ReactionSummary reaction)
  onReactionTap;
  final void Function(Message message, int option) onVote;
  final void Function(Message message, String content) onSubmitEdit;
  final VoidCallback onCancelEdit;

  /// Jumps to the message named by a reply's `replyToId`, whether or not the
  /// row's own compact quote managed to resolve a preview for it locally.
  final void Function(String replyToId) onJumpToReply;

  /// A jump ([messageJumpProvider]) has landed on this message id: scroll to
  /// it and flash it. Null the rest of the time.
  final String? jumpTargetId;

  /// Identifies which arrival [jumpTargetId] is, so a fresh jump to the same
  /// id (asked for twice) still mounts a fresh flash rather than reusing one
  /// already fading out.
  final int? jumpToken;

  /// Called once the jump has actually scrolled to and started flashing the
  /// target, so the caller can tell the jump controller this arrival is
  /// handled.
  final VoidCallback? onJumpArrived;

  @override
  State<MessageTranscript> createState() => _MessageTranscriptState();
}

class _MessageTranscriptState extends State<MessageTranscript> {
  /// Message ids already on screen at least once. The newest row animates in
  /// only when its id is not in here, so a genuinely new arrival slides in
  /// while the initial load, a recycle on scroll-back, and an unrelated parent
  /// rebuild all render it statically. Reset with the widget, which is per
  /// channel, so switching channels does not replay a stale entrance.
  final Set<String> _seen = {};
  bool _hydrated = false;

  /// Kept across rebuilds on purpose; see its own doc comment for why living
  /// on the per-build delegate would defeat it.
  final TranscriptExtentEstimator _extent = TranscriptExtentEstimator();

  /// How close to the oldest end still counts as having reached it, so a page
  /// starts before the reader hits a hard stop.
  static const double _loadOlderSlop = 240;

  /// The last jump token already given a rough scroll, so a rebuild carrying
  /// the same token (a new message arriving elsewhere, say) does not keep
  /// re-jumping a reader who has since scrolled away on their own.
  int? _estimatedJumpToken;

  /// How many rounds [_refineJumpScroll] jumps and re-reads the estimate for.
  /// A [ListView.builder] only knows the true extent of what it has actually
  /// laid out, and rows here vary sharply - a grouped continuation is far
  /// shorter than a headed one - so `maxScrollExtent` measured from whatever
  /// handful of rows sat at the bottom before the jump routinely undershoots
  /// the real total several times over. Jumping once, letting a frame
  /// settle, and re-reading it again converges on the right spot as more of
  /// the list gets measured, which a single jump cannot; a fixed round count
  /// bounds it rather than looping until some notion of "close enough".
  static const int _jumpRefineRounds = 6;

  /// [ListView.builder] only builds what is near the viewport, so a target
  /// row far from wherever the reader currently is has no context yet for
  /// [MessageJumpHighlight] to call `Scrollable.ensureVisible` on. This gets
  /// the reader close by proportion of position in the loaded list - an
  /// estimate, not exact, since rows vary in height - which is what puts the
  /// real target within the list's cache extent so it actually gets built
  /// and can then correct itself precisely.
  void _estimateJumpScroll() {
    final token = widget.jumpToken;
    final targetId = widget.jumpTargetId;
    if (token == null || targetId == null || token == _estimatedJumpToken) {
      return;
    }
    final index = widget.messages.indexWhere((m) => m.id == targetId);
    final span = widget.messages.length - 1;
    if (index == -1 || span <= 0) return;
    _estimatedJumpToken = token;
    unawaited(_refineJumpScroll(token, index, span));
  }

  /// [ScrollController.jumpTo] fires its listeners synchronously, and doing
  /// that straight out of [build] reaches a sibling `ValueListenableBuilder`
  /// mid-build, which Flutter refuses; every round below awaits a frame
  /// first, including the first, for that reason alone.
  Future<void> _refineJumpScroll(int token, int index, int span) async {
    for (var round = 0; round < _jumpRefineRounds; round++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || widget.jumpToken != token) return;
      if (!widget.scrollController.hasClients) return;
      final position = widget.scrollController.position;
      // Reversed: the newest sits at the minimum extent, the oldest at the maximum, so distance from the newest end is the fraction below.
      final fromNewest = widget.messages.length - 1 - index;
      final estimate = position.maxScrollExtent * fromNewest / span;
      widget.scrollController.jumpTo(
        estimate.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(MessageTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different channel's rows may be sized quite differently, so what settled against these ones stops being evidence about anything.
    if (oldWidget.channelId != widget.channelId) _extent.reset();
    if (oldWidget.scrollController == widget.scrollController) return;
    oldWidget.scrollController.removeListener(_onScroll);
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  /// The list is reversed, so the oldest message sits at the *maximum* extent;
  /// the minimum is the newest, which is where `_scrollToLatest` goes.
  void _onScroll() {
    final controller = widget.scrollController;
    if (!controller.hasClients) return;
    final position = controller.position;
    if (position.maxScrollExtent - position.pixels > _loadOlderSlop) return;
    widget.onLoadOlder();
  }

  /// A list shorter than its viewport never scrolls, so nothing would ever
  /// ask for the page that would prove where the channel starts.
  ///
  /// Called only once [build] is about to lay out a real, populated list.
  /// Every loaded row can be filtered from view (a channel whose visible tail
  /// is entirely a blocked author, say), and an empty transcript then renders
  /// as a bare [SingleChildScrollView] whose `maxScrollExtent` is always zero
  /// - indistinguishable, to [_onScroll], from a genuine scroll to the end.
  /// Gating on there being an actual list is a structural fact about what is
  /// on screen, not a threshold: a counter would still fire this once before
  /// it could trip, and forgets, the moment it resets, why it should not fire
  /// again the next time every row is filtered.
  ///
  /// Whether the ask is worth making is [ChannelHistoryController.loadOlder]'s
  /// decision alone; scheduling nothing once the start is known only saves the
  /// callback.
  void _checkAfterLayout() {
    if (widget.history.atStart) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  /// The slot at the very top of the loaded window: always present, never
  /// absent, so the list's own item count never shifts by one right where the
  /// reader is scrolled when a page lands - only what fills it changes.
  ///
  /// Returning null here for a DM once history reached its true start used to
  /// be exactly that shift: paging only ever triggers near the far end of the
  /// loaded list, so the one item that could vanish always vanished right
  /// under the reader's own scroll offset. [ChannelStartHeader] renders
  /// generic copy for a DM now instead of nothing, closing the gap without
  /// reopening the "Welcome to # a person's name" wording it was never meant
  /// to say.
  Widget _topSlot() {
    if (!widget.history.atStart) {
      return HistoryTopAffordance(
        failed: widget.history.failed,
        loading: widget.history.loading,
        onRetry: widget.onRetryOlder,
      );
    }
    if (widget.channelIsThread) {
      return widget.threadParent ?? const SizedBox.shrink();
    }
    return ChannelStartHeader(
      name: widget.channelName,
      topic: widget.channelTopic,
      isThread: widget.channelIsThread,
      isVoice: widget.channelIsVoice,
    );
  }

  /// A short thread reads from the top (parent, replies, free space below); a channel stays bottom-anchored against its composer.
  @override
  Widget build(BuildContext context) => widget.channelIsThread
      ? Align(alignment: Alignment.topCenter, child: _transcript(context))
      : _transcript(context);

  Widget _transcript(BuildContext context) {
    final messages = widget.messages;
    final start = _topSlot();
    // Shrink-wrapped, a thread lays out every row: affordable only while it is short.
    final shrinkWrap =
        widget.channelIsThread && messages.length <= _shrinkWrapThreadMax;

    if (messages.isEmpty) {
      // Reverse-anchored like the populated list below, so the welcome sits above the composer, not at the top of an empty pane.
      if (widget.syncStatus == SyncStatus.live) {
        return ListView(
          controller: widget.scrollController,
          reverse: true,
          shrinkWrap: shrinkWrap,
          padding: const EdgeInsets.only(bottom: AppSpacing.s8),
          children: [
            if (widget.channelIsThread)
              const ChannelStartHeader(name: null, isThread: true),
            start,
          ],
        );
      }
      final waiting = EmptyMessages(syncStatus: widget.syncStatus);
      if (!widget.channelIsThread) return waiting;
      // The parent is known without the sync, so it shows even while the replies cannot.
      return Column(
        children: [
          widget.threadParent ?? const SizedBox.shrink(),
          Expanded(child: waiting),
        ],
      );
    }

    _checkAfterLayout();
    _estimateJumpScroll();
    final newestId = messages.last.id;
    final animateNewest = _hydrated && !_seen.contains(newestId);
    // Everything on screen counts as seen, so a recycle never replays.
    _seen.addAll(messages.map((m) => m.id));
    _hydrated = true;

    // A reply's parent, built from the same already-filtered list this transcript renders; see `reply_quote.dart`.
    final byId = {for (final m in messages) m.id: m};
    final order = [for (final m in messages) m.id];

    // Reversed so a short conversation sits against the composer; the start header rides one past the oldest message, which reverse puts at the top.
    return TranscriptSelection(
      child: ListView.custom(
        controller: widget.scrollController,
        reverse: true,
        shrinkWrap: shrinkWrap,
        padding: const EdgeInsets.only(bottom: AppSpacing.s8),
        semanticChildCount: messages.length + 1,
        childrenDelegate: TranscriptChildDelegate(
          (context, i) {
            if (i == messages.length) return start;
            // Index 0 is the newest; `previous` stays the row visually above,
            // so grouping still reads right.
            final index = messages.length - 1 - i;
            final message = messages[index];
            final previous = index == 0 ? null : messages[index - 1];
            final newDay = isNewDay(
              message,
              previous,
              historyKnown: widget.historyKnown,
            );
            final row = MessageRowExtras(
              // By message, not by slot: an arrival shifts every index by one.
              key: ValueKey(message.id),
              messageId: message.id,
              channelId: widget.channelId,
              previousMessageId: previous?.id,
              builder: (extras, editing, previousWebhookUsername) => MessageSelectable(
                channelId: widget.channelId,
                messageId: message.id,
                order: order,
                child: MessageRow(
                  message: message,
                  // A new day breaks a group so a continuation across midnight regains its avatar and header.
                  grouped:
                      isGrouped(
                        message,
                        previous,
                        webhookUsername: extras.webhookUsername,
                        previousWebhookUsername: previousWebhookUsername,
                      ) &&
                      !newDay,
                  showNewDivider: startsUnread(
                    message,
                    previous,
                    widget.lastReadSeq,
                    widget.selfId,
                  ),
                  dayLabel: newDay ? formatMessageDay(message.createdAt) : null,
                  knownUsernames: widget.knownUsernames,
                  knownRoleNames: widget.knownRoleNames,
                  customEmoji: widget.customEmoji,
                  callbacks: MessageRowCallbacks(
                    onRetry: () => widget.onRetry(message),
                    onDiscard: () => widget.onDiscard(message),
                    onEditFailed: widget.onEditFailed == null
                        ? null
                        : () => widget.onEditFailed!(message),
                    onPickReaction: (emoji) =>
                        widget.onPickReaction(message, emoji),
                    onReactionTap: (reaction) =>
                        widget.onReactionTap(message, reaction),
                    onVote: (option) => widget.onVote(message, option),
                    onSubmitEdit: (content) =>
                        widget.onSubmitEdit(message, content),
                    onCancelEdit: widget.onCancelEdit,
                    onViewEditHistory: () => showMessageEditHistorySheet(
                      context,
                      widget.channelId,
                      message.id,
                    ),
                    onReplyTap: switch (message.replyToId) {
                      final String id => () => widget.onJumpToReply(id),
                      null => null,
                    },
                  ),
                  extras: extras,
                  viewerIsCaller:
                      extras.call?.callerId != null &&
                      extras.call?.callerId == widget.selfId,
                  // A null replyToId is a null map key here, which is a null lookup - the same "no parent" the row renders as nothing.
                  replyTo: byId[message.replyToId],
                  replyParentAdjacent: message.replyToId == previous?.id,
                  editing: editing,
                  actions: widget.actionsFor(
                    message,
                    extras.threadChannelId != null,
                  ),
                ),
              ),
            );
            final content = message.id == widget.jumpTargetId
                ? MessageJumpHighlight(
                    key: ValueKey('jump-${widget.jumpToken}'),
                    onArrived: widget.onJumpArrived ?? () {},
                    child: row,
                  )
                : row;
            if (i != 0) return content;
            return MessageEntrance(
              key: ValueKey('entrance-$newestId'),
              animateOnMount: animateNewest,
              child: content,
            );
          },
          childCount: messages.length + 1,
          estimator: _extent,
        ),
      ),
    );
  }
}
