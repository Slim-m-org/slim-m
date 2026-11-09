// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel's main body below the header: either the live search-results
/// list or the live transcript stream plus its jump-to-latest control,
/// whichever `channelSearchProvider` says is current for this channel.
///
/// Split out of `channel_screen.dart`, which had no line budget left to grow
/// into and already carries the header, search bar and composer wiring.
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

import '../../members/providers/blocks_controller.dart';
import '../../members/providers/bot_ui_uses.dart';
import '../providers/channel_history.dart';
import '../providers/channel_permissions.dart';
import '../providers/channel_search_controller.dart';
import '../../emoji/providers/emoji_catalog_provider.dart';
import '../../messages/providers/ephemeral_messages.dart';
import '../../members/providers/member_presence.dart';
import '../../messages/providers/message_actions.dart';
import '../../messages/providers/message_editing.dart';
import '../../messages/providers/message_jump.dart';
import '../providers/pins_controller.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';
import '../../members/providers/user_profiles.dart';
import '../widgets/channel_search.dart';
import '../widgets/compact_channel_search.dart' show channelSearchScope;
import '../../../widgets/dismiss_keyboard_on_drag.dart';
import '../../messages/widgets/ephemeral_report.dart';
import '../../messages/widgets/jump_to_latest_button.dart';
import '../../messages/widgets/message_jump.dart';
import '../../messages/widgets/message_transcript.dart';
import '../../messages/widgets/thread_parent_card.dart';
import 'channel_message_actions.dart';
import 'channel_screen.dart' show knownRoleNamesFrom, knownUsernamesFrom;
import 'channel_screen_streams.dart';
import 'channel_transcript_scroll.dart';

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
    this.searchPage = false,
    required this.lastReadSeq,
    required this.syncedSeq,
    required this.manuallyUnread,
    required this.onMarkRead,
    required this.onReply,
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

  /// The phone's search page is up: it shows in place of the transcript even
  /// before a query, and a jump arriving from elsewhere closes it.
  final bool searchPage;
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

  /// A hit in another channel (an `in:` search) leaves this one, so its search clears.
  void _openHit(BuildContext context, WidgetRef ref, api.Message hit) {
    if (hit.channelId != channelId) {
      ref.read(channelSearchProvider(channelId).notifier).toggle();
    }
    jumpToMessage(
      GoRouter.of(context),
      ref.read,
      currentChannelId: channelId,
      channelId: hit.channelId,
      messageId: hit.id,
    );
  }

  /// Results stay up while the hit is found, then give way to its row; a new query drops the jump.
  void _closeSearchOnArrival(WidgetRef ref) {
    ref.listen(messageJumpProvider, (_, next) {
      final resultsShowing =
          searchPage ||
          ref.read(channelSearchProvider(channelId)).query != null;
      if (next is MessageJumpArrived &&
          next.channelId == channelId &&
          resultsShowing) {
        ref.read(channelSearchProvider(channelId).notifier).toggle();
      }
    });
    ref.listen(channelSearchProvider(channelId).select((s) => s.query), (
      _,
      query,
    ) {
      if (query != null) {
        ref.read(messageJumpProvider.notifier).cancelFor(channelId);
      }
    });
    // A refusal belongs to the search it came from, so a reopened one starts clean.
    ref.listen(channelSearchProvider(channelId).select((s) => s.open), (
      _,
      open,
    ) {
      if (!open) {
        ref.read(messageJumpProvider.notifier).clearNoticeFor(channelId);
      }
    });
  }

  Widget? _jumpBanner(WidgetRef ref, JumpNotice? notice) {
    if (notice == null) return null;
    final jump = ref.read(messageJumpProvider.notifier);
    return AppErrorState(
      message: notice.text,
      onRetry: notice.retryable
          ? () => unawaited(jump.jumpTo(channelId, notice.messageId))
          : null,
      onDismiss: notice.retryable
          ? null
          : () => jump.dismissNotice(notice.token),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(channelSearchProvider(channelId));
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
    final searchShowing = search.query != null || searchPage;
    final jumpArrival = watchMessageJump(
      ref,
      context,
      channelId,
      inlineNotice: searchShowing,
    );
    final jumpSeeking = ref.watch(
      messageJumpProvider.select((s) => jumpSeekingIn(s, channelId)),
    );
    final jumpNotice = ref.watch(
      messageJumpProvider.select((s) => jumpNoticeFor(s, channelId)),
    );
    _closeSearchOnArrival(ref);

    return Expanded(
      child: DismissKeyboardOnDrag(
        // Tapping the transcript dismisses the keyboard, which on a phone otherwise covers what the tap was aiming at.
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Kept mounted under the results, so closing the search returns the reader to where they were.
              Visibility(
                visible: !searchShowing,
                maintainState: true,
                child: Stack(
                  children: [
                    StreamBuilder<List<Message>>(
                      stream: streams.transcript(
                        store,
                        channelId,
                        history.window,
                      ),
                      builder: (context, snapshot) {
                        final rows = snapshot.data ?? const <Message>[];
                        final transcript = visibleTranscript(rows, blocked);
                        final oldest = oldestDeliveredSeq(rows);
                        paging.syncOldest(oldest);
                        resolveAuthorProfiles(ref, [
                          ...transcript.messages.map((m) => m.authorId),
                          ...privateAnswers.map((m) => m.authorId),
                        ]);
                        // A deleted newest message leaves nothing to show, but must not leave the channel unread.
                        final readUpTo = math.max(
                          transcript.newestSeq,
                          syncedSeq,
                        );
                        scrollTracker.updateKnownSeqs(
                          latestSeq: readUpTo,
                          lastReadSeq: lastReadSeq,
                          manuallyUnread: manuallyUnread,
                        );
                        // Gated on the viewport and on the search being closed: scrolled into history, this rebuild is a message arriving somewhere unread.
                        if (scrollTracker.atLatest && !searchShowing) {
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
                          onReportPrivate: (m) =>
                              unawaited(reportEphemeralMessage(context, m)),
                          syncStatus: syncStatus,
                          historyKnown: historyKnown,
                          channelName: hashChannelName,
                          channelIsThread: isThread,
                          channelIsVoice: isVoice,
                          channelTopic: channelTopic,
                          threadParent: isThread
                              ? ThreadParentSlot(channelId: channelId)
                              : null,
                          scrollController: scrollTracker.controller,
                          lastReadSeq: lastReadSeq,
                          knownUsernames: knownUsernames,
                          knownRoleNames: knownRoleNames,
                          customEmoji: customEmoji,
                          // A channel with nothing delivered has no history to page, so its oldest loaded row is vacuously its first.
                          history: history.copyWith(
                            atStart:
                                history.atStart ||
                                (oldest == null &&
                                    syncStatus == SyncStatus.live),
                          ),
                          onLoadOlder: () => unawaited(paging.loadOlder()),
                          onRetryOlder: () => unawaited(paging.retry()),
                          // The policy itself lives in `channel_message_actions.dart`; this only supplies the pane's own state.
                          actionsFor: (message, hasExistingThread) =>
                              messageActionsFor(
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
                          onDiscard: (m) =>
                              unawaited(discardMessage(ref.read, m)),
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
                            setReaction(
                              ref,
                              m.id,
                              reaction.emoji,
                              wasActive: reaction.reacted,
                            ),
                          ),
                          onVote: (m, option) =>
                              unawaited(castVote(ref, m.id, option)),
                          onRank: (m, ranking) =>
                              unawaited(castRanking(ref, m.id, ranking)),
                          onSubmitEdit: (m, content) =>
                              _submitEdit(context, m, content),
                          onCancelEdit: () => _cancelEdit(ref),
                          onJumpToReply: (replyToId) => jumpToMessage(
                            GoRouter.of(context),
                            ref.read,
                            currentChannelId: channelId,
                            channelId: channelId,
                            messageId: replyToId,
                          ),
                          jumpTargetId: jumpArrival?.messageId,
                          jumpToken: jumpArrival?.token,
                          onJumpArrived: jumpArrival == null
                              ? null
                              : () => ref
                                    .read(messageJumpProvider.notifier)
                                    .consume(jumpArrival.token),
                        );
                      },
                    ),
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
              if (searchShowing)
                ChannelSearchResults(
                  results: search.results,
                  knownUsernames: knownUsernames,
                  knownRoleNames: knownRoleNames,
                  customEmoji: customEmoji,
                  loading: search.loading,
                  failed: search.failed,
                  forbidden: search.forbidden,
                  onRetry: () => ref
                      .read(channelSearchProvider(channelId).notifier)
                      .run(search.query!),
                  onSelect: (m) => _openHit(context, ref, m),
                  seeking: jumpSeeking,
                  banner: _jumpBanner(ref, jumpNotice),
                  compact: searchPage,
                  query: search.query,
                  scope: channelSearchScope(
                    name: hashChannelName,
                    isVoice: isVoice,
                    isThread: isThread,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
