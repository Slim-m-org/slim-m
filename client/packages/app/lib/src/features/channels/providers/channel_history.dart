// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Paging a channel's history backwards, and knowing whether the top of it
/// has actually been reached.
///
/// [ChannelHistory.atStart] is set only by the server running out of older
/// messages, never inferred from a row's `seq` (soft deletes make it gappy) or
/// from an unfilled window.
///
/// [window] grows in pages, so the transcript's scrollbar shows a position
/// within what is loaded, never a proportion of the whole history. Thumb jitter
/// is a separate matter, handled in `widgets/message_transcript_extent.dart`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// `listMessages` is an extension method, so this import is load-bearing.
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../../messages/providers/hydrated_ranges.dart';
import '../../messages/providers/message_extras.dart';
import '../../messages/providers/message_page_size.dart';
import '../../../providers/providers.dart';
import '../../../providers/rate_limit_retry.dart';
import '../../messages/providers/retention_policy.dart';
import 'mounted_channels.dart';

/// The transcript's opening window, matching [MessageStore.watchChannel]'s
/// own default so a channel that has never been paged reads exactly as it
/// did before this existed.
const _initialWindow = 200;

/// The newest page [ChannelHistoryController.hydrate] refetches on every open.
const _recentPage = 50;

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
      final older = await _fetchPage(before: oldest, limit: pageSize);
      if (older == null) return;
      // Newest first is the server's own contract, so the last entry is oldest.
      if (older.isNotEmpty) _oldest = older.last.seq;
      state = state.copyWith(
        loading: false,
        atStart: older.length < pageSize,
        window: cappedChannelWindow(state.window + older.length),
      );
    } catch (error, stack) {
      api.reportFailure(api.LogTag.data, 'load older messages', error, stack);
      // Not only ApiException: the store write above can fail too, and either must not wedge loading.
      if (!mounted) return;
      state = state.copyWith(loading: false, failed: true);
    }
  }

  MessageExtrasController get _extras =>
      _ref.read(messageExtrasProvider.notifier);

  /// One page into the store and the extras. Null once the session has ended,
  /// so a page landing after sign-out reaches neither for the next account.
  Future<List<api.Message>?> _fetchPage({
    int? before,
    required int limit,
  }) async {
    final page = await retryWhenRateLimited(
      () => _ref
          .read(apiProvider)
          .listMessages(_channelId, before: before, limit: limit),
      wait: _ref.read(rateLimitWaitProvider),
    );
    if (!mounted) return null;
    final store = await _ref.read(storeProvider.future);
    await store.applyMessages(page);
    if (!mounted) return null;
    _extras.applyPage(_channelId, page, before: before, limit: limit);
    return page;
  }

  /// Queued so two callers wanting the same pages fetch them once.
  Future<void> _hydrating = Future.value();

  Future<T> _queued<T>(Future<T> Function() task) {
    final run = _hydrating.then((_) => task());
    _hydrating = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Run on opening a channel: refetches the newest page, then every older one
  /// the window shows, since the store holds no extras for them. Stops walking
  /// once the channel is closed.
  Future<void> hydrate() => _queued(() async {
    try {
      _restartIfForgotten();
      if (await _fetchPage(limit: _recentPage) == null) return;
      final store = await _ref.read(storeProvider.future);
      if (!mounted) return;
      final floor = await store.oldestSeqInWindow(_channelId, state.window);
      if (floor == null) return;
      await _hydrateDownTo(floor, () => _isClosed);
    } catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'load recent channel messages',
        error,
        stack,
      );
    }
  });

  bool get _isClosed =>
      !mounted || !_ref.read(mountedChannelsProvider).isOpen(_channelId);

  /// A channel whose extras were swept starts over from the initial window,
  /// since refilling a grown one would cost a request per page.
  void _restartIfForgotten() {
    final forgotten =
        _extras.highestUnhydrated(_channelId, 1) == HydratedRanges.newest;
    if (!forgotten || state.loading || state.window <= _initialWindow) return;
    _oldest = null;
    state = const ChannelHistory();
  }

  /// Fetches until every row from [floor] up came from the server this
  /// session; false when a page failed or [isCancelled] said to stop.
  Future<bool> hydrateTo(int floor, {bool Function()? isCancelled}) {
    if (!mounted) return Future.value(false);
    if (_extras.highestUnhydrated(_channelId, floor) == null) {
      return Future.value(true);
    }
    return _queued(() => _hydrateDownTo(floor, isCancelled));
  }

  Future<bool> _hydrateDownTo(int floor, bool Function()? isCancelled) async {
    final limit = _ref.read(messagePageSizeControllerProvider).rows;
    // The largest window is all a transcript ever shows, so no floor is worth more pages than fill it.
    final maxPages = (channelWindowCeiling / limit).ceil() + 1;
    try {
      for (var fetched = 0; fetched < maxPages; fetched++) {
        if (isCancelled?.call() ?? false) return false;
        final gap = _extras.highestUnhydrated(_channelId, floor);
        if (gap == null) return true;
        final before = gap == HydratedRanges.newest ? null : gap + 1;
        if (await _fetchPage(before: before, limit: limit) == null) {
          return false;
        }
      }
      return _extras.highestUnhydrated(_channelId, floor) == null;
    } catch (error, stack) {
      api.reportFailure(api.LogTag.data, 'load older messages', error, stack);
      return false;
    }
  }

  /// Grows [ChannelHistory.window] to hold at least [rows], for a row the
  /// store already has but the window does not reach. False when [rows] is
  /// past [channelWindowCeiling], which no window ever shows.
  bool widenWindowTo(int rows) {
    if (rows > channelWindowCeiling) return false;
    if (rows > state.window) state = state.copyWith(window: rows);
    return true;
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
