// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel's main body below the header: the live transcript stream, its
/// jump-to-latest control, and how a jump to one of its messages is going.
///
/// Split out of `channel_screen.dart`, which had no line budget left to grow
/// into and already carries the header and composer wiring.
/// Every provider this reads (history, sync status, permissions, pins, the
/// member/emoji lookups, the jump arrival) was only ever used here, so this
/// watches them itself rather than being handed them by a screen `build()`
/// that has no other use for them; only the handful of things genuinely
/// owned by `_ChannelScreenState` - the shared streams cache, the scroll
/// tracker, the draft composer, and the reply/read-marker callbacks - are
/// passed in.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/known_mention_names.dart';
import '../../members/providers/blocks_controller.dart';
import '../../members/providers/bot_ui_uses.dart';
import '../providers/channel_history.dart';
import '../providers/channel_permissions.dart';
import '../../emoji/providers/emoji_catalog_provider.dart';
import '../../messages/providers/ephemeral_messages.dart';
import '../../members/providers/member_presence.dart';
import '../../messages/providers/message_actions.dart';
import '../../messages/providers/message_editing.dart';
import '../../messages/providers/message_context_window.dart';
import '../../messages/providers/message_jump.dart';
import '../providers/pins_controller.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';
import '../../members/providers/user_profiles.dart';
import '../../../widgets/dismiss_keyboard_on_drag.dart';
import '../../messages/widgets/context_window_bar.dart';
import '../../messages/widgets/ephemeral_report.dart';
import '../../messages/widgets/jump_to_latest_button.dart';
import '../../messages/widgets/message_jump.dart';
import '../../messages/widgets/message_jump_status.dart';
import '../../messages/widgets/message_transcript.dart';
import '../../messages/widgets/message_transcript_widgets.dart';
import '../../messages/widgets/thread_parent_card.dart';
import 'channel_message_actions.dart';
import 'channel_screen_streams.dart';
import 'channel_transcript_scroll.dart';

/// Back to the live window at its newest message, from Jump to present or a
/// send; does nothing while no context window is open.
void leaveContextWindow(
  WidgetRef ref,
  String channelId,
  TranscriptScrollTracker scrollTracker,
) {
  if (ref.read(messageContextWindowProvider(channelId)) == null) return;
  final jump = ref.read(messageJumpProvider);
  if (jumpArrivalFor(jump, channelId) case (:final token, messageId: _)) {
    ref.read(messageJumpProvider.notifier).consume(token);
  }
  ref.read(messageContextWindowProvider(channelId).notifier).close();
  scrollTracker.resetForChannelSwitch();
}

class ChannelTranscriptPane extends ConsumerWidget {
  const ChannelTranscriptPane({
    super.key,
    required this.channelId,
    required this.store,
    required this.streams,
    required this.scrollTracker,
    required this.composer,
    required this.hashChannelName,
    required this.channelTopic,
    required this.isThread,
    this.isVoice = false,
    this.dmAudience = DmAudience.pair,
    required this.lastReadSeq,
    required this.syncedSeq,
    required this.manuallyUnread,
    required this.onMarkRead,
    required this.onReply,
    this.fitContent = false,
  });

  final String channelId;
  final MessageStore store;
  final ChannelStreamCache streams;
  final TranscriptScrollTracker scrollTracker;

  /// The screen's own draft controller: [_onEditFailed] returns a failed
  /// send's text to it, the same recovery path a plain send failure gets.
  final TextEditingController composer;

  final String? hashChannelName;
  final String? channelTopic;
  final bool isThread;

  /// A voice channel's chat, whose empty state is not the text channel's.
  final bool isVoice;

  /// Who a DM is between, whose empty state speaks to a pair, a group or only you.
  final DmAudience dmAudience;

  final int lastReadSeq;

  /// The highest seq synced into this channel, deleted messages included; a
  /// reader at the bottom has seen everything up to it.
  final int syncedSeq;

  /// Mirrored from the server's own hand-mark flag; see `Channel.
  /// manuallyUnread`'s doc comment in `database.dart`. Threaded down to
  /// [onMarkRead] because reading a channel is the only client-side undo for
  /// it, and that undo has to fire even when [lastReadSeq] already equals the
  /// newest seq - see `channel_read_marker.dart`.
  final bool manuallyUnread;

  /// `_ChannelScreenState._markReadUpToLatest`: read-marking goes through
  /// its own `ReadMarker`, owned by the screen, not duplicated here.
  final void Function(int seq, int lastReadSeq, bool manuallyUnread) onMarkRead;

  /// `_ChannelScreenState._startReply`: shows the reply banner above the
  /// composer, which lives outside this pane entirely.
  final ValueChanged<Message> onReply;

  /// `ChannelScreen.fitContent`: as tall as the messages, not the space given.
  final bool fitContent;

  void _startEdit(WidgetRef ref, Message message) =>
      ref.read(editingMessageIdProvider(channelId).notifier).state = message.id;

  void _cancelEdit(WidgetRef ref) =>
      ref.read(editingMessageIdProvider(channelId).notifier).state = null;

  void _submitEdit(BuildContext context, Message message, String content) =>
      unawaited(submitMessageEdit(context, message, content));

  void _onEditFailed(WidgetRef ref, Message message) {
    composer.text = message.content;
    unawaited(discardMessage(ref.read, message));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final knownUsernames = ref.watch(
      membersProvider.select(knownUsernamesFrom),
    );
    final knownRoleNames = ref.watch(
      membersProvider.select(knownRoleNamesFrom),
    );
    final customEmoji = ref.watch(customEmojiIndexProvider);
    final blocked = ref.watch(blocksProvider.select((state) => state.ids));
    final history = ref.watch(channelHistoryProvider(channelId));
    final paging = ref.read(channelHistoryProvider(channelId).notifier);
    final syncStatus = ref.watch(syncControllerProvider);
    final historyKnown = ref.watch(initialSyncCompleteProvider);
    final myId = ref.watch(meProvider).valueOrNull?.id;
    final myPermissions = ref.watch(myChannelPermissionsProvider(channelId));
    final botUi =
        ref.watch(channelBotUiProvider(channelId)).valueOrNull ?? const [];
    final pinnedIds = <String>{
      for (final p
          in ref.watch(pinsControllerProvider(channelId)).pinned ??
              const <api.PinnedMessage>[])
        p.message.id,
    };
    final privateAnswers = ref.watch(
      channelEphemeralMessagesProvider(channelId),
    );
    final jumpArrival = watchMessageJump(ref, channelId);
    final contextWindow = ref.watch(messageContextWindowProvider(channelId));

    final transcript = StreamBuilder<List<Message>>(
      stream: contextWindow != null
          ? streams.contextTranscript(contextWindow.messages)
          : streams.transcript(store, channelId, history.window),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? const <Message>[];
        final transcript = visibleTranscript(rows, blocked);
        final oldest = oldestDeliveredSeq(rows);
        if (contextWindow == null) paging.syncOldest(oldest);
        resolveAuthorProfiles(ref, [
          ...transcript.messages.map((m) => m.authorId),
          ...privateAnswers.map((m) => m.authorId),
        ]);
        // A channel with nothing delivered has no history to page, so its oldest loaded row is vacuously its first.
        final shownHistory = contextWindow != null
            ? const ChannelHistory(atStart: true)
            : history.copyWith(
                atStart:
                    history.atStart ||
                    (oldest == null && syncStatus == SyncStatus.live),
              );
        // A deleted newest message leaves nothing to show, but must not leave the channel unread.
        final readUpTo = math.max(transcript.newestSeq, syncedSeq);
        scrollTracker.updateKnownSeqs(
          latestSeq: readUpTo,
          lastReadSeq: lastReadSeq,
          manuallyUnread: manuallyUnread,
        );
        final atLatest = scrollTracker.atLatest;
        // Gated on the viewport: scrolled into history, this rebuild is a message arriving somewhere unread.
        if (atLatest && contextWindow == null) {
          onMarkRead(readUpTo, lastReadSeq, manuallyUnread);
        }
        return MessageTranscript(
          channelId: channelId,
          selfId: ref.read(sessionProvider).tokens?.userId,
          messages: transcript.messages,
          privateAnswers: privateAnswers,
          onDismissPrivate: (m) => ref
              .read(ephemeralMessagesProvider.notifier)
              .dismiss(channelId, m.id),
          onReportPrivate: (m) => unawaited(reportEphemeralMessage(context, m)),
          syncStatus: syncStatus,
          historyKnown: historyKnown,
          channelName: hashChannelName,
          channelIsThread: isThread,
          channelIsVoice: isVoice,
          dmAudience: dmAudience,
          channelTopic: channelTopic,
          threadParent: isThread
              ? ThreadParentSlot(channelId: channelId)
              : null,
          scrollController: scrollTracker.controller,
          atLatest: atLatest,
          lastReadSeq: lastReadSeq,
          knownUsernames: knownUsernames,
          knownRoleNames: knownRoleNames,
          customEmoji: customEmoji,
          history: shownHistory,
          onLoadOlder: () => unawaited(paging.loadOlder()),
          onRetryOlder: () => unawaited(paging.retry()),
          // The policy itself lives in `channel_message_actions.dart`; this only supplies the pane's own state.
          actionsFor: (message, hasExistingThread) => messageActionsFor(
            ref,
            context,
            message,
            channelId: channelId,
            channelIsThread: isThread,
            hasExistingThread: hasExistingThread,
            myId: myId,
            myPermissions: myPermissions,
            pinnedIds: pinnedIds,
            onReply: onReply,
            onEdit: (m) => _startEdit(ref, m),
            botUi: botUi,
          ),
          onRetry: (m) => unawaited(retryMessage(ref.read, m)),
          onDiscard: (m) => unawaited(discardMessage(ref.read, m)),
          // Failed text lands back in the composer to fix and resend; the row is then discarded, so nothing typed is lost.
          onEditFailed: (m) => _onEditFailed(ref, m),
          onPickReaction: (m, emoji) => unawaited(
            setReaction(
              ref,
              m.id,
              emoji,
              wasActive: hasReacted(ref, m.id, emoji),
            ),
          ),
          onReactionTap: (m, reaction) => unawaited(
            setReaction(ref, m.id, reaction.emoji, wasActive: reaction.reacted),
          ),
          onVote: (m, option) => unawaited(castVote(ref, m.id, option)),
          onRank: (m, ranking) => unawaited(castRanking(ref, m.id, ranking)),
          onSubmitEdit: (m, content) => _submitEdit(context, m, content),
          onCancelEdit: () => _cancelEdit(ref),
          onJumpToReply: (replyToId) => jumpToMessage(
            GoRouter.of(context),
            ref.read,
            currentChannelId: channelId,
            channelId: channelId,
            messageId: replyToId,
          ),
          // Fills the space until its rows and the start of its history are in, so a fitted sheet never grows into them.
          fitContent: fitContent && snapshot.hasData && shownHistory.atStart,
          jumpTargetId: jumpArrival?.messageId,
          jumpToken: jumpArrival?.token,
          onJumpArrived: jumpArrival == null
              ? null
              : () => ref
                    .read(messageJumpProvider.notifier)
                    .consume(jumpArrival.token),
        );
      },
    );

    final fit = fitContent ? FlexFit.loose : FlexFit.tight;
    return Flexible(
      fit: fit,
      child: DismissKeyboardOnDrag(
        // Tapping the transcript dismisses the keyboard, which on a phone otherwise covers what the tap was aiming at.
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Stack(
            fit: fitContent ? StackFit.loose : StackFit.expand,
            children: [
              Column(
                mainAxisSize: fitContent ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  MessageJumpStatus(channelId: channelId),
                  Flexible(
                    fit: fit,
                    child: Stack(
                      children: [
                        transcript,
                        if (contextWindow == null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Center(
                              child: ValueListenableBuilder<bool>(
                                valueListenable: scrollTracker.scrolledAway,
                                builder: (context, scrolledAway, _) =>
                                    JumpToLatestButton(
                                      visible: scrolledAway,
                                      onTap: () => scrollTracker.scrollToLatest(
                                        duration: AppMotion.reduced(
                                          context,
                                          AppMotion.slow,
                                        ),
                                      ),
                                    ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // In flow, not over the list: a reversed list cannot scroll its newest row out from under a bar.
                  AppRevealBand(
                    child: contextWindow == null
                        ? null
                        : ContextWindowBar(
                            onJumpToPresent: () => leaveContextWindow(
                              ref,
                              channelId,
                              scrollTracker,
                            ),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
