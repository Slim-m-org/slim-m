// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Paging a channel's history backwards, and knowing whether the top of it
/// has actually been reached.
///
/// Two things depended on this and neither had it. The transcript rendered
/// `ChannelStartHeader` from the channel's name alone, so a channel with more
/// history than the loaded window announced the start of the conversation
/// while sitting directly above messages nobody had fetched. And scrolling to
/// the top loaded nothing at all: `/sync` and the channel screen's own
/// hydration both stop at 50, and `MessageStore.watchChannel` shows the newest
/// 200 rows, so everything older than that was unreachable in the client.
///
/// [ChannelHistory.atStart] is the answer to both, and it is only ever set by
/// the server running out of older messages - never inferred from a row's
/// `seq`, which soft deletes make gappy, and never from the window being
/// unfilled, which says nothing about what was never asked for.
///
/// [window] is also the whole reason the scrollbar the transcript's
/// `ListView` draws never represents the channel's full history: its extent
/// is the loaded window's, which grows in pages rather than being known up
/// front. Faking a total by estimating unfetched history would answer with a
/// number that changes on every page and cannot be trusted; loading
/// everything up front to make the number real is exactly what paging exists
/// to avoid. The honest reading is a position-within-what-is-loaded
/// indicator, the same trade-off other paginated chat clients make, not a
/// proportion-of-everything gauge - see `message_transcript.dart`'s own note
/// on `_topSlot` for the one place that answer used to lie by omission
/// instead, which is now fixed.
///
/// Do not read that as covering a thumb that jitters, which is a different
/// thing and was a real bug rather than this trade-off showing through. The
/// extent stepping up by a page is one discrete move at the top of the list;
/// the thumb sliding backwards several times a second while somebody scrolls
/// steadily was `ListView`'s own extent estimate re-averaging the handful of
/// rows on screen every frame, and is fixed in
/// `widgets/message_transcript_extent.dart`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// `listMessages` is an extension method, so this import is load-bearing.
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../../../providers/message_extras.dart';
import '../../../providers/message_page_size.dart';
import '../../../providers/providers.dart';
import '../../../providers/rate_limit_retry.dart';
import '../../../providers/retention_policy.dart';

/// The transcript's opening window, matching [MessageStore.watchChannel]'s
/// own default so a channel that has never been paged reads exactly as it
/// did before this existed.
const _initialWindow = 200;

/// How much of a channel's history is loaded, and whether that is all of it.
class ChannelHistory {
  const ChannelHistory({
    this.atStart = false,
    this.loading = false,
    this.failed = false,
    this.window = _initialWindow,
  });

  /// True once the server has answered with fewer older messages than a full
  /// page, which is the only evidence that the oldest loaded row is genuinely
  /// the channel's first.
  final bool atStart;

  final bool loading;

  /// A failed page stops the automatic trigger from retrying: the top of the
  /// list stays in view while it is showing, so an auto-retry would become an
  /// unbounded request loop against whatever just refused.
  final bool failed;

  /// How many rows the local store is asked to hand the transcript, grown by
  /// each page so prepended history is actually visible.
  ///
  /// Capped at [channelWindowCeiling] (see `retention_policy.dart`): past
  /// that, [ChannelHistoryController.loadOlder] stops growing this rather
  /// than feeding drift's watch an ever-larger `LIMIT` for the rest of the
  /// session.
  final int window;

  ChannelHistory copyWith({
    bool? atStart,
    bool? loading,
    bool? failed,
    int? window,
  }) => ChannelHistory(
    atStart: atStart ?? this.atStart,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
    window: window ?? this.window,
  );
}

class ChannelHistoryController extends StateNotifier<ChannelHistory> {
  ChannelHistoryController(this._ref, this._channelId)
    : super(const ChannelHistory());

  final Ref _ref;
  final String _channelId;

  /// The seq to page backwards from next, tracked here rather than trusted
  /// fresh from the caller on every call.
  ///
  /// [loadOlder] updates this itself the instant a page lands, in the same
  /// breath as the `state` write below - so a scroll landing between that
  /// page's store write and the transcript's own rebuild (a separate,
  /// independently-timed stream) reads the cursor the fetch just left behind,
  /// not the value that was current before it. [syncOldest] only ever moves
  /// this further into the past, which is what makes that safe: a rebuild
  /// still running on pre-fetch data can only report a newer boundary than
  /// what [loadOlder] already confirmed, never an older one, so it can never
  /// undo that fetch's own progress.
  int? _oldest;

  /// Tells the controller what the transcript currently shows as its oldest
  /// delivered row. Safe to call from a build method: unlike everything else
  /// here, it never touches [state], so it cannot trip the "modified a
  /// provider while the widget tree was building" guard.
  void syncOldest(int? oldest) {
    if (oldest == null) return;
    if (_oldest == null || oldest < _oldest!) _oldest = oldest;
  }

  /// Fetches the page of messages immediately older than the tracked cursor
  /// and prepends it to the local store.
  ///
  /// Safe to call on every scroll frame: it is a no-op once the start has
  /// been reached, while a page is in flight, after a failure, and once
  /// [ChannelHistory.window] has reached [channelWindowCeiling] - the local
  /// store may hold far more than that already, but nothing past the ceiling
  /// joins this session's live-watched window. A null or zero cursor means
  /// nothing delivered is loaded yet, so there is no keyset to page from.
  ///
  /// A page the server refuses for rate limiting is retried quietly, after
  /// the wait it names, while [ChannelHistory.loading] stays set; only a
  /// refusal that outlasts the retry budget becomes [ChannelHistory.failed].
  ///
  /// The page size is the user's [messagePageSizeControllerProvider] choice,
  /// read once here so the number asked for and the number that decides
  /// [ChannelHistory.atStart] are the same: a page shorter than requested is
  /// the only evidence the channel's start has been reached.
  Future<void> loadOlder() async {
    if (state.atStart || state.loading || state.failed) return;
    if (state.window >= channelWindowCeiling) return;
    final oldest = _oldest;
    if (oldest == null || oldest <= 0) return;
    final pageSize = _ref.read(messagePageSizeControllerProvider).rows;
    state = state.copyWith(loading: true);
    try {
      final older = await retryWhenRateLimited(
        () => _ref
            .read(apiProvider)
            .listMessages(_channelId, before: oldest, limit: pageSize),
        wait: _ref.read(rateLimitWaitProvider),
      );
      final store = await _ref.read(storeProvider.future);
      await store.applyMessages(older);
      if (!mounted) return;
      _ref.read(messageExtrasProvider.notifier).applyMessages(older);
      // Newest first is the server's own contract, so the last entry is oldest.
      if (older.isNotEmpty) _oldest = older.last.seq;
      state = state.copyWith(
        loading: false,
        atStart: older.length < pageSize,
        window: cappedChannelWindow(state.window + older.length),
      );
    } catch (_) {
      // Not only ApiException: the store write above can fail too, and either must not wedge loading.
      if (!mounted) return;
      state = state.copyWith(loading: false, failed: true);
    }
  }

  /// Clears a failed page and asks again, from the retry the top of the list
  /// offers.
  Future<void> retry() async {
    if (!state.failed) return;
    state = state.copyWith(failed: false);
    await loadOlder();
  }
}

/// Per channel and deliberately not `autoDispose`: what has been paged in is
/// a property of the channel as seen by this account through this local
/// store, not of the screen currently showing it, so switching channels must
/// not re-announce a start already proved to have more above it.
///
/// That scoping is exactly why it must not survive a sign-out: the local
/// store is one file for the whole app, so whoever signs in next on this
/// device would otherwise inherit a stranger's paging state along with it.
/// `SyncController._endSession` invalidates every instance of this family in
/// the same breath it clears the database, so a fresh account starts with
/// nothing paged in either.
final channelHistoryProvider =
    StateNotifierProvider.family<
      ChannelHistoryController,
      ChannelHistory,
      String
    >((ref, channelId) => ChannelHistoryController(ref, channelId));

/// The smallest `seq` among the delivered rows in [rows], or null when none
/// are delivered.
///
/// Pending sends carry `seq` 0 until the server acknowledges them, and zero
/// is the lowest value there is, so a naive minimum would page from the
/// beginning of every channel the moment somebody had an unsent message.
int? oldestDeliveredSeq(List<Message> rows) {
  int? oldest;
  for (final row in rows) {
    if (row.seq <= 0) continue;
    if (oldest == null || row.seq < oldest) oldest = row.seq;
  }
  return oldest;
}
