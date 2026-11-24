// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Catch-up: pulling every known scope up to the server's head over REST.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart' hide Message;

import '../../features/channels/providers/channel_history.dart';
import '../../features/messages/providers/message_extras.dart';
import '../../features/messages/providers/message_ops_sync.dart';
import '../../features/messages/providers/retention_policy.dart';
import '../../providers/rate_limit_retry.dart';

/// Cursors per `/sync` request, under the server's 200-scope ceiling.
const syncScopeChunk = 150;

/// Waits between retries of one failed chunk; its length is the retry count.
final syncChunkRetryDelaysProvider = Provider<List<Duration>>(
  (ref) => const [Duration(milliseconds: 500), Duration(seconds: 2)],
);

/// Rows per page when catch-up rereads a channel's messages; a test shrinks it.
final syncNewestPageProvider = Provider<int>((ref) => 50);

bool _isTransientSyncFailure(Object error) => switch (error) {
  TransportException() || UnavailableException() => true,
  RateLimitedException() => true,
  ServerException(:final statusCode) => statusCode >= 500,
  _ => false,
};

/// Runs catch-up rounds for the sync controller, which says whether a run is still the current one.
class SyncCatchUp {
  SyncCatchUp(this._ref, this._isCurrent);

  final Ref _ref;
  final bool Function(int generation) _isCurrent;

  final _held = <String, Message>{};
  final _batches = StreamController<List<Message>>.broadcast();

  /// Messages a reconnect's catch-up stored, which no live frame announced.
  Stream<List<Message>> get reconnectBatches => _batches.stream;

  /// Starts collecting the messages the coming catch-up stores.
  void beginBatch() => _held.clear();

  /// Hands the collected messages to [reconnectBatches] after a reconnect, or drops them on a first connect.
  void endBatch({required bool reconnect}) {
    if (reconnect && _held.isNotEmpty) _batches.add(_held.values.toList());
    _held.clear();
  }

  void dispose() => unawaited(_batches.close());

  /// Catches every known scope up, round after round until none is behind.
  ///
  /// The rounds are awaited here rather than left to a detached continuation,
  /// so a failed round throws to whoever is waiting: [start] retries with
  /// backoff, [reconcile] drops the connection. A detached one had nobody to
  /// throw to once `start()` had moved on, and the controller went live with
  /// the rest of the backlog unfetched.
  ///
  /// [generation] is this call's [start], checked before every write: a
  /// sign-out landing while a network round trip is already in flight must
  /// not let its answer, arriving after the store has been cleared for the
  /// account signing out, write into it anyway.
  ///
  /// [onFirstRound] runs once the first round has landed, before the rest of
  /// a long backlog, so the first paint does not wait for all of it.
  Future<void> run(
    int generation,
    SlimmApi api,
    MessageStore store, {
    void Function()? onFirstRound,
    bool Function()? shouldStop,
  }) async {
    var first = true;
    Set<String>? only;
    while (true) {
      final behind = await _round(generation, api, store, only: only);
      if (!_isCurrent(generation)) return;
      if (first) onFirstRound?.call();
      first = false;
      if (behind.isEmpty || (shouldStop?.call() ?? false)) return;
      only = behind;
      // Next tick rather than straight through, so a long backlog does not block the first paint.
      await Future<void>.delayed(Duration.zero);
      if (!_isCurrent(generation)) return;
    }
  }

  /// One pass over the known scopes (or just [only]) in [syncScopeChunk]-sized
  /// requests, each applied before the next so a later failure keeps the
  /// progress. Answers the scopes that still have more to fetch.
  Future<Set<String>> _round(
    int generation,
    SlimmApi api,
    MessageStore store, {
    Set<String>? only,
  }) async {
    final all = await store.allCursors();
    final cursors = only == null
        ? all
        : all.where((c) => only.contains(c.channelId)).toList();
    final behind = <String>{};
    for (var at = 0; at < cursors.length; at += syncScopeChunk) {
      final chunk = cursors.sublist(
        at,
        min(at + syncScopeChunk, cursors.length),
      );
      final deltas = await _syncChunk(generation, api, chunk);
      for (final delta in deltas) {
        if (!_isCurrent(generation)) return const {};
        final deltaMore = await _applyDelta(generation, api, store, delta);
        if (deltaMore == null) return const {};
        if (deltaMore) behind.add(delta.channelId);
      }
    }
    return behind;
  }

  /// One chunk's `/sync`, retried on a transient failure after the delays in
  /// [syncChunkRetryDelaysProvider]; anything else, or the last failure, throws.
  Future<List<ScopeDelta>> _syncChunk(
    int generation,
    SlimmApi api,
    List<ScopeCursor> chunk,
  ) async {
    final delays = _ref.read(syncChunkRetryDelaysProvider);
    for (var attempt = 0; ; attempt++) {
      try {
        return await api.sync(chunk);
      } catch (error, stack) {
        if (attempt >= delays.length || !_isTransientSyncFailure(error)) {
          rethrow;
        }
        AppLog.debug(
          LogTag.sync,
          'A sync request failed; retrying',
          error: error,
          stack: stack,
          context: {'attempt': attempt + 1},
        );
        await Future<void>.delayed(delays[attempt]);
        if (!_isCurrent(generation)) return const [];
      }
    }
  }

  /// Applies one scope's delta. Answers whether it has more to fetch, or null
  /// when the generation moved on underneath it.
  Future<bool?> _applyDelta(
    int generation,
    SlimmApi api,
    MessageStore store,
    ScopeDelta delta,
  ) async {
    bool isCurrent() => _isCurrent(generation);
    if (delta.reset) {
      // Either cursor is too far behind to stream: local state is untrusted.
      await _resetScope(generation, api, store, delta);
      return isCurrent() ? false : null;
    }
    if (await _adoptsOverHeldRows(store, delta)) {
      await _refetchHeld(generation, api, store, delta);
      return isCurrent() ? false : null;
    }
    await store.applyMessages(delta.messages, advance: CursorAdvance.always);
    if (!isCurrent()) return null;
    for (final message in delta.messages) {
      _held[message.id] = message;
    }
    _ref.read(messageExtrasProvider.notifier).applyMessages(delta.messages);

    // After the messages: an edit cannot precede the message it names.
    if (delta.opLatestSeq != null) {
      switch (await _applyDeltaOps(generation, api, store, delta)) {
        case _OpsStep.stale:
          return null;
        case _OpsStep.reset:
          return false;
        case _OpsStep.proceed:
          break;
      }
    }
    // Only a cursor that asked gets a marker here: it names no held message that still mentions us.
    if (delta.mentionedSeq case final seq?) {
      await store.healMentionCursor(delta.channelId, seq);
    }
    // A deleted tail leaves the page short of the head, which a late frame for one of them would slip past.
    if (delta.latestSeq case final head? when !delta.hasMore) {
      await store.coverCursor(delta.channelId, head);
    }
    return delta.hasMore || delta.opsHasMore;
  }

  /// Whether adopting the op head would skip ops on rows already held.
  ///
  /// A channel with no op cursor adopts the head, which is only safe while it
  /// holds nothing: rows that arrived first, live or from a page, may be named
  /// by ops before that head which no cursor will ever ask for.
  Future<bool> _adoptsOverHeldRows(MessageStore store, ScopeDelta delta) async {
    final head = delta.opLatestSeq;
    if (head == null || head == 0) return false;
    if (await store.opCursorFor(delta.channelId) != null) return false;
    return await store.oldestLocalSeq(delta.channelId) != null;
  }

  /// Rereads the span of rows held before the op cursor existed, and starts
  /// the op cursor at the head [delta] read before those pages.
  ///
  /// Unlike [_resetScope] the rows are swapped in one write, so an open channel
  /// is never shown empty, and the cursor moves only once the pages are stored:
  /// a fetch that fails leaves the scope to be refetched by the next catch-up.
  Future<void> _refetchHeld(
    int generation,
    SlimmApi api,
    MessageStore store,
    ScopeDelta delta,
  ) async {
    final head = delta.latestSeq;
    // Without the head there is no telling a deleted row from one that arrived since.
    if (head == null) return _resetScope(generation, api, store, delta);
    final channelId = delta.channelId;
    final span = await _pagesOverHeld(generation, api, store, channelId);
    if (span == null) return;
    final fresh = span.rows;
    final through = fresh.fold(head, (seq, m) => max(seq, m.seq));
    await store.replaceHeld(
      channelId,
      fresh,
      from: span.from,
      through: through,
    );
    await store.setOpCursor(channelId, delta.opLatestSeq);
    _ref.read(messageExtrasProvider.notifier).applyMessages(fresh);
    await store.coverCursor(channelId, head);
  }

  /// The newest page and each older one down to the oldest row held, with the
  /// seq they cover from: 0 once a short page proved the channel's start.
  /// Null when the generation moved on.
  ///
  /// Every held row is reread, not just the newest page: history the user
  /// paged in stays, and an op on it from before the head is still caught. It
  /// stops at [channelWindowCeiling] rows, below which no window shows a row.
  Future<({List<Message> rows, int from})?> _pagesOverHeld(
    int generation,
    SlimmApi api,
    MessageStore store,
    String channelId,
  ) async {
    final limit = _ref.read(syncNewestPageProvider);
    final oldestHeld = await store.oldestLocalSeq(channelId) ?? 0;
    final maxPages = (channelWindowCeiling / limit).ceil() + 1;
    final rows = <Message>[];
    int? before;
    for (var fetched = 0; fetched < maxPages; fetched++) {
      final page = await retryWhenRateLimited(
        () => api.listMessagePage(channelId, before: before, limit: limit),
        wait: _ref.read(rateLimitWaitProvider),
      );
      if (!_isCurrent(generation)) return null;
      rows.addAll(page.messages);
      if (page.isShort(limit)) return (rows: rows, from: 0);
      before = page.minRawSeq;
      if (before == null || before <= oldestHeld) break;
    }
    return (rows: rows, from: before ?? 0);
  }

  /// Applies a scope's edit ops after its messages, adopting the head on a first sync.
  Future<_OpsStep> _applyDeltaOps(
    int generation,
    SlimmApi api,
    MessageStore store,
    ScopeDelta delta,
  ) async {
    bool isCurrent() => _isCurrent(generation);
    final cursor = await store.opCursorFor(delta.channelId);
    if (!isCurrent()) return _OpsStep.stale;
    if (cursor == null) {
      // Adopt the head; asking from zero replays every edit ever made.
      await store.setOpCursor(delta.channelId, delta.opLatestSeq);
      return _OpsStep.proceed;
    }
    if (delta.ops.isEmpty) return _OpsStep.proceed;
    final outcome = await applyOps(store, delta.channelId, delta.ops);
    if (!isCurrent()) return _OpsStep.stale;
    if (outcome != OpsOutcome.needsReset) return _OpsStep.proceed;
    await _resetScope(generation, api, store, delta);
    return _OpsStep.reset;
  }

  /// Drops a scope's cached messages and both its cursors, then refetches the
  /// newest page and restores the mention cursor from [delta]'s marker, or
  /// keeps its own when a reset this client started carries none.
  ///
  /// The op cursor restarts at the head [delta] reported, which was read
  /// before the page is: an op landing after the page was read is then still
  /// ahead of the cursor. Left null, the next catch-up adopted whatever the
  /// head had become, and an edit or delete in between was never applied.
  Future<void> _resetScope(
    int generation,
    SlimmApi api,
    MessageStore store,
    ScopeDelta delta,
  ) async {
    final channelId = delta.channelId;
    final mentioned =
        delta.mentionedSeq ??
        (await store.channelRow(channelId))?.mentionedSeq ??
        0;
    await store.resetChannel(channelId);
    // Paging would otherwise go on from below rows that are no longer held.
    _ref.read(messageExtrasProvider.notifier).forgetPages(channelId);
    _ref.invalidate(channelHistoryProvider(channelId));
    await store.setOpCursor(channelId, delta.opLatestSeq);
    final limit = _ref.read(syncNewestPageProvider);
    final fresh = await retryWhenRateLimited(
      () => api.listMessages(channelId, limit: limit),
      wait: _ref.read(rateLimitWaitProvider),
    );
    if (!_isCurrent(generation)) return;
    await store.applyMessages(fresh, advance: CursorAdvance.always);
    _ref.read(messageExtrasProvider.notifier).applyMessages(fresh);
    if (delta.latestSeq case final head?) {
      await store.coverCursor(channelId, head);
    }
    // The page holds only the newest messages; an older mention survives by the marker or the kept cursor.
    if (mentioned > 0) await store.advanceMentionCursor(channelId, mentioned);
  }
}

/// What applying a scope's edit ops leaves the catch-up to do.
enum _OpsStep { proceed, stale, reset }
