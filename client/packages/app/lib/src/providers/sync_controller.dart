// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the local store current: catch-up, then live events.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';

import '../features/auth/providers/account_state_refresh.dart';
import '../features/channels/providers/channel_history.dart';
import '../features/channels/providers/channel_notification_overrides_controller.dart';
import '../features/channels/providers/channel_refresher.dart';
import '../features/voice/providers/dm_call_activity.dart';
import '../features/voice/providers/dm_call_ring_controller.dart';
import '../features/messages/providers/ephemeral_messages.dart';
import '../features/members/providers/presence_activity.dart';
import '../features/members/providers/presence_controller.dart';
import '../features/members/providers/presence_devices.dart';
import '../features/voice/providers/voice_controller.dart';
import '../features/messages/providers/failed_send_retry.dart';
import '../features/channels/providers/last_text_channel.dart';
import '../features/members/providers/member_presence.dart';
import '../features/messages/providers/message_ops_sync.dart';
import 'app_lifecycle.dart';
import 'op_adjacency.dart';
import '../features/messages/providers/message_extras.dart';
import 'providers.dart';
import 'rate_limit_retry.dart';
import 'reconnect_backoff.dart';
import 'sync_failure.dart';
import 'sync_ephemeral_reset.dart';
import 'sync_frame_queue.dart';

import 'sync_status.dart';

export 'sync_status.dart';

part 'sync_controller_catchup.dart';
part 'sync_controller_events.dart';
part 'sync_controller_reset.dart';
part 'sync_controller_resume.dart';

/// Drives synchronisation.
///
/// The order matters and is the whole point. On every (re)connect it catches up
/// over REST first, so the first paint never waits on the socket; then attaches
/// the live socket, holding what it delivers; then catches up once more; then
/// applies what it held. The server only subscribes a socket to its fan-out
/// when that socket's hello is read, so anything committed between the first
/// catch-up and that subscription is in neither. The second catch-up runs after
/// the subscription, which is what closes that window, and what the socket
/// delivered meanwhile is applied afterwards: re-applying a message the
/// catch-up already holds is a no-op, so the overlap needs no deduplication of
/// its own.
///
/// The socket is only a delivery route for things already written durably, so
/// losing it is never data loss, just staleness, and reconnecting re-runs the
/// same catch-up.
///
/// Session-driven: starts the moment a session begins, whether that is a
/// fresh sign-in or one restored from the last launch, and stops the moment
/// one ends, whether that is a sign-out or a refresh token the server
/// rejected. Only that 0-to-1 or 1-to-0 edge matters, not every token
/// rotation in between, so a routine access-token refresh mid-session does
/// not drop and reconnect the socket for no reason.
class SyncController extends StateNotifier<SyncStatus> {
  SyncController(
    this._ref, {
    Random? random,
    Duration backoffStep = const Duration(seconds: 1),
  }) : _backoff = ReconnectBackoff(random: random, step: backoffStep),
       super(SyncStatus.offline) {
    final session = _ref.read(sessionProvider);
    // Subscribe before reading the current value, so a change landing between the two is never missed.
    _sessionSubscription = session.changes.listen((tokens) {
      final signedIn = tokens != null;
      if (signedIn == _lastSignedIn) return;
      _lastSignedIn = signedIn;
      if (signedIn) {
        // A fresh sign-in reuses this process, so a stale cached identity must not survive it.
        _ref.invalidate(meProvider);
        unawaited(start());
      } else {
        unawaited(_endSession());
      }
    });
    _lastSignedIn = session.isSignedIn;
    _ref.listen(appLifecycleProvider, _onLifecycle);
    if (_lastSignedIn) unawaited(start());
  }

  final Ref _ref;
  late final StreamSubscription<TokenPair?> _sessionSubscription;
  bool _lastSignedIn = false;
  EventConnection? _connection;
  StreamSubscription<ServerEvent>? _events;
  SerialFrameQueue? _frames;
  bool _reconciling = false;
  bool _reconcileAgain = false;
  Timer? _retry;
  bool _disposed = false;

  SyncStatus get _status => state;

  /// False once [stop] or [dispose] ran, so a resume does not revive a stopped sync.
  bool _wantsConnection = false;
  final ReconnectBackoff _backoff;
  final _channelRefresher = ChannelRefresher();

  /// Channels a refresh on this connection did not bring into the store, such
  /// as threads, which the channel list never names.
  final _unlistedChannels = <String>{};

  /// Whether this controller has been live before, which tells a reconnect from
  /// the first connect of a session.
  bool _wasLive = false;

  /// Bumped by every [stop], every fresh [start] and [dispose], so a run
  /// superseded mid-flight (a sign-out landing during catch-up, or a second
  /// start racing the first) notices at its next checkpoint rather than
  /// finishing and writing stale data into a store a newer run already
  /// cleared. Every await in this class that is followed by a write has to
  /// re-check it, including the ones inside [ChannelRefresher], which is why
  /// that takes the predicate rather than being trusted to finish quickly.
  int _generation = 0;

  /// Every event this session receives, broadcast to whoever else wants one
  /// (presence, typing, reactions, pins, polls): a second, independent
  /// listener on top of the store-application switch below, so those
  /// features do not need their own socket connection or their own copy of
  /// the reconnect/backoff logic. Outlives any one connection: created once
  /// here, never recreated by [_teardown] or a reconnect.
  final _liveEvents = StreamController<ServerEvent>.broadcast();

  /// Every event this session receives, for anything that wants to react to
  /// one live rather than re-deriving it from the local store.
  Stream<ServerEvent> get liveEvents => _liveEvents.stream;

  /// Tells the server this user is typing in a channel.
  ///
  /// A no-op while the socket is down: typing is ephemeral, so a refresh
  /// missed during a reconnect is worth nothing and must never surface as an
  /// error to the person typing.
  void notifyTyping(String channelId) => _connection?.typing(channelId);

  /// Tells the server which channels this device has open and focused; a
  /// no-op while the socket is down, like [notifyTyping].
  void notifyViewing(Iterable<String> channelIds, {bool active = false}) =>
      _connection?.viewing(channelIds, active: active);

  /// Whether the person is at this device, asked at each connect; set by the
  /// presence activity reporter. Unset sends no claim, keeping ping-based presence.
  bool Function()? activeAtHello;

  /// Tells the server the person used this device recently; a no-op while the
  /// socket is down, like [notifyTyping], and false then so the caller retries.
  bool notifyActive() {
    final connection = _connection;
    if (connection == null) return false;
    connection.active();
    return true;
  }

  /// Tells the server this user's pointer moved on a channel's canvas.
  ///
  /// The same no-op-while-down shape as [notifyTyping]: a cursor position
  /// missed during a reconnect is worth nothing and must never surface as an
  /// error to whoever is drawing.
  void notifyCanvasCursor(
    String channelId,
    double x,
    double y, {
    bool left = false,
  }) => _connection?.canvasCursor(channelId, x, y, left: left);

  /// Tells the server this user's in-flight stroke gained points, or ended.
  ///
  /// The same no-op-while-down shape as [notifyCanvasCursor]: a preview
  /// frame missed during a reconnect is worth nothing and must never surface
  /// as an error to whoever is drawing.
  void notifyCanvasStrokePreview(
    String channelId,
    String objectId,
    List<double> points, {
    bool ended = false,
    bool cancelled = false,
    String? color,
    double? width,
  }) => _connection?.canvasStrokePreview(
    channelId,
    objectId,
    points,
    ended: ended,
    cancelled: cancelled,
    color: color,
    width: width,
  );

  /// Tells the server the box of the object this user is dragging or
  /// resizing, or that the gesture ended; the same no-op-while-down shape.
  void notifyCanvasObjectPreview(
    String channelId,
    String objectId,
    ({double x, double y, double w, double h}) box, {
    bool ended = false,
  }) =>
      _connection?.canvasObjectPreview(channelId, objectId, box, ended: ended);

  /// Tells the server the box of the camera or screen-share tile this user is
  /// dragging; the same no-op-while-down shape.
  void notifyCanvasMediaSlotPreview(
    String channelId,
    String kind,
    String slotUserId,
    ({double x, double y, double w, double h}) box, {
    bool ended = false,
  }) => _connection?.canvasMediaSlotPreview(
    channelId,
    kind,
    slotUserId,
    box,
    ended: ended,
  );

  /// Tells the server the world rectangle this user is looking at; the same
  /// no-op-while-down shape.
  void notifyCanvasView(
    String channelId,
    ({double x, double y, double w, double h}) view, {
    bool summon = false,
  }) => _connection?.canvasView(channelId, view, summon: summon);

  /// Starts, or restarts, synchronisation. Safe to call repeatedly: a call
  /// superseded by a later [start] or a [stop] before it reaches a given
  /// checkpoint abandons itself there rather than finishing against a
  /// session, or a store, that has since moved on.
  Future<void> start() async {
    if (_disposed) return;
    final generation = ++_generation;
    _wantsConnection = true;
    _retry?.cancel();
    await _teardown();
    if (generation != _generation) return;
    state = SyncStatus.connecting;
    _unlistedChannels.clear();
    resetEphemeralSessionState(_ref);
    try {
      final api = _ref.read(apiProvider);
      final store = await _ref.read(storeProvider.future);
      if (generation != _generation) return;

      await _channelRefresher.refresh(
        api,
        store,
        isCurrent: () => generation == _generation,
      );
      if (generation != _generation) return;
      await _catchUp(
        generation,
        api,
        store,
        onFirstRound: () =>
            _ref.read(initialSyncCompleteProvider.notifier).state = true,
      );
      if (generation != _generation) return;
      final frames = await _attach(generation, api, store);
      if (frames == null) return;
      await _catchUp(generation, api, store);
      if (generation != _generation) return;
      if (frames.closed) throw const SocketClosedDuringConnect();
      if (frames.overflowed) throw const FrameBacklogOverflow();
      await frames.flush();
      if (generation != _generation) return;
      if (frames.closed) throw const SocketClosedDuringConnect();

      _backoff.connected();
      state = SyncStatus.live;
      refreshAccountNotificationState(_ref, reconnect: _wasLive);
      _wasLive = true;
      _ref.read(hasFailedSinceLiveProvider.notifier).state = false;
      _ref.read(syncFailureProvider.notifier).state = null;
      // A DB read failure here must not read as this connect itself having failed; retryMessage's own catch already covers a failed resend.
      unawaited(
        retryFailedSends(
          _ref.read,
          store,
          isCurrent: () => generation == _generation,
        ).catchError(ignoreError(LogTag.sync, 'resend unsent messages')),
      );
    } catch (error, stack) {
      reportFailure(LogTag.sync, 'connect to the server', error, stack);
      if (generation != _generation) return;
      // Both show offline and retry with backoff, but the reader is told which: see syncFailureProvider.
      state = SyncStatus.offline;
      _ref.read(hasFailedSinceLiveProvider.notifier).state = true;
      _ref.read(syncFailureProvider.notifier).state = syncFailureFor(error);
      _scheduleRetry();
    }
  }

  /// Attaches the live socket and returns the queue its frames land in, held
  /// until [start] has caught up. Null when a newer run superseded this one.
  /// A frame that closes the socket is a drop that schedules a full restart, so
  /// the next connection catches up before trusting live events again.
  ///
  /// [generation] is checked after the ticket mint and the connect, because
  /// both are network round trips: a [stop] landing inside either used to
  /// return from [start] having already assigned a socket the superseding
  /// [_teardown] had run too early to see, leaving it live and applying
  /// frames with nothing left holding a handle to close it.
  Future<SerialFrameQueue?> _attach(
    int generation,
    SlimmApi api,
    MessageStore store,
  ) async {
    final ticket = await api.webSocketTicket();
    final connection = await EventConnection.connect(
      url: api.webSocketUrl,
      ticket: ticket.ticket,
      open: api.openWebSocket,
      active: activeAtHello?.call(),
    );
    if (generation != _generation) {
      await connection.close();
      return null;
    }
    _connection = connection;

    final frames = SerialFrameQueue(
      (event) => _applyServerEvent(generation, api, store, event),
      onError: (_, _) {
        if (generation == _generation) _onDropped();
      },
    );
    _frames = frames;
    void lost() {
      frames.closed = true;
      _onDropped();
    }

    _events = connection.events.listen(
      (event) {
        if (generation != _generation) return;

        /// Broadcast first and unconditionally: a listener that only cares
        /// about, say, ReactionsChanged must not depend on this switch ever
        /// learning about that event type.
        _liveEvents.add(event);
        frames.add(event);
      },
      onError: (_) => lost(),
      onDone: lost,
    );
    return frames;
  }

  /// Applies one live event the way [_attach]'s listener would, without
  /// needing a real socket. For tests only.
  @visibleForTesting
  /// [generation] defaults to the live one; a test passes a stale value to
  /// stand in for a sign-out or reconnect that landed mid-event.
  Future<void> applyServerEventForTest(
    ServerEvent event, {
    int? generation,
  }) async {
    final api = _ref.read(apiProvider);
    final store = await _ref.read(storeProvider.future);
    await _applyServerEvent(generation ?? _generation, api, store, event);
  }

  void _onDropped() {
    if (_disposed || state == SyncStatus.connecting) return;
    _backoff.dropped();
    state = SyncStatus.offline;
    _scheduleRetry();
  }

  /// Backs off, and jitters, so a server restart does not bring every client
  /// back in the same instant. See [ReconnectBackoff] for the delay itself;
  /// this only schedules the timer it returns.
  void _scheduleRetry() {
    if (_disposed || _backgroundedOnPhone) return;
    _retry?.cancel();
    _retry = Timer(_backoff.next(), start);
  }

  Future<void> _teardown() async {
    _backoff.dropped();
    await _events?.cancel();
    _events = null;
    _frames?.clear();
    _frames = null;
    await _connection?.close();
    _connection = null;
  }

  /// Stops synchronising, for sign-out.
  ///
  /// Deliberately does not touch the local database. The sign-out and delete
  /// handlers await this before their request goes out, and a delete that
  /// fails keeps the session on purpose; wiping here would throw the cache
  /// away for an account the user is still signed into. The wipe belongs to
  /// the session actually ending, which is [_endSession].
  Future<void> stop() async {
    // Supersedes any in-flight start(), even one paused mid-catch-up on a network call.
    _generation++;
    _wantsConnection = false;
    _channelRefresher.discardInFlight();
    _retry?.cancel();
    await _teardown();
    state = SyncStatus.offline;
  }

  /// The session ended, whichever way: a sign-out, an account deletion that
  /// went through, or a refresh the server rejected.
  ///
  /// The local database is one file for the whole app, not one per account or
  /// per server, so whatever survives here is read by whoever signs in next on
  /// this device: the previous account's channel list and message text,
  /// visible before any new sync could correct it. Phones get handed over and
  /// desktops are shared, so the cache goes the moment it stops belonging to
  /// the person holding the device.
  ///
  /// Best-effort. A database that will not open or clear must not leave
  /// somebody stuck signed in, so the failure is swallowed; the session is
  /// already gone by the time this runs.
  ///
  /// [channelHistoryProvider] and [messageExtrasProvider] are reset alongside
  /// the database for the same reason; see their own doc comments.
  ///
  /// The DM-call ring state is cleared here too, and that is not cosmetic:
  /// see `sign_out_stops_the_ring_test.dart` for what a surviving ring does.
  ///
  /// Leaving the voice call belongs here rather than only in the Sign Out
  /// button, because a session can end without the user asking for it.
  /// `SlimmApi._refreshOnce` clears the session on a 401 while refreshing -
  /// an expired or revoked refresh token, or another device signing this
  /// account out - and that path reaches this method without passing through
  /// any UI. Until it did, an involuntary end left a live microphone
  /// publishing into a room the app itself considered signed out of, until
  /// the server's own 40-second stale-heartbeat sweep noticed. `leave()`
  /// bumps its own call generation and is safe to call when not in a call,
  /// so the explicit Sign Out path calling it first costs nothing here.
  Future<void> _endSession() async {
    await stop();
    _ref.invalidate(channelHistoryProvider);
    _ref.invalidate(meProvider);
    _ref.invalidate(initialSyncCompleteProvider);
    _ref.invalidate(hasFailedSinceLiveProvider);
    _ref.invalidate(syncFailureProvider);
    _ref.invalidate(ephemeralMessagesProvider);
    _ref.invalidate(lastTextChannelProvider);
    _ref.invalidate(previousTextChannelProvider);
    _ref.invalidate(deletedChannelsProvider);
    _ref.read(messageExtrasProvider.notifier).clear();
    _ref.read(dmCallRingControllerProvider.notifier).clear();
    _ref.read(dmCallActivityProvider.notifier).clear();
    _ref.read(presenceControllerProvider.notifier).clear();
    _ref.read(presenceActivityProvider.notifier).clear();
    _ref.read(presenceDevicesProvider.notifier).clear();
    _ref.invalidate(presenceVisibilityDisplayProvider);
    _ref.invalidate(memberProfileOverridesProvider);
    // A session can end without the user asking; see this method's own doc.
    unawaited(_ref.read(voiceControllerProvider.notifier).leave());
    try {
      final store = await _ref.read(storeProvider.future);
      await store.clear();
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.sync,
        'Could not clear local data after signing out',
        error,
        stack,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _wantsConnection = false;
    _generation++;
    unawaited(_sessionSubscription.cancel());
    _retry?.cancel();
    unawaited(_teardown());
    unawaited(_liveEvents.close());
    super.dispose();
  }
}

final syncControllerProvider =
    StateNotifierProvider<SyncController, SyncStatus>(
      (ref) => SyncController(ref),
    );
