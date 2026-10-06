// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SyncController]'s catch-up half: pulling every known scope up to the
/// server's head over REST.
///
/// Split out of `sync_controller.dart`, which sat at the 500-line ceiling.
part of 'sync_controller.dart';

extension SyncControllerCatchUp on SyncController {
  /// Catches every known scope up in one request, applying deltas in order.
  ///
  /// [generation] is this call's [start], checked before every write: a
  /// sign-out landing while the network round trip above is already in
  /// flight must not let its answer, arriving after the store has been
  /// cleared for the account signing out, write into it anyway.
  Future<void> _catchUp(
    int generation,
    SlimmApi api,
    MessageStore store,
  ) async {
    bool isCurrent() => generation == _generation;
    final cursors = await store.allCursors();
    if (cursors.isEmpty) return;

    final deltas = await api.sync(cursors);
    if (generation != _generation) return;
    var more = false;
    for (final delta in deltas) {
      if (generation != _generation) return;
      if (delta.reset) {
        // Either cursor is too far behind to stream: local state is untrusted.
        await _resetScope(generation, api, store, delta.channelId);
        if (!isCurrent()) return;
        continue;
      }
      await store.applyMessages(delta.messages);

      // After the messages: an edit cannot precede the message it names.
      if (delta.opLatestSeq != null) {
        final cursor = await store.opCursorFor(delta.channelId);
        if (!isCurrent()) return;
        if (cursor == null) {
          // Adopt the head; asking from zero replays every edit ever made.
          await store.setOpCursor(delta.channelId, delta.opLatestSeq);
        } else if (delta.ops.isNotEmpty) {
          final outcome = await applyOps(store, delta.channelId, delta.ops);
          if (!isCurrent()) return;
          if (outcome == OpsOutcome.needsReset) {
            await _resetScope(generation, api, store, delta.channelId);
            continue;
          }
        }
      }

      more = more || delta.hasMore || delta.opsHasMore;
    }

    /// At most one continuation per round, however many scopes are behind.
    /// Scheduling inside the loop meant every backlogged channel started its own
    /// full-cursor resync, so ten of them fanned out into ten overlapping /sync
    /// calls that each re-requested all ten scopes. Next tick rather than
    /// straight through, so a long backlog does not block the first paint.
    if (more) {
      // Runs outside start()'s try/catch, so a failed round takes the drop path a lost socket takes.
      unawaited(
        Future<void>.delayed(
          Duration.zero,
          () => _catchUp(generation, api, store),
        ).catchError((_) {
          if (!_disposed && generation == _generation) _onDropped();
        }),
      );
    }
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
