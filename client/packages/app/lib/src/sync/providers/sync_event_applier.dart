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
import '../../features/channels/providers/open_channel_rehydrate.dart';
import '../../features/settings/providers/theme_store.dart';
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
        await _applyLiveOp(
          (channelId: message.channelId, opSeq: opSeq),
          store,
          isCurrent,
          () => store.applyEdited(message),
        );
      case MessageLinkPreviewsRemoved(
        :final channelId,
        :final messageId,
        :final opSeq,
      ):
        await _applyLiveOp(
          (channelId: channelId, opSeq: opSeq),
          store,
          isCurrent,
          () => store.markLinkPreviewsRemoved(messageId),
        );
      case MessageDeleted(:final channelId, :final messageId, :final opSeq):
        // Without this case a delete by another user stayed visible until the next full resync.
        await _applyLiveOp(
          (channelId: channelId, opSeq: opSeq),
          store,
          isCurrent,
          () => store.discard(messageId),
        );
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
      case CategoryMuteChanged(:final categoryId, :final muted):
        if (_ref.exists(channelNotificationOverridesProvider)) {
          _ref
              .read(channelNotificationOverridesProvider.notifier)
              .applyRemoteCategory(categoryId, muted: muted);
        }
      case ChannelCreated(:final channel):
      case ChannelUpdated(:final channel):
        await store.upsertChannels([channel]);
        // A heading this device never held would leave the channel drawn nowhere, or under the wrong one.
        if (await _namesUnheldCategory(channel.categoryId, store)) {
          if (!isCurrent()) return;
          await _channelRefresher.refreshAfterChange(
            api,
            store,
            isCurrent: isCurrent,
          );
        }
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
      case SpaceSettingsChanged():
        unawaited(rehydrateIfTranscriptsTurnedOn(_ref));
        _refetchSpaceThemes();
      case SpaceThemesChanged():
        _refetchSpaceThemes();
      case ErrorEvent(:final needsResync) when needsResync:
        // The server closed a connection that fell behind; a restart re-runs catch-up.
        unawaited(_resyncAfterLag());
      case _:
        break;
    }
  }

  void _refetchSpaceThemes() {
    if (_ref.exists(spaceThemesProvider)) _ref.invalidate(spaceThemesProvider);
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
    final placed = (id: message.id, seq: message.seq);
    if (await _cannotPlace(message.channelId, placed, store, isCurrent)) {
      return;
    }
    await store.applyMessage(message);
  }

  /// Whether [categoryId], or the parent it sits under, is missing locally.
  Future<bool> _namesUnheldCategory(
    String? categoryId,
    MessageStore store,
  ) async {
    if (categoryId == null) return false;
    final held = {for (final c in await store.allCategories()) c.id: c};
    final category = held[categoryId];
    if (category == null) return true;
    final parentId = category.parentId;
    return parentId != null && !held.containsKey(parentId);
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

  /// Whether a created [message] in [channelId] must not be applied: it sits more than one
  /// past its channel's cursor, or at or below it without being held.
  ///
  /// Messages are dense per channel, so one further ahead means a message in
  /// between was never seen. Applying it would move the cursor past what was
  /// lost for good, so it is left to the reconcile it schedules, whose page
  /// carries the same message in order.
  ///
  /// One the cursor already covers was caught up past, so a row that is not
  /// here was deleted since or is deliberately not held. One below where a
  /// first write started the cursor was never caught up past, and is stored. Storing it brings a
  /// deleted message back: its delete is behind the op cursor by then, which a
  /// second tab on the same database reaches without ever applying it.
  ///
  /// Also true for a run superseded while the cursor was being read.
  Future<bool> _cannotPlace(
    String channelId,
    ({String id, int seq}) message,
    MessageStore store,
    bool Function() isCurrent,
  ) async {
    final cursor = await store.cursorFor(channelId);
    if (!isCurrent()) return true;
    if (cursor == null) return false;
    if (message.seq <= cursor) {
      return store.cursorCovers(channelId, cursor, message.seq) &&
          !await store.hasMessage(channelId, message.id);
    }
    if (message.seq == cursor + 1) return false;
    unawaited(
      _reconcile().catchError(
        ignoreError(LogTag.sync, 're-check state after the connection dropped'),
      ),
    );
    return true;
  }

  /// Applies a live op with [write] when it is the next one, then advances the cursor.
  ///
  /// A gap schedules one reconcile rather than applying an op it cannot place:
  /// moving the cursor past something never seen would strand it permanently,
  /// where a stall only lasts until the next round.
  ///
  /// The write comes first, so one that fails is still ahead of the cursor
  /// and the next catch-up delivers it; see docs/internals.md, sync convergence.
  /// A channel with no cursor gets one only from the stream's first op: any
  /// later op would start it past ops nobody applied.
  ///
  /// [isCurrent] is rechecked after the cursor read: a sign-out or reconnect
  /// landing inside that await leaves a number from a store the newer run has
  /// since moved past.
  Future<void> _applyLiveOp(
    ({String channelId, int? opSeq}) op,
    MessageStore store,
    bool Function() isCurrent,
    Future<void> Function() write,
  ) async {
    final cursor = await store.opCursorFor(op.channelId);
    if (!isCurrent()) return;
    switch (liveOpDecision(op.opSeq, cursor)) {
      case LiveOpOutcome.ignored:
        return;
      case LiveOpOutcome.needsReconcile:
        unawaited(
          _reconcile().catchError(
            ignoreError(
              LogTag.sync,
              're-check state after the connection dropped',
            ),
          ),
        );
      case LiveOpOutcome.applied:
        await write();
        final seq = op.opSeq;
        if (seq == null || (cursor == null && seq != 1)) return;
        await store.setOpCursor(op.channelId, seq);
    }
  }
}
