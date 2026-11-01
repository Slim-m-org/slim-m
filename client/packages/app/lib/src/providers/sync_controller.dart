// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the local store current: catch-up, then live events.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';

import '../features/auth/providers/account_state_refresh.dart';
import '../features/channels/providers/channel_refresher.dart';
import '../features/messages/providers/failed_send_retry.dart';
import 'providers.dart';
import 'app_lifecycle.dart';
import '../sync/providers/reconnect_backoff.dart';
import '../sync/providers/sync_failure.dart';
import '../sync/providers/sync_ephemeral_reset.dart';
import '../sync/providers/sync_catch_up.dart';
import '../sync/providers/sync_event_applier.dart';
import '../sync/providers/sync_frame_queue.dart';
import '../sync/providers/sync_reconnector.dart';
import '../sync/providers/sync_session_end.dart';

import '../sync/providers/sync_status.dart';

export '../sync/providers/sync_catch_up.dart'
    show syncChunkRetryDelaysProvider, syncScopeChunk;
export '../sync/providers/sync_status.dart';

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
  }) : super(SyncStatus.offline) {
    _reconnector = SyncReconnector(
      ref: _ref,
      backoff: ReconnectBackoff(random: random, step: backoffStep),
      start: start,
      isDisposed: () => _disposed,
      wantsConnection: () => _wantsConnection,
      status: () => state,
      generation: () => _generation,
      probe: () => _connection?.probe(),
      failConnect: _failConnect,
    );
    _catchUp = SyncCatchUp(_ref, (generation) => generation == _generation);
    _applier = SyncEventApplier(
      _ref,
      (generation) => generation == _generation,
      _channelRefresher,
      reconcile,
      _reconnector.resyncAfterLag,
    );
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
    _ref.listen(appLifecycleProvider, _reconnector.onLifecycle);
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
  bool _disposed = false;

  /// False once [stop] or [dispose] ran, so a resume does not revive a stopped sync.
  bool _wantsConnection = false;
  late final SyncReconnector _reconnector;
  late final SyncCatchUp _catchUp;
  late final SyncEventApplier _applier;
  final _channelRefresher = ChannelRefresher();

  /// Whether this controller has been live before, which tells a reconnect from
  /// the first connect of a session.
  bool _wasLive = false;

  /// Bumped by every [stop], fresh [start] and [dispose]; every await followed by a write re-checks it.
  int _generation = 0;

  /// Every event this session receives, broadcast to features (presence, typing, reactions, pins, polls) that need no socket of their own.
  /// Outlives any one connection: never recreated by [_teardown] or a reconnect.
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

  final _watchedCanvases = <String>[];

  /// Tells the server a canvas is open here so it sends its live frames; call the result when it closes.
  void Function() watchCanvas(String channelId) {
    _watchedCanvases.add(channelId);
    _connection?.canvasWatch(_watchedCanvases.toSet());
    return () {
      _watchedCanvases.remove(channelId);
      _connection?.canvasWatch(_watchedCanvases.toSet());
    };
  }

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

  /// Tells the server this user's pointer moved on a channel's canvas; a no-op while the socket is down, like [notifyTyping].
  void notifyCanvasCursor(
    String channelId,
    double x,
    double y, {
    bool left = false,
  }) => _connection?.canvasCursor(channelId, x, y, left: left);

  /// Tells the server this user's in-flight stroke gained points, or ended; a no-op while the socket is down.
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

  /// Relays a mark over a shared screen, or the sharer's consent; the same no-op-while-down shape.
  void notifyCanvasScreenAnnotation(
    String channelId,
    String targetUserId,
    String kind, {
    String? annotationId,
    List<double> points = const [],
    String? color,
    String? text,
    bool ended = false,
    bool allowed = false,
    double? aspect,
  }) => _connection?.canvasScreenAnnotation(
    channelId,
    targetUserId,
    kind,
    annotationId: annotationId,
    points: points,
    color: color,
    text: text,
    ended: ended,
    allowed: allowed,
    aspect: aspect,
  );

  /// Tells the server the world rectangle this user is looking at; the same
  /// no-op-while-down shape.
  void notifyCanvasView(
    String channelId,
    ({double x, double y, double w, double h}) view, {
    bool summon = false,
    String? tile,
  }) => _connection?.canvasView(channelId, view, summon: summon, tile: tile);

  /// Starts, or restarts, synchronisation. Safe to call repeatedly: a call
  /// superseded by a later [start] or a [stop] before it reaches a given
  /// checkpoint abandons itself there rather than finishing against a
  /// session, or a store, that has since moved on.
  Future<void> start() async {
    if (_disposed) return;
    final generation = ++_generation;
    _wantsConnection = true;
    _reconnector.cancelRetry();
    await _teardown();
    if (generation != _generation) return;
    state = SyncStatus.connecting;
    _applier.unlistedChannels.clear();
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
      await _catchUp.run(
        generation,
        api,
        store,
        onFirstRound: () =>
            _ref.read(initialSyncCompleteProvider.notifier).state = true,
      );
      if (generation != _generation) return;
      final frames = await _attach(generation, api, store);
      if (frames == null) return;
      await _catchUp.run(
        generation,
        api,
        store,
        shouldStop: () => frames.overflowed,
      );
      if (generation != _generation) return;
      if (frames.closed) throw const SocketClosedDuringConnect();
      if (frames.overflowed) throw const FrameBacklogOverflow();
      await frames.flush();
      if (generation != _generation) return;
      if (frames.closed) throw const SocketClosedDuringConnect();

      _reconnector.connected();
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
    } on FrameBacklogOverflow catch (error, stack) {
      if (generation == _generation) {
        _reconnector.onBacklogOverflow(error, stack);
      }
    } catch (error, stack) {
      if (generation == _generation) _failConnect(error, stack);
    }
  }

  void _failConnect(Object error, StackTrace stack) {
    reportFailure(LogTag.sync, 'connect to the server', error, stack);
    // Both show offline and retry with backoff, but the reader is told which: see syncFailureProvider.
    state = SyncStatus.offline;
    _ref.read(hasFailedSinceLiveProvider.notifier).state = true;
    _ref.read(syncFailureProvider.notifier).state = syncFailureFor(error);
    _reconnector.scheduleRetry();
  }

  /// Attaches the live socket and returns the queue its frames land in, held
  /// until [start] has caught up. Null when a newer run superseded this one;
  /// a frame that closes the socket schedules a full restart.
  ///
  /// [generation] is checked after the ticket mint and the connect, both
  /// network round trips a [stop] can land inside (docs/internals.md, sync generations).
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
    connection.canvasWatch(_watchedCanvases.toSet());

    final frames = SerialFrameQueue(
      (event) => _applier.apply(generation, api, store, event),
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
    await _applier.apply(generation ?? _generation, api, store, event);
  }

  void _onDropped() {
    if (_disposed || state == SyncStatus.connecting) return;
    _reconnector.backoff.dropped();
    state = SyncStatus.offline;
    _reconnector.scheduleRetry();
  }

  Future<void> _teardown() async {
    _reconnector.backoff.dropped();
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
    _reconnector.cancelRetry();
    await _teardown();
    state = SyncStatus.offline;
  }

  /// The session ended, whichever way: stop syncing, then clear what belongs to it.
  Future<void> _endSession() async {
    await stop();
    await clearSessionState(_ref);
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
          await _catchUp.run(generation, api, store);
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

  @override
  void dispose() {
    _disposed = true;
    _wantsConnection = false;
    _generation++;
    unawaited(_sessionSubscription.cancel());
    _reconnector.cancelRetry();
    unawaited(_teardown());
    unawaited(_liveEvents.close());
    super.dispose();
  }
}

final syncControllerProvider =
    StateNotifierProvider<SyncController, SyncStatus>(
      (ref) => SyncController(ref),
    );
