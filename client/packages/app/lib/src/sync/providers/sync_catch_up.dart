// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Catch-up: pulling every known scope up to the server's head over REST.
library;

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';

import '../../features/messages/providers/message_extras.dart';
import '../../features/messages/providers/message_ops_sync.dart';
import '../../providers/rate_limit_retry.dart';

/// Cursors per `/sync` request, under the server's 200-scope ceiling.
const syncScopeChunk = 150;

/// Waits between retries of one failed chunk; its length is the retry count.
final syncChunkRetryDelaysProvider = Provider<List<Duration>>(
  (ref) => const [Duration(milliseconds: 500), Duration(seconds: 2)],
);

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
      await _resetScope(generation, api, store, delta.channelId);
      return isCurrent() ? false : null;
    }
    await store.applyMessages(delta.messages);
    if (!isCurrent()) return null;
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
    return delta.hasMore || delta.opsHasMore;
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
    await _resetScope(generation, api, store, delta.channelId);
    return _OpsStep.reset;
  }

  /// Drops a scope's cached messages and both its cursors, then refetches the
  /// newest page.
  ///
  /// [MessageStore.resetChannel] clears the op cursor to null as well as
  /// rewinding the message one, so the next catch-up adopts a fresh head
  /// rather than asking from a seq the server may have swept past.
  Future<void> _resetScope(
    int generation,
    SlimmApi api,
    MessageStore store,
    String channelId,
  ) async {
    await store.resetChannel(channelId);
    final fresh = await retryWhenRateLimited(
      () => api.listMessages(channelId, limit: 50),
      wait: _ref.read(rateLimitWaitProvider),
    );
    if (!_isCurrent(generation)) return;
    await store.applyMessages(fresh);
    _ref.read(messageExtrasProvider.notifier).applyMessages(fresh);
  }
}

/// What applying a scope's edit ops leaves the catch-up to do.
enum _OpsStep { proceed, stale, reset }
