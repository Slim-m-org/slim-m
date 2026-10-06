// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SyncController]'s event-application half: how one frame off the
/// socket becomes local state.
///
/// Split out of `sync_controller.dart`, which had reached the 500-line
/// hard ceiling with no headroom left - any change to it, including a
/// two-line bug fix, broke the file budget. The seam is real rather than
/// arbitrary: everything here decides what a received event MEANS, while
/// what remains owns the connection and session lifecycle that delivers
/// one. A `part` rather than a separate class because these methods are
/// private to [SyncController] and reach its generation guard.
part of 'sync_controller.dart';

extension SyncControllerEvents on SyncController {
  /// How one frame from the socket changes local state. A method of its own
  /// so [applyServerEventForTest] can drive it without a real socket.
  Future<void> _applyServerEvent(
    int generation,
    SlimmApi api,
    MessageStore store,
    ServerEvent event,
  ) async {
    bool isCurrent() => generation == _generation;
    switch (event) {
      case MessageCreated(:final message):
        await _materialise(message.channelId, api, store, isCurrent);
        if (!isCurrent()) return;
        if (await _skipsOver(
          message.channelId,
          message.seq,
          store,
          isCurrent,
        )) {
          return;
        }
        await store.applyMessage(message);
      case MessageEdited(:final message, :final opSeq):
        await _materialise(message.channelId, api, store, isCurrent);
        if (!isCurrent()) return;
        if (!await _placeLiveOp(message.channelId, opSeq, store, isCurrent)) {
          return;
        }
        await store.applyMessage(message);
      case MessageDeleted(:final channelId, :final messageId, :final opSeq):

        /// Closes a real gap: this switch previously had no case for a
        /// delete at all, so a message removed by another user (or this
        /// account's own delete looping back) never left the local store
        /// and stayed visible until the next full resync.
        if (!await _placeLiveOp(channelId, opSeq, store, isCurrent)) return;
        if (!isCurrent()) return;
        await store.discard(messageId);
      case ReadStateChanged(
        :final channelId,
        :final lastReadSeq,
        :final manuallyUnread,
      ):
        await store.setReadMarker(
          channelId,
          lastReadSeq,
          manuallyUnread: manuallyUnread,
        );
      case NotificationOverrideChanged(:final channelId, :final preference):
        // A controller not built yet fetches the current list when it is.
        if (_ref.exists(channelNotificationOverridesProvider)) {
          _ref
              .read(channelNotificationOverridesProvider.notifier)
              .applyRemote(channelId, preference);
        }
      case ChannelCreated(:final channel):
      case ChannelUpdated(:final channel):
        await store.upsertChannels([channel]);
      case ChannelDeleted(:final channelId):
        // A channel already known to be gone; no round trip needed for that.
        await store.removeChannel(channelId);
      case OverwriteChanged():
      case RoleChanged():
      case MemberRoleChanged():
      case CategoryChanged():
        // None say which channel (or category) changed; a refresh finds it.
        await _channelRefresher.refreshOnce(api, store, isCurrent: isCurrent);
      case ErrorEvent(:final needsResync) when needsResync:
        // The server closed a connection that fell behind; a restart re-runs catch-up.
        unawaited(start());
      case _:
        break;
    }
  }

  /// Refreshes the channel list for a message in a channel not held yet, which
  /// is how a DM's first message lands instead of no-opping.
  ///
  /// Once per channel per connection: a thread is never listed, and a refresh
  /// per reply rate-limited the account. A refused refresh is skipped rather
  /// than dropping the socket over a message that could not be placed anyway.
  Future<void> _materialise(
    String channelId,
    SlimmApi api,
    MessageStore store,
    bool Function() isCurrent,
  ) async {
    if (_unlistedChannels.contains(channelId)) return;
    if (await store.hasChannel(channelId)) return;
    try {
      await _channelRefresher.refreshOnce(api, store, isCurrent: isCurrent);
    } on ApiException {
      return;
    }
    if (isCurrent() && !await store.hasChannel(channelId)) {
      _unlistedChannels.add(channelId);
    }
  }

  /// Whether a message numbered [seq] sits more than one past its channel's cursor, so a
  /// message in between was never seen. Messages are dense per channel, so
  /// that is a real gap, not a guess.
  ///
  /// Applying it would move the cursor past what was lost for good, so it is
  /// left to the reconcile it schedules, whose page carries the same message
  /// in order. Answers true when the caller must not apply it, which includes
  /// a run superseded while the cursor was being read.
  Future<bool> _skipsOver(
    String channelId,
    int seq,
    MessageStore store,
    bool Function() isCurrent,
  ) async {
    final cursor = await store.cursorFor(channelId);
    if (!isCurrent()) return true;
    if (cursor == null || seq <= cursor + 1) return false;
    unawaited(reconcile().catchError((_) {}));
    return true;
  }

  /// Decides whether a live op may be applied, and advances the cursor when
  /// it may. Answers false when the caller must not apply the payload.
  ///
  /// A gap schedules one reconcile rather than applying an op it cannot place:
  /// moving the cursor past something never seen would strand it permanently,
  /// where a stall only lasts until the next round.
  ///
  /// [isCurrent] is rechecked after the cursor read, not only before the call.
  /// Reading the cursor is an await, and a sign-out or reconnect landing inside
  /// it leaves this holding a number from a store the newer run has since moved
  /// past - writing it back would advance a cursor over ops that run never saw,
  /// which is the permanent stranding the paragraph above exists to avoid. It
  /// is the guard every other checkpoint in [SyncController.start] already
  /// applies; this one path was reading the cursor without it.
  Future<bool> _placeLiveOp(
    String channelId,
    int? opSeq,
    MessageStore store,
    bool Function() isCurrent,
  ) async {
    final cursor = await store.opCursorFor(channelId);
    if (!isCurrent()) return false;
    switch (liveOpDecision(opSeq, cursor)) {
      case LiveOpOutcome.ignored:
        return false;
      case LiveOpOutcome.needsReconcile:
        unawaited(reconcile().catchError((_) {}));
        return false;
      case LiveOpOutcome.applied:
        if (opSeq != null) await store.setOpCursor(channelId, opSeq);
        return true;
    }
  }
}
