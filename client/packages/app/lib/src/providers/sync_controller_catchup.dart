// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SyncController]'s catch-up half: pulling every known scope up to the
/// server's head over REST.
///
/// Split out of `sync_controller.dart`, which sat at the 500-line ceiling.
part of 'sync_controller.dart';

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
    while (true) {
      final more = await _catchUpRound(generation, api, store);
      if (generation != _generation) return;
      if (first) onFirstRound?.call();
      first = false;
      if (!more) return;
      // Next tick rather than straight through, so a long backlog does not block the first paint.
      await Future<void>.delayed(Duration.zero);
      if (generation != _generation) return;
    }
  }

  /// One `/sync` request over every scope, applying its deltas in order.
  /// Answers whether any scope still has more to fetch.
  Future<bool> _catchUpRound(
    int generation,
    SlimmApi api,
    MessageStore store,
  ) async {
    bool isCurrent() => generation == _generation;
    final cursors = await store.allCursors();
    if (cursors.isEmpty) return false;

    final deltas = await api.sync(cursors);
    var more = false;
    for (final delta in deltas) {
      if (!isCurrent()) return false;
      if (delta.reset) {
        // Either cursor is too far behind to stream: local state is untrusted.
        await _resetScope(generation, api, store, delta.channelId);
        if (!isCurrent()) return false;
        continue;
      }
      await store.applyMessages(delta.messages);

      // After the messages: an edit cannot precede the message it names.
      if (delta.opLatestSeq != null) {
        final cursor = await store.opCursorFor(delta.channelId);
        if (!isCurrent()) return false;
        if (cursor == null) {
          // Adopt the head; asking from zero replays every edit ever made.
          await store.setOpCursor(delta.channelId, delta.opLatestSeq);
        } else if (delta.ops.isNotEmpty) {
          final outcome = await applyOps(store, delta.channelId, delta.ops);
          if (!isCurrent()) return false;
          if (outcome == OpsOutcome.needsReset) {
            await _resetScope(generation, api, store, delta.channelId);
            continue;
          }
        }
      }

      more = more || delta.hasMore || delta.opsHasMore;
    }
    return more;
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
        } catch (_) {
          if (generation == _generation) _onDropped();
          return;
        }
      } while (_reconcileAgain && !_disposed);
    } finally {
      _reconciling = false;
    }
  }
}
