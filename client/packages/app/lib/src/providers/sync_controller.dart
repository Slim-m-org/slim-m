// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the local store current: catch-up, then live events.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';

import 'channel_history.dart';
import 'channel_notification_overrides_controller.dart';
import 'channel_refresher.dart';
import 'dm_call_activity.dart';
import 'dm_call_ring_controller.dart';
import 'ephemeral_messages.dart';
import 'presence_activity.dart';
import 'presence_controller.dart';
import 'voice_controller.dart';
import 'failed_send_retry.dart';
import 'last_text_channel.dart';
import 'message_ops_sync.dart';
import 'op_adjacency.dart';
import 'message_extras.dart';
import 'providers.dart';
import 'rate_limit_retry.dart';
import 'reconnect_backoff.dart';
import 'sync_failure.dart';
import 'sync_frame_queue.dart';
import 'typing_controller.dart';
import 'user_profiles.dart';
import 'watch_room.dart';

part 'sync_controller_catchup.dart';
part 'sync_controller_events.dart';
part 'sync_controller_reset.dart';

/// How the connection is doing, for the UI to show honestly rather than
/// pretending everything is fine while messages silently stop arriving.
enum SyncStatus { offline, connecting, live }

/// Whether this session's first catch-up round has completed, independent of
/// whether the live socket then attaches.
///
/// Read by the transcript ([MessageTranscript.historyKnown]) so an optimistic
/// send made before the very first catch-up lands does not briefly anchor a
/// day divider it does not really own - see `isNewDay`'s own doc comment.
/// Deliberately not folded into [SyncStatus]: that flips back to
/// `connecting`/`offline` on every later reconnect, while this only ever
/// needs to become true once and stay true for the session, since a
/// reconnect's catch-up can only confirm history already known, never
/// un-confirm it.
final initialSyncCompleteProvider = StateProvider<bool>((ref) => false);

/// Whether this session has had a connect attempt actually fail since it was
/// last [SyncStatus.live]: latched true the moment [start]'s catch block
/// gives up on one, cleared the moment the socket attaches.
///
/// Read by [MobileBootGate] so a phone's retry loop only ever covers the app
/// with the boot splash for the genuine first attempt, and by
/// [SpaceConnectionDot]/[RailConnectionBar] (through [displaySyncStatus]) so
/// their reading of the connection does not itself flip between "Connecting"
/// and "Offline" on every retry - once a session has genuinely failed to
/// connect, the reader has already seen that, and re-announcing it every
/// backoff cycle tells them nothing new.
final hasFailedSinceLiveProvider = StateProvider<bool>((ref) => false);

/// The [SyncStatus] to actually show, collapsing a retry's
/// [SyncStatus.connecting] attempt into [SyncStatus.offline] once
/// [hasFailedSinceLiveProvider] has latched: a session that has already
/// failed once is not made newly "connecting" by trying again on the same
/// backoff loop.
SyncStatus displaySyncStatus(SyncStatus status, bool hasFailedSinceLive) {
  if (status == SyncStatus.live || !hasFailedSinceLive) return status;
  return SyncStatus.offline;
}

/// Drives synchronisation.
///
/// The order matters and is the whole point: on every (re)connect it catches up
/// over REST first, then attaches the live socket. Attaching first would leave a
/// gap between the last message the client holds and the first one the socket
/// delivers, and nothing would ever notice.
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
  SyncController(this._ref, {Random? random})
    : _backoff = ReconnectBackoff(random: random),
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
  final ReconnectBackoff _backoff;
  final _channelRefresher = ChannelRefresher();

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
  void notifyViewing(Iterable<String> channelIds) =>
      _connection?.viewing(channelIds);

  /// Tells the server this user's pointer moved on a channel's canvas.
  ///
  /// The same no-op-while-down shape as [notifyTyping]: a cursor position
  /// missed during a reconnect is worth nothing and must never surface as an
  /// error to whoever is drawing.
  void notifyCanvasCursor(String channelId, double x, double y) =>
      _connection?.canvasCursor(channelId, x, y);

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
  }) => _connection?.canvasStrokePreview(
    channelId,
    objectId,
    points,
    ended: ended,
  );

  /// Starts, or restarts, synchronisation. Safe to call repeatedly: a call
  /// superseded by a later [start] or a [stop] before it reaches a given
  /// checkpoint abandons itself there rather than finishing against a
  /// session, or a store, that has since moved on.
  Future<void> start() async {
    if (_disposed) return;
    final generation = ++_generation;
    _retry?.cancel();
    await _teardown();
    if (generation != _generation) return;
    state = SyncStatus.connecting;
    // No cursor over a rename to catch up from, so forget every cached name on a fresh connect.
    _ref.read(batchProfilesControllerProvider.notifier).clear();
    // A missed voice.activity frame while disconnected is otherwise unrecoverable.
    _ref.read(dmCallActivityProvider.notifier).clear();
    _ref.read(dmCallRingControllerProvider.notifier).clear();
    // Same: typing.stopped is ephemeral, so one missed frame sticks forever.
    _ref.invalidate(typingControllerProvider);
    // A watch tick is ephemeral too: the session may have moved on or ended while offline.
    _ref.invalidate(watchRoomProvider);
    // Listens for private answers from here on; created lazily it would miss the first one.
    _ref.read(ephemeralMessagesProvider);
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
      await _catchUp(generation, api, store);
      if (generation != _generation) return;
      _ref.read(initialSyncCompleteProvider.notifier).state = true;
      final frames = await _attach(generation, api, store);
      if (frames == null) return;
      await frames.flush();
      if (generation != _generation) return;

      _backoff.reset();
      state = SyncStatus.live;
      _ref.read(hasFailedSinceLiveProvider.notifier).state = false;
      _ref.read(syncFailureProvider.notifier).state = null;
      // A DB read failure here must not read as this connect itself having failed; retryMessage's own catch already covers a failed resend.
      unawaited(
        retryFailedSends(
          _ref.read,
          store,
          isCurrent: () => generation == _generation,
        ).catchError((_) {}),
      );
    } catch (error) {
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
    state = SyncStatus.offline;
    _scheduleRetry();
  }

  /// Backs off, and jitters, so a server restart does not bring every client
  /// back in the same instant. See [ReconnectBackoff] for the delay itself;
  /// this only schedules the timer it returns.
  void _scheduleRetry() {
    if (_disposed) return;
    _retry?.cancel();
    _retry = Timer(_backoff.next(), start);
  }

  Future<void> _teardown() async {
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
    _ref.read(messageExtrasProvider.notifier).clear();
    _ref.read(dmCallRingControllerProvider.notifier).clear();
    _ref.read(dmCallActivityProvider.notifier).clear();
    _ref.read(presenceControllerProvider.notifier).clear();
    _ref.read(presenceActivityProvider.notifier).clear();
    // A session can end without the user asking; see this method's own doc.
    unawaited(_ref.read(voiceControllerProvider.notifier).leave());
    try {
      final store = await _ref.read(storeProvider.future);
      await store.clear();
    } catch (_) {
      // Nothing useful to do here, and the sign-out itself already succeeded.
    }
  }

  @override
  void dispose() {
    _disposed = true;
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
