// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SyncController]'s catch-up half: pulling every known scope up to the
/// server's head over REST.
///
/// Split out of `sync_controller.dart`, which sat at the 500-line ceiling.
part of 'sync_controller.dart';

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

extension SyncControllerCatchUp on SyncController {
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
  Future<void> _catchUp(
    int generation,
    SlimmApi api,
    MessageStore store, {
    void Function()? onFirstRound,
  }) async {
    var first = true;
    Set<String>? only;
    while (true) {
      final behind = await _catchUpRound(generation, api, store, only: only);
      if (generation != _generation) return;
      if (first) onFirstRound?.call();
      first = false;
      if (behind.isEmpty) return;
      only = behind;
      // Next tick rather than straight through, so a long backlog does not block the first paint.
      await Future<void>.delayed(Duration.zero);
      if (generation != _generation) return;
    }
  }

  /// One pass over the known scopes (or just [only]) in [syncScopeChunk]-sized
  /// requests, each applied before the next so a later failure keeps the
  /// progress. Answers the scopes that still have more to fetch.
  Future<Set<String>> _catchUpRound(
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
        if (generation != _generation) return const {};
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
          'sync chunk failed, retrying',
          error: error,
          stack: stack,
          context: {'attempt': attempt + 1},
        );
        await Future<void>.delayed(delays[attempt]);
        if (generation != _generation) return const [];
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
    bool isCurrent() => generation == _generation;
    if (delta.reset) {
      // Either cursor is too far behind to stream: local state is untrusted.
      await _resetScope(generation, api, store, delta.channelId);
      return isCurrent() ? false : null;
    }
    await store.applyMessages(delta.messages);

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
    bool isCurrent() => generation == _generation;
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

  /// Runs a catch-up against the current generation.
  ///
  /// The gap detector's entry point: a live frame that is not exactly the next
  /// one schedules this rather than applying a payload it cannot place.
  /// Single-flight: a call while one is running is not a second `/sync` but a
  /// request for one more pass once it ends, so a burst of gaps costs one or
  /// two requests however long it is. A pass that fails drops the connection,
  /// since the local store is then known to be behind and only a fresh
  /// connect repairs it.
  Future<void> reconcile() async {
    if (_disposed) return;
    if (_reconciling) {
      _reconcileAgain = true;
      return;
    }
    _reconciling = true;
    try {
      do {
        _reconcileAgain = false;
        final generation = _generation;
        final api = _ref.read(apiProvider);
        final store = await _ref.read(storeProvider.future);
        if (generation != _generation) return;
        try {
          await _catchUp(generation, api, store);
        } catch (error, stack) {
          reportFailure(LogTag.sync, 'catch up with the server', error, stack);
          if (generation == _generation) _onDropped();
          return;
        }
      } while (_reconcileAgain && !_disposed);
    } finally {
      _reconciling = false;
    }
  }
}

/// What applying a scope's edit ops leaves the catch-up to do.
enum _OpsStep { proceed, stale, reset }
