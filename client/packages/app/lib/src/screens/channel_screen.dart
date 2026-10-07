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
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ids.dart';
import '../providers/blocks_controller.dart';
import '../providers/channel_drafts.dart';
import '../providers/channel_search_controller.dart';
import '../providers/message_actions.dart';
import '../providers/message_extras.dart';
import '../providers/message_jump.dart';
import '../providers/mounted_channels.dart';
import '../providers/providers.dart';
import '../routing/breakpoints.dart';
import '../widgets/blocked_dm_notice.dart';
import '../widgets/channel_attachment_drop_zone.dart';
import '../widgets/channel_header.dart';
import '../widgets/channel_search.dart';
import 'channel_composer_area.dart';
import 'channel_read_marker.dart';
import 'channel_screen_streams.dart';
import 'channel_transcript_pane.dart';
import 'channel_transcript_scroll.dart';

export '../ids.dart' show newMessageId;

/// One channel's messages.
/// The usernames a mention can be matched against, read from the member
/// roster [members].
///
/// `valueOrNull`, never `maybeWhen(data:)`: an `AsyncError` keeps whatever
/// resolved before it, and only the first of those two can see that value.
/// Reading it the other way made a failed fetch indistinguishable from an
/// empty deployment, so every `@name` in view fell back to plain text the
/// moment the connection dropped (reported 2026-08-13, "mentions also get
/// unhighlighted when the server was offline").
///
/// A cold start with no connection genuinely has nothing to match against and
/// still renders mentions plain; that is the honest answer rather than a gap,
/// since nothing has ever told this client who the members are.
Set<String> knownUsernamesFrom(AsyncValue<List<api.UserProfile>> members) =>
    members.valueOrNull?.map((m) => m.username.toLowerCase()).toSet() ??
    const <String>{};

/// The role names an `@[Role Name]` mention can be matched against, read the
/// same `valueOrNull` way [knownUsernamesFrom] is for the identical reason:
/// a failed refresh must not unhighlight a role mention that was already on
/// screen. Derived from [members]'s own `roles` field (`GET /members`,
/// requiring no permission beyond viewing the roster) rather than a
/// dedicated roles listing, which stays MANAGE_ROLES-gated - so a role
/// nobody currently visible holds is not offered here, the same boundary
/// the member-badge feature this reuses already draws.
Set<String> knownRoleNamesFrom(AsyncValue<List<api.UserProfile>> members) =>
    members.valueOrNull
        ?.expand((m) => m.roles)
        .map((name) => name.toLowerCase())
        .toSet() ??
    const <String>{};

class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({
    required this.channelId,
    this.isThread = false,
    this.showHeader = true,
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

  /// See `ComposerAutofocus`; only the docked thread pane sets it.
  final bool autofocusComposer;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  final _composer = TextEditingController();

  /// The query text only; the search itself (open, hits, failure) lives in
  /// [channelSearchProvider], which the compact app bar drives too.
  final _searchController = TextEditingController();

  /// The message the next send will reply to, if any. Cleared by sending,
  /// by an explicit cancel, and by switching channels - a reply is scoped to
  /// the conversation it was started in, not carried across a channel switch.
  Message? _replyingTo;

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
    unawaited(_hydrateExtras());
    // Fresh or reused (see [ReadMarker]), this must open on this channel's own draft.
    _composer.text = _drafts.draftFor(widget.channelId);
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
      _searchController.clear();
      // A jump neither finished nor consumed before the switch must not
      // replay against whichever channel is open next.
      ref.read(messageJumpProvider.notifier).cancelFor(oldWidget.channelId);
      _replyingTo = null;
      _scrollTracker.resetForChannelSwitch();
      _drafts.save(oldWidget.channelId, _composer.text);
      _composer.text = _drafts.draftFor(widget.channelId);
      // Re-seed extras: on a route that reuses this State across a switch (a thread modal), initState ran only for the first channel, leaving synced messages' reactions, polls and attachments blank until a live event touched them.
      unawaited(_hydrateExtras());
    }
  }

  Future<void> _hydrateExtras() async {
    try {
      final recent = await ref
          .read(apiProvider)
          .listMessages(widget.channelId, limit: 50);
      if (!mounted) return;
      ref.read(messageExtrasProvider.notifier).applyMessages(recent);
    } on api.ApiException {
      // Nothing useful to do; a live event or the next channel open corrects it.
    }
  }

  @override
  void dispose() {
    _mountedChannels.unregister(widget.channelId);
    // Last chance to save unsent text before a torn-down State (voice, a DM call, canvas) loses it.
    _drafts.save(widget.channelId, _composer.text);
    _composer.dispose();
    _scrollTracker.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Sends, showing the message immediately and reconciling with the server's
  /// copy when it lands. The field is cleared before the first await, so two
  /// calls in one turn cannot both read the same text: the second finds it
  /// empty and returns.
  Future<void> _send(List<String> attachmentIds) async {
    final text = _composer.text.trim();
    // A staged file is a message on its own, so only a send carrying neither
    // text nor attachment is the one to drop.
    if (text.isEmpty && attachmentIds.isEmpty) return;
    _composer.clear();
    _drafts.clear(widget.channelId);
    // Read and cleared before the first await, same as the composer text.
    final replyToId = _replyingTo?.id;
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
      replyToId: replyToId,
      onQueued: _scrollToLatest,
    );
    _scrollToLatest();
  }

  void _startReply(Message message) => setState(() => _replyingTo = message);

  void _cancelReply() => setState(() => _replyingTo = null);

  /// Both the flag and the query live in [channelSearchProvider] so the
  /// compact layout's app bar, built above this screen, can drive them too.
  void _search(String query) =>
      ref.read(channelSearchProvider(widget.channelId).notifier).run(query);

  void _toggleSearch() =>
      ref.read(channelSearchProvider(widget.channelId).notifier).toggle();

  void _markReadUpToLatest(int seq, int lastReadSeq, bool manuallyUnread) =>
      _readMarker.advance(
        widget.channelId,
        seq: seq,
        lastReadSeq: lastReadSeq,
        manuallyUnread: manuallyUnread,
      );

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
    final search = ref.watch(channelSearchProvider(widget.channelId));
    // Search can now be closed from the app bar as well as from the header,
    // and either way the field it typed into has to empty with it.
    ref.listen(channelSearchProvider(widget.channelId).select((s) => s.open), (
      _,
      open,
    ) {
      if (!open) _searchController.clear();
    });
    final blocked = ref.watch(blocksProvider.select((state) => state.ids));

    return storeAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          const Center(child: Text('Could not open the local store.')),
      data: (store) => StreamBuilder<Channel?>(
        stream: _streams.channelRow(store, widget.channelId),
        builder: (context, channelSnapshot) {
          final channel = channelSnapshot.data;
          final channelName = channel?.name ?? '';
          final lastReadSeq = channel?.lastReadSeq ?? 0;
          final manuallyUnread = channel?.manuallyUnread ?? false;
          final dmPartnerId = channel?.dmParticipantId;
          final blockedDm =
              dmPartnerId != null && blocked.contains(dmPartnerId);
          // Ored with the store's own answer; see isThread's doc comment.
          final isThread = widget.isThread || channel?.parentMessageId != null;
          // Only a real named channel gets "#name"; shared so the transcript and composer cannot drift.
          final hashChannelName = channel?.kind == 'text' ? channelName : null;
          final isVoice = channel?.kind == 'voice';
          final isDm = channel?.kind == 'dm';
          final isPersonalSpace = channel?.isPersonalSpace ?? false;

          // Local fn, not an inline wrapper, so the transcript keeps its indentation.
          Widget content() => Column(
            children: [
              // A thread supplies its own bar at every width; see thread_screen.dart.
              if (layout.showsBothPanes && !isThread && widget.showHeader)
                ChannelHeader(
                  channelId: widget.channelId,
                  name: channelName,
                  topic: channel?.topic,
                  isVoice: isVoice,
                  isDm: isDm,
                  dmParticipantId: dmPartnerId,
                  isPersonalSpace: isPersonalSpace,
                  restricted: channel?.restricted ?? false,
                  searchOpen: search.open,
                  onToggleSearch: _toggleSearch,
                ),
              AppRevealBand(
                child: search.open
                    ? ChannelSearchBar(
                        controller: _searchController,
                        onChanged: _search,
                      )
                    : null,
              ),
              ChannelTranscriptPane(
                channelId: widget.channelId,
                store: store,
                streams: _streams,
                scrollTracker: _scrollTracker,
                composer: _composer,
                hashChannelName: isVoice ? channelName : hashChannelName,
                isVoice: isVoice,
                channelTopic: channel?.topic,
                isThread: isThread,
                lastReadSeq: lastReadSeq,
                manuallyUnread: manuallyUnread,
                onMarkRead: _markReadUpToLatest,
                onReply: _startReply,
              ),
              if (blockedDm)
                BlockedDmNotice(userId: dmPartnerId, name: channelName)
              else
                ChannelComposerArea(
                  channelId: widget.channelId,
                  controller: _composer,
                  channelName: hashChannelName ?? '',
                  onSend: _send,
                  replyingTo: _replyingTo,
                  onCancelReply: _cancelReply,
                  autofocus: widget.autofocusComposer,
                ),
            ],
          );
          return ChannelAttachmentDropZone(
            channelId: widget.channelId,
            blockedDm: blockedDm,
            child: content(),
          );
        },
      ),
    );
  }
}
