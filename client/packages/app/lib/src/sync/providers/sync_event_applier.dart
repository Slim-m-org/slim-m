// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How one frame off the socket becomes local state.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';

import '../../features/channels/providers/channel_notification_overrides_controller.dart';
import '../../features/channels/providers/channel_refresher.dart';
import '../../features/channels/providers/last_text_channel.dart';
import '../../providers/op_adjacency.dart';

class SyncEventApplier {
  SyncEventApplier(
    this._ref,
    this._isCurrent,
    this._channelRefresher,
    this._reconcile,
    this._resyncAfterLag,
  );

  final Ref _ref;
  final bool Function(int generation) _isCurrent;
  final ChannelRefresher _channelRefresher;

  /// A gap was seen: run one more catch-up pass.
  final Future<void> Function() _reconcile;

  /// The server cut this connection for lagging.
  final Future<void> Function() _resyncAfterLag;

  /// Channels a refresh on this connection did not bring into the store, such
  /// as threads, which the channel list never names.
  final unlistedChannels = <String>{};

  /// How one frame from the socket changes local state. A method of its own
  /// so [applyServerEventForTest] can drive it without a real socket.
  Future<void> apply(
    int generation,
    SlimmApi api,
    MessageStore store,
    ServerEvent event,
  ) async {
    bool isCurrent() => _isCurrent(generation);
    switch (event) {
      case MessageCreated():
        await _onMessageCreated(event, api, store, isCurrent);
      case MessageEdited(:final message, :final opSeq):
        await _materialise(message.channelId, api, store, isCurrent);
        if (!isCurrent()) return;
        if (!await _placeLiveOp(message.channelId, opSeq, store, isCurrent)) {
          return;
        }
        await store.applyMessage(message);
      case MessageLinkPreviewsRemoved(
        :final channelId,
        :final messageId,
        :final opSeq,
      ):
        if (!await _placeLiveOp(channelId, opSeq, store, isCurrent)) return;
        if (!isCurrent()) return;
        await store.markLinkPreviewsRemoved(messageId);
      case MessageDeleted(:final channelId, :final messageId, :final opSeq):
        if (!await _placeLiveOp(channelId, opSeq, store, isCurrent)) return;
        if (!isCurrent()) return;
        // Without this case a delete by another user stayed visible until the next full resync.
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
        await _onChannelDeleted(channelId, store);
      case OverwriteChanged():
      case DmChanged():
      case RoleChanged():
      case MemberRoleChanged():
      case CategoryChanged():
        // None say which channel (or category) changed, or who joined a group; a refresh finds it.
        await _channelRefresher.refreshAfterChange(
          api,
          store,
          isCurrent: isCurrent,
        );
      case ErrorEvent(:final needsResync) when needsResync:
        // The server closed a connection that fell behind; a restart re-runs catch-up.
        unawaited(_resyncAfterLag());
      case _:
        break;
    }
  }

  Future<void> _onMessageCreated(
    MessageCreated event,
    SlimmApi api,
    MessageStore store,
    bool Function() isCurrent,
  ) async {
    final message = event.message;
    await _materialise(message.channelId, api, store, isCurrent);
    if (!isCurrent()) return;
    if (await _skipsOver(message.channelId, message.seq, store, isCurrent)) {
      return;
    }
    await store.applyMessage(message);
  }

  Future<void> _onChannelDeleted(String channelId, MessageStore store) async {
    final row = await store.channelRow(channelId);
    if (row?.roomOwnerId != null) {
      final removed = _ref.read(removedRoomsProvider.notifier);
      removed.state = {...removed.state, channelId};
    } else if (row != null) {
      final deleted = _ref.read(deletedChannelsProvider.notifier);
      deleted.state = {...deleted.state, channelId: row.name};
    }
    // A channel already known to be gone; no round trip needed for that.
    await store.removeChannel(channelId);
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
    if (unlistedChannels.contains(channelId)) return;
    if (await store.hasChannel(channelId)) return;
    try {
      await _channelRefresher.refreshOnce(api, store, isCurrent: isCurrent);
    } on ApiException catch (error, stack) {
      AppLog.swallowed(
        LogTag.sync,
        'Could not refresh channels after a server event; skipping it',
        error,
        stack,
      );
      return;
    }
    if (isCurrent() && !await store.hasChannel(channelId)) {
      unlistedChannels.add(channelId);
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
    unawaited(
      _reconcile().catchError(
        ignoreError(LogTag.sync, 're-check state after the connection dropped'),
      ),
    );
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
        unawaited(
          _reconcile().catchError(
            ignoreError(
              LogTag.sync,
              're-check state after the connection dropped',
            ),
          ),
        );
        return false;
      case LiveOpOutcome.applied:
        if (opSeq != null) await store.setOpCursor(channelId, opSeq);
        return true;
    }
  }
}
