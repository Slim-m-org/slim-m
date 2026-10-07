// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The thread panel: a message's hidden sub-channel, reached by "Reply in
/// thread" from the message context menu.
///
/// Reuses [ChannelScreen] wholesale for the transcript and the composer - a
/// thread is an ordinary channel with `parentMessageId` set
/// (docs/decisions/0005-threads.md), so nothing here needs to know how to
/// render a message or send one; that is [ChannelScreen]'s job already, and
/// it already tolerates a channel with no rail entry the way a DM does.
///
/// [ChannelScreen] builds its own `ChannelHeader` at any width that shows
/// both panes, which is correct for a channel opened through
/// `ConversationPane` and was wrong here: this bar is the only one a thread
/// gets at every width, so `channel_screen.dart` now skips its own header
/// for a thread channel specifically, rather than this screen forking it.
///
/// A thread is "sort of a temporary area to communicate" (the owner's own
/// words), so the header carries almost nothing: the back affordance and
/// the title, full stop. Everything `ChannelHeader` otherwise offers is
/// deliberately not wired in here at all, not merely hidden, and each was
/// weighed on its own rather than dropped as a block:
///
/// - Pin and the canvas are irrelevant to a side conversation this shallow -
///   a thread has no browsing surface of its own for a pinned set to be
///   rediscovered later, and a canvas button here was flagged as an unwanted
///   surface by the 2026-08-02 security review, not a thing anybody asked
///   for.
/// - The member-pane and channel-rail toggles are worse than irrelevant:
///   `memberPaneVisibleProvider` and `channelRailExpandedProvider`
///   (`widgets/member_pane.dart`, `widgets/channel_rail.dart`) are both bare
///   `StateProvider<bool>`, one flag for the whole app rather than one per
///   channel, and `HomeShell` reads them for whatever channel the router
///   currently has selected underneath this screen - not for the thread.
///   Wiring either button in here would flip UI chrome for the parent
///   channel a person cannot even see behind this overlay, which is exactly
///   the bug the owner reported: toggling the "member panel" control from
///   inside a thread opened the member pane for the channel behind it. Any
///   future overlay that reuses `ChannelHeader`'s controls needs to ask this
///   same question, since nothing about that provider shape stops it from
///   recurring.
/// The bar carries the same bottom hairline `CompactChannelAppBar` does,
/// and for the same reason: it shares `surfaceBase` with the transcript at
/// zero elevation, so without a border there is no visible boundary between
/// the bar and the messages under it. That was reported for the channel bar
/// and fixed there first; this one had it too.
///
/// - Search is the one kept, and only because it does not have that
///   shape: `channelSearchProvider` (`channel_search_controller.dart`) is a
///   `family` keyed by channel id, so a thread's own copy of it can only
///   ever open a search bar over the thread's own messages
///   (`thread_screen_test.dart` asserts the parent channel's copy of the
///   same provider is untouched). Kept scoped rather than dropped on the
///   same reasoning that would have dropped it: a control is fine here
///   exactly when it acts on the thread and nothing else.
///
/// `channel_screen.dart` decided "am I a thread" from the local store's
/// `channel?.parentMessageId`, which is what every widget test here seeds
/// directly and so never noticed that this screen reached by URL - a deep
/// link, a reload while inside a thread, or `scripts/lib/e2e_threads.py`
/// navigating straight to `#/thread/{id}` - has never fetched that row at
/// all: a thread is excluded from `GET /channels` and `GET /dms` by design
/// (docs/decisions/0005-threads.md), so the store answers null and every
/// piece of chrome this doc comment just spent thirty lines explaining why
/// to withhold came back anyway. `ChannelScreen` takes an `isThread` flag
/// this screen sets unconditionally - it already knows what it opened, so
/// there is no store round trip and nothing to race - and ORs it with the
/// store's own answer rather than replacing it, so the ordinary
/// `ConversationPane` route, which never sets the flag, keeps behaving
/// exactly as it did.
///
/// The title carries an explicit `Semantics(container: true, header: true)`
/// wrapper for a related reason: `AppBar(title: Text('Thread'))` alone
/// produced no semantics node of its own for the word, merging it upward
/// into the bar's own node instead, which leaves "Thread" reachable only as
/// part of a blob shared with the back button's tooltip. That is worse for
/// a screen reader, which can then only announce the whole blob rather than
/// being asked what this bar is titled.
///
/// It is kept for that reason alone, and an earlier version of this comment
/// claimed more than it should have. `container: true` does separate the
/// title in `flutter_test`'s framework-level semantics tree, which is what
/// `thread_screen_test.dart` asserts, and it does NOT change what Flutter
/// web projects into the DOM: a real browser run still shows the word merged
/// into the bar's node. So this did not fix the e2e scenario that was timing
/// out on it, and `scripts/lib/e2e_threads.py` waits on the back button's
/// tooltip instead, for reasons its own module doc gives. Do not read this
/// wrapper as making the title findable from a browser; it does not.
///
/// The title itself is "Thread in #general" once [threadParentProvider]
/// resolves, closing this screen's own worst orientation gap: a plain
/// "Thread" gave a person returning after a while, or arriving from a
/// notification, no way to tell which conversation a thread belonged to.
/// Plain "Thread" is what it falls back to while that answer is still in
/// flight, on error, or for a channel [threadParentProvider] genuinely
/// cannot resolve (a deleted parent, a permission lost between opening the
/// notification and this screen mounting) - never a stale or invented name.
///
/// The same resolved answer is also what [ThreadParentCard] renders above
/// the transcript: before this, the parent message was never shown anywhere
/// in the thread panel, so a thread carried replies with no visible subject.
/// A deleted parent or an anonymized author is the card's own concern, not
/// this screen's - see its doc comment.
///
/// The same resolved answer also closes a second, separate bug: a thread
/// opened cold never got a local `channels` row at all (see above), so
/// `MessageStore.setReadMarker`'s plain `UPDATE` silently no-op'd and the
/// unread divider sat above the first message every session even though the
/// server's own read state was correct. `_ensureThreadChannelRow` upserts a
/// real row - carrying the *real* `parentMessageId` this fetch resolved,
/// not a placeholder - the moment that answer lands, which both
/// materialises a row for the read marker to update and keeps
/// `replaceChannels`'s pruning rule (`parentMessageId IS NOT NULL`) from
/// ever mistaking this thread for one that dropped off the server's list.
/// It runs once, from `initState`, off a direct `ref.read(...future)`
/// rather than a `ref.listen` reacting to the same provider `build()`
/// separately watches for the title: two independent consumers of one
/// cached fetch (Riverpod dedupes the request itself), not one mechanism
/// doing double duty - simpler to reason about, and to test, than a
/// listener whose firing depends on this widget's own rebuild timing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import '../providers/threads.dart';
import '../routing/close_screen.dart';
import '../routing/routes.dart';
import '../widgets/compact_channel_app_bar.dart' show ChannelSearchAction;
import 'channel_screen.dart';

class ThreadScreen extends ConsumerStatefulWidget {
  const ThreadScreen({required this.channelId, this.onClose, super.key});

  final String channelId;

  /// Set when this screen is a docked side pane rather than the pushed modal
  /// route: there is no navigator entry to pop, so the leading control closes
  /// the pane through this instead of the route's own back affordance.
  final VoidCallback? onClose;

  @override
  ConsumerState<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends ConsumerState<ThreadScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(_ensureThreadChannelRow());
  }

  @override
  void didUpdateWidget(ThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // This modal route reuses the State across a thread switch, so the new thread's channel row must be ensured again; initState ran only for the first.
    if (oldWidget.channelId != widget.channelId) {
      unawaited(_ensureThreadChannelRow());
    }
  }

  Future<void> _ensureThreadChannelRow() async {
    final channelId = widget.channelId;
    final api.ThreadParent parent;
    try {
      parent = await ref.read(threadParentProvider(channelId).future);
    } on api.ApiException {
      // Best effort: the title stays "Thread" and the read marker stays unfixed for this session, same as today.
      return;
    }
    if (!parent.isThread || !mounted) return;
    final store = await ref.read(storeProvider.future);
    await store.upsertChannels([
      api.Channel(
        id: channelId,
        name: threadChannelName,
        kind: 'text',
        createdAt: 0,
        parentMessageId: parent.parentMessageId,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final parent = ref
        .watch(threadParentProvider(widget.channelId))
        .valueOrNull;
    final parentName = parent?.parentChannelName;
    final title = parentName == null || parentName.isEmpty
        ? 'Thread'
        : 'Thread in #$parentName';
    // Docked beside the chat: its own raised surface, so the pane is not lost against the transcript it sits next to.
    final docked = widget.onClose != null;
    final surface = docked ? tokens.surfaceRaised : null;
    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        backgroundColor: surface,
        // Docked: a close, since the parent sits beside it, not behind. Routed: the automatic back button is a Material glyph; BackToButton's is the Lucide one every other screen uses.
        leading: widget.onClose != null
            ? IconButton(
                icon: const Icon(AppIcons.dismiss),
                tooltip: 'Close thread',
                onPressed: widget.onClose,
              )
            : const BackToButton(
                tooltip: 'Back to the conversation',
                fallback: Routes.channels,
              ),
        // container: true gives the title its own semantics node; see the doc comment above.
        title: Semantics(header: true, container: true, child: Text(title)),
        shape: Border(bottom: BorderSide(color: tokens.borderSubtle)),
        actions: [
          ChannelSearchAction(channelId: widget.channelId),
          const SizedBox(width: AppSpacing.s8),
        ],
      ),
      body: ChannelScreen(
        channelId: widget.channelId,
        isThread: true,
        autofocusComposer: docked,
      ),
    );
  }
}
