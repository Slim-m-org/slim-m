// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The conversation: history, live arrivals, search, and the composer.
///
/// This screen holds the state a channel view has to carry across a rebuild
/// (what is being edited, what has been marked read, where the scroll is) and
/// wires the pieces together. The two things it used to also do live next
/// door now: `channel_message_actions.dart` acts on a single message, and
/// `widgets/message_transcript.dart` lays the list out.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../ids.dart';
import '../../../providers/app_lifecycle.dart';
import '../../accounts/providers/account_slot.dart';
import '../../members/providers/blocks_controller.dart';
import '../providers/channel_drafts.dart';
import '../providers/channel_history.dart';
import '../../messages/providers/message_actions.dart';
import '../../messages/providers/message_context_window.dart';
import '../../messages/providers/message_jump.dart';
import '../providers/mounted_channels.dart';
import '../../../providers/providers.dart';
import '../../messages/providers/reply_mention_preference.dart';
import '../../../routing/breakpoints.dart';
import '../../members/widgets/blocked_dm_notice.dart';
import '../../messages/widgets/message_transcript_widgets.dart' show DmAudience;
import '../widgets/channel_attachment_drop_zone.dart';
import '../widgets/channel_header.dart';
import '../../composer/widgets/composer_attachments.dart' show StagedSend;
import '../../composer/widgets/composer_text_controller.dart';
import 'channel_composer_area.dart';
import 'channel_draft_saver.dart';
import 'channel_read_marker.dart';
import 'channel_screen_streams.dart';
import 'channel_transcript_pane.dart';
import 'channel_transcript_scroll.dart';

export '../../../ids.dart' show newMessageId;

/// One channel's messages.
class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({
    required this.channelId,
    this.isThread = false,
    this.showHeader = true,
    this.fitContent = false,
    this.autofocusComposer = false,
    super.key,
  });

  final String channelId;

  /// True only from [ThreadScreen], which already knows what it is opening
  /// and does not need to ask the local store. The store's own
  /// `channel?.parentMessageId` is the fallback for the ordinary route
  /// through `ConversationPane`, which never sets this and has always relied
  /// on the row - but a thread reached by URL (a deep link, a reload while
  /// inside one, or `scripts/lib/e2e_threads.py`) has never fetched that row:
  /// a thread is excluded from `GET /channels` and `GET /dms` by design
  /// (docs/decisions/0005-threads.md), so `watchChannelRow` answers null and
  /// this screen built the full parent-channel header, `Pinned messages`,
  /// `Open canvas` and `Toggle member list` included - exactly the chrome
  /// `ThreadScreen`'s own doc comment says must never reach a thread.
  final bool isThread;

  /// False only from `voice_text_pane.dart`, which docks this beside a live
  /// call that already carries its own header
  /// (`_VoiceConversationHeader` in `home_shell.dart`). Left true,
  /// [ChannelHeader] would double up there: a second name/icon row, a second
  /// `CanvasOpenButton` for the same channel, and a "Toggle member list"
  /// button squeezed into a pane narrower than the roster it opens -
  /// [ThreadScreen] withholds this same header for the identical reason.
  /// Search and pins are not reachable from the docked pane as a result;
  /// acceptable for a secondary surface beside a live call, the same trade
  /// [ThreadScreen] already makes for its own docked transcript.
  final bool showHeader;

  /// Sizes to its messages up to the height it is given, for a sheet that
  /// should not open on empty space; a pane fills its height.
  final bool fitContent;

  /// See `ComposerAutofocus`; only the docked thread pane sets it.
  final bool autofocusComposer;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  final _composer = ComposerTextController();

  /// The message the next send will reply to, if any. Cleared by sending,
  /// by an explicit cancel, and by switching channels - a reply is scoped to
  /// the conversation it was started in, not carried across a channel switch.
  Message? _replyingTo;

  /// Bumped by Reply so the composer takes the caret, as the thread pane's does.
  final _composerFocusRequests = ValueNotifier<int>(0);

  late final ReadMarker _readMarker = ReadMarker(ref);

  /// The scroll controller, the jump-to-latest arrow's visibility, and the
  /// read-marking that follows from both; see `channel_transcript_scroll.dart`.
  late final TranscriptScrollTracker _scrollTracker = TranscriptScrollTracker(
    markRead: _markReadUpToLatest,
  );

  /// Captured once rather than read from `ref` in [dispose]: by then the
  /// element has already detached, and `ref.read` there throws "Cannot use
  /// ref after the widget was disposed" (see `composer.dart`'s own note on
  /// the same trap). The controller itself needs no further `ref` access
  /// once resolved, so holding it plainly is enough.
  late final ChannelDraftsController _drafts = ref.read(channelDraftsProvider);

  /// Writes the composer's text as it is typed; the switch and dispose saves
  /// below stay as the final flush.
  late final ChannelDraftSaver _draftSaver;

  /// Captured once, not read via `ref` in [dispose] - see [_drafts]'s own
  /// note for why. This is the registry `providers/retention_sweep.dart`
  /// reads to know which channels are actually open; see
  /// `providers/mounted_channels.dart`.
  late final MountedChannels _mountedChannels = ref.read(
    mountedChannelsProvider,
  );

  /// See `channel_screen_streams.dart`: recreates a channel's drift streams
  /// only when the store, channel id, or window actually change, rather than
  /// on every build the way an inline `store.watchChannel(...)` call did.
  final _streams = ChannelStreamCache();

  @override
  void initState() {
    super.initState();
    _mountedChannels.register(widget.channelId);
    // A context window from an earlier visit must not greet this one; deferred because providers cannot change while the tree builds.
    final channelId = widget.channelId;
    Future.microtask(
      () => ref.read(messageContextWindowProvider(channelId).notifier).close(),
    );
    unawaited(_hydrateExtras());
    // Fresh or reused (see [ReadMarker]), this must open on this channel's own draft.
    _composer.text = _drafts.draftFor(widget.channelId);
    _draftSaver = ChannelDraftSaver(
      composer: _composer,
      drafts: _drafts,
      channelId: () => widget.channelId,
    );
    unawaited(_fillFromRestore());
  }

  /// A reload opens on this channel before the disk read has finished, so the first draft lookup is empty.
  Future<void> _fillFromRestore() async {
    final channelId = widget.channelId;
    await _drafts.restored;
    if (!mounted || widget.channelId != channelId) return;
    if (_composer.text.isNotEmpty) return;
    _composer.text = _drafts.draftFor(channelId);
  }

  @override
  void didUpdateWidget(ChannelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // This State outlives a channel switch (see [ReadMarker]), so the field
    // would otherwise still hold the previous channel's query.
    if (oldWidget.channelId != widget.channelId) {
      _mountedChannels.unregister(oldWidget.channelId);
      _mountedChannels.register(widget.channelId);
      // A jump neither finished nor consumed before the switch must not
      // replay against whichever channel is open next.
      ref.read(messageJumpProvider.notifier).cancelFor(oldWidget.channelId);
      ref
          .read(messageContextWindowProvider(oldWidget.channelId).notifier)
          .close();
      _replyingTo = null;
      _scrollTracker.resetForChannelSwitch();
      _drafts.save(oldWidget.channelId, _composer.text);
      _composer.text = _drafts.draftFor(widget.channelId);
      // Re-seed extras: on a route that reuses this State across a switch (a thread modal), initState ran only for the first channel, leaving synced messages' reactions, polls and attachments blank until a live event touched them.
      unawaited(_hydrateExtras());
    }
  }

  /// Through the history controller, which outlives this screen: a channel
  /// closed mid-load must still end with the rows it stored carrying their extras.
  Future<void> _hydrateExtras() =>
      ref.read(channelHistoryProvider(widget.channelId).notifier).hydrate();

  @override
  void dispose() {
    _mountedChannels.unregister(widget.channelId);
    // Last chance to save unsent text before a torn-down State (voice, a DM call, canvas) loses it.
    _drafts.save(widget.channelId, _composer.text);
    _draftSaver.dispose();
    _composer.dispose();
    _composerFocusRequests.dispose();
    _scrollTracker.dispose();
    super.dispose();
  }

  /// Sends, showing the message immediately and reconciling with the server's
  /// copy when it lands. The field is cleared before the first await, so two
  /// calls in one turn cannot both read the same text: the second finds it
  /// empty and returns.
  Future<void> _send(StagedSend attachments) async {
    final attachmentIds = attachments.ids;
    final text = _composer.text.trim();
    // A staged file is a message on its own, so only a send carrying neither
    // text nor attachment is the one to drop.
    if (text.isEmpty && attachmentIds.isEmpty) return;
    // The sent row lands in the live window, so a context window would hide it.
    leaveContextWindow(ref, widget.channelId, _scrollTracker);
    _composer.clear();
    _drafts.clear(widget.channelId);
    // Read and cleared before the first await, same as the composer text.
    final replyToId = _replyingTo?.id;
    final mentionReply =
        _replyingTo?.authorId != ref.read(sessionProvider).tokens?.userId &&
        ref.read(replyMentionProvider);
    setState(() => _replyingTo = null);

    // The container outlives this screen, which a send can be left behind by.
    final container = ProviderScope.containerOf(context, listen: false);
    await sendOptimistically(
      container.read,
      id: newMessageId(),
      channelId: widget.channelId,
      authorId: container.read(sessionProvider).tokens?.userId ?? '',
      content: text,
      attachmentIds: attachmentIds,
      spoilerIds: attachments.spoilerIds,
      replyToId: replyToId,
      mentionReply: mentionReply,
      onQueued: _scrollToLatest,
    );
    _scrollToLatest();
  }

  void _startReply(Message message) {
    setState(() => _replyingTo = message);
    _composerFocusRequests.value++;
  }

  void _cancelReply() => setState(() => _replyingTo = null);

  /// The same test `ViewingReporter` applies before telling the server a channel is open.
  bool get _watched =>
      ref.read(appFocusedProvider) && ref.read(accountActiveProvider);

  void _markReadUpToLatest(int seq, int lastReadSeq, bool manuallyUnread) {
    // A search's context window is not the live channel, so its bottom is not the newest message.
    if (!_watched ||
        ref.read(messageContextWindowProvider(widget.channelId)) != null) {
      return;
    }
    _readMarker.advance(
      widget.channelId,
      seq: seq,
      lastReadSeq: lastReadSeq,
      manuallyUnread: manuallyUnread,
    );
  }

  void _readWhatArrivedUnwatched() {
    if (_watched) _scrollTracker.markReadIfAtLatest();
  }

  void _scrollToLatest() {
    if (!mounted) return;
    _scrollTracker.scrollToLatest(
      duration: AppMotion.reduced(context, AppMotion.slow),
    );
  }

  @override
  Widget build(BuildContext context) {
    final storeAsync = ref.watch(storeProvider);
    final layout = LayoutClass.of(context);
    ref.listen(appFocusedProvider, (_, _) => _readWhatArrivedUnwatched());
    ref.listen(accountActiveProvider, (_, _) => _readWhatArrivedUnwatched());
    final blocked = ref.watch(blocksProvider.select((state) => state.ids));

    return storeAsync.when(
      loading: () => const Center(child: AppSpinner(size: AppSpinnerSize.lg)),
      error: (e, _) =>
          const Center(child: Text('Could not open the local store.')),
      data: (store) => StreamBuilder<Channel?>(
        stream: _streams.channelRow(store, widget.channelId),
        builder: (context, channelSnapshot) => _body(
          store: store,
          channel: channelSnapshot.data,
          layout: layout,
          blocked: blocked,
        ),
      ),
    );
  }

  Widget _body({
    required MessageStore store,
    required Channel? channel,
    required LayoutClass layout,
    required Set<String> blocked,
  }) {
    final channelName = channel?.name ?? '';
    final dmPartnerId = channel?.dmParticipantId;
    final blockedDm = dmPartnerId != null && blocked.contains(dmPartnerId);
    // Ored with the store's own answer; see isThread's doc comment.
    final isThread = widget.isThread || channel?.parentMessageId != null;
    final isVoice = channel?.kind == 'voice';
    // Only a real named channel (text or voice) gets its name; shared so the transcript and composer cannot drift.
    final hashChannelName = channel?.kind == 'text' || isVoice
        ? channelName
        : null;
    return ChannelAttachmentDropZone(
      channelId: widget.channelId,
      blockedDm: blockedDm,
      child: Column(
        mainAxisSize: widget.fitContent ? MainAxisSize.min : MainAxisSize.max,
        children: [
          // A thread supplies its own bar at every width; see thread_screen.dart.
          if (layout.showsBothPanes && !isThread && widget.showHeader)
            ChannelHeader(
              channelId: widget.channelId,
              name: channelName,
              topic: channel?.topic,
              isVoice: isVoice,
              isDm: channel?.kind == 'dm',
              dmParticipantId: dmPartnerId,
              groupMemberIds: channel?.groupMemberIds ?? const [],
              isPersonalSpace: channel?.isPersonalSpace ?? false,
              restricted: channel?.restricted ?? false,
            ),
          ChannelTranscriptPane(
            channelId: widget.channelId,
            store: store,
            streams: _streams,
            scrollTracker: _scrollTracker,
            composer: _composer,
            hashChannelName: hashChannelName,
            isVoice: isVoice,
            dmAudience: channel?.isPersonalSpace ?? false
                ? DmAudience.self
                : channel?.isGroupDm ?? false
                ? DmAudience.group
                : DmAudience.pair,
            channelTopic: channel?.topic,
            isThread: isThread,
            lastReadSeq: channel?.lastReadSeq ?? 0,
            syncedSeq: channel?.cursor ?? 0,
            manuallyUnread: channel?.manuallyUnread ?? false,
            onMarkRead: _markReadUpToLatest,
            onReply: _startReply,
            fitContent: widget.fitContent,
          ),
          blockedDm
              ? BlockedDmNotice(userId: dmPartnerId, name: channelName)
              : ChannelComposerArea(
                  channelId: widget.channelId,
                  controller: _composer,
                  channelName: hashChannelName ?? '',
                  onSend: _send,
                  replyingTo: _replyingTo,
                  onCancelReply: _cancelReply,
                  autofocus: widget.autofocusComposer,
                  focusRequests: _composerFocusRequests,
                  reportsExtent: !isThread,
                ),
        ],
      ),
    );
  }
}
