// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'events.dart';
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'client.dart';
import 'socket_liveness.dart';
import 'logging/app_log.dart';

/// Opens the event socket and yields its events.
///
/// The connection is deliberately not self-healing here: it surfaces closure so
/// the layer above can decide to reconnect and, critically, to catch up over
/// sync before trusting the live stream again. Silent reconnection would leave
/// a gap in the sequence that the caller never learns about.
class EventConnection {
  EventConnection._(this._channel, this._events, this._liveness);

  final WebSocketChannel _channel;
  final Stream<ServerEvent> _events;
  final SocketLiveness _liveness;

  /// Events after a successful handshake.
  Stream<ServerEvent> get events => _events;

  /// Connects with a ticket from [SlimmApi.webSocketTicket]; completes once the server's hello arrives.
  /// A non-null [active] promises [active] frames from here on and says whether the person is at the device now.
  static Future<EventConnection> connect({
    required Uri url,
    required String ticket,
    Duration timeout = const Duration(seconds: 15),
    Duration keepaliveInterval = const Duration(seconds: 20),
    WebSocketChannel Function(Uri url)? open,
    bool? active,
  }) async {
    final channel = (open ?? WebSocketChannel.connect)(url);
    // A connect that lands after the timeout would otherwise leave a socket nobody listens to.
    final ready = channel.ready;
    try {
      await ready.timeout(timeout);
    } catch (error) {
      unawaited(ready.then((_) => channel.sink.close(), onError: (_) {}));
      throw EventConnectionRefused('could not open the socket: $error');
    }

    // Owned here so a silent socket can be ended without waiting on a close that never comes.
    final events = StreamController<ServerEvent>.broadcast();
    SocketLiveness? liveness;
    final subscription = channel.stream.listen(
      (raw) {
        liveness?.heard();
        final ServerEvent? event;
        try {
          event = ServerEvent.parse(
            raw is String ? raw : utf8.decode(raw as List<int>),
          );
        } on Object catch (error, stack) {
          AppLog.swallowed(LogTag.sync,
              'Dropped a server message that could not be read', error, stack);
          return;
        }
        if (event != null && event is! PongEvent) events.add(event);
      },
      onError: events.addError,
      onDone: () {
        liveness?.stop();
        unawaited(events.close());
      },
    );

    // Send the hello and wait for the server's, so the caller never sees a half-open connection.
    final handshake = events.stream.first.timeout(timeout);
    channel.sink.add(
      jsonEncode({
        'type': 'hello',
        'ticket': ticket,
        'protocol': protocolVersion,
        if (active != null) 'active': active,
      }),
    );

    final ServerEvent first;
    try {
      first = await handshake;
    } on TimeoutException {
      await channel.sink.close();
      throw const EventConnectionRefused(
        'the server did not answer the handshake',
      );
    } on StateError {
      throw const EventConnectionRefused(
        'the socket closed before the server answered',
      );
    }

    switch (first) {
      case HelloEvent(:final protocol) when protocol == protocolVersion:
        final live = SocketLiveness(
          ping: () => channel.sink.add(jsonEncode({'type': 'ping'})),
          interval: keepaliveInterval,
          onSilent: () {
            unawaited(subscription.cancel());
            unawaited(channel.sink.close());
            unawaited(events.close());
          },
        );
        liveness = live..start();
        return EventConnection._(channel, events.stream, live);
      case HelloEvent(:final protocol):
        await channel.sink.close();
        throw EventConnectionRefused(
          'the server speaks protocol $protocol, this client speaks $protocolVersion',
        );
      case ErrorEvent(:final message):
        await channel.sink.close();
        throw EventConnectionRefused(message);
      default:
        await channel.sink.close();
        throw const EventConnectionRefused(
          'the server did not open with a hello',
        );
    }
  }

  /// Whether the socket still answers, for a device that may have slept through
  /// its death. False means the caller should reconnect.
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) =>
      _liveness.probe(timeout: timeout);

  /// Refreshes "this user is typing" in a channel.
  ///
  /// There is deliberately no stop frame: the server expires the state on a
  /// TTL, so a client that closes mid-typing cannot leave the indicator stuck
  /// on somebody else's screen. Call this repeatedly while the user types.
  /// Over-sending is safe - the server rate-limits it and drops the excess
  /// silently rather than erroring or closing the socket.
  void typing(String channelId) => _channel.sink.add(
        jsonEncode({'type': 'typing', 'channel_id': channelId}),
      );

  /// Reports the channels this device has open and focused, replacing its
  /// previous report; empty clears it. [active] says the user has used this
  /// device recently, which skips message pushes to their other devices. The
  /// server lets a report lapse, so the caller re-sends it while it holds.
  void viewing(Iterable<String> channelIds, {bool active = false}) =>
      _channel.sink.add(
        jsonEncode({
          'type': 'viewing',
          'channel_ids': channelIds.toList(),
          if (active) 'active': true,
        }),
      );

  /// Reports the canvases open on this device, replacing the previous report; empty says none.
  /// Until the first report the server sends live canvas frames for every channel.
  void canvasWatch(Iterable<String> channelIds) => _channel.sink.add(
        jsonEncode({
          'type': 'canvas.watch',
          'channel_ids': channelIds.toList(),
        }),
      );

  /// Tells the server the person used this device recently. After the first
  /// one, this connection's pings stop counting as activity, so a client that
  /// sends it must keep sending it, about once a minute, while they are here.
  void active() => _channel.sink.add(jsonEncode({'type': 'active'}));

  /// Reports this user's pointer position on a channel's canvas. Ephemeral like [typing]: unacknowledged, and the server rate-limits and drops the excess silently, so the caller should throttle.
  void canvasCursor(
    String channelId,
    double x,
    double y, {
    bool left = false,
  }) =>
      _channel.sink.add(
        jsonEncode({
          'type': 'canvas.cursor',
          'channel_id': channelId,
          'x': x,
          'y': y,
          if (left) 'left': true,
        }),
      );

  /// Relays this device's in-flight stroke as a delta of [points] since this [objectId]'s last frame.
  /// Ephemeral like [canvasCursor]: unacknowledged, and the server drops excess by byte size. [ended] marks the last frame; [color] and [width] are the pen's.
  void canvasStrokePreview(
    String channelId,
    String objectId,
    List<double> points, {
    bool ended = false,
    bool cancelled = false,
    String? color,
    double? width,
  }) =>
      _channel.sink.add(
        jsonEncode({
          'type': 'canvas.stroke_preview',
          'channel_id': channelId,
          'object_id': objectId,
          'points': points,
          'ended': ended,
          if (cancelled) 'cancelled': true,
          if (color != null) 'color': color,
          if (width != null) 'width': width,
        }),
      );

  /// Relays the box of an object this device is dragging or resizing. The
  /// same ephemeral, rate-limited shape as [canvasCursor]; [ended] marks the
  /// gesture's last frame.
  void canvasObjectPreview(
    String channelId,
    String objectId,
    ({double x, double y, double w, double h}) box, {
    bool ended = false,
  }) =>
      _channel.sink.add(
        jsonEncode({
          'type': 'canvas.object_preview',
          'channel_id': channelId,
          'object_id': objectId,
          'x': box.x,
          'y': box.y,
          'w': box.w,
          'h': box.h,
          'ended': ended,
        }),
      );

  /// Relays the box of a camera or screen-share tile this device is dragging.
  /// Same ephemeral shape as [canvasObjectPreview]; [slotUserId] is whose tile it is.
  void canvasMediaSlotPreview(
    String channelId,
    String kind,
    String slotUserId,
    ({double x, double y, double w, double h}) box, {
    bool ended = false,
  }) =>
      _channel.sink.add(
        jsonEncode({
          'type': 'canvas.media_slot_preview',
          'channel_id': channelId,
          'kind': kind,
          'user_id': slotUserId,
          'x': box.x,
          'y': box.y,
          'w': box.w,
          'h': box.h,
          'ended': ended,
        }),
      );

  /// Relays a mark over [targetUserId]'s shared screen, or (kind `consent`,
  /// sent by that sharer) whether viewers may draw. Coordinates are 0 to 1 on
  /// the shared screen. Ephemeral and rate-limited like [canvasStrokePreview].
  void canvasScreenAnnotation(
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
  }) =>
      _channel.sink.add(
        jsonEncode({
          'type': 'canvas.screen_annotation',
          'channel_id': channelId,
          'target_user_id': targetUserId,
          'kind': kind,
          if (annotationId != null) 'annotation_id': annotationId,
          'points': points,
          if (color != null) 'color': color,
          if (text != null) 'text': text,
          'ended': ended,
          'allowed': allowed,
          if (aspect != null) 'aspect': aspect,
        }),
      );

  /// Relays the world rectangle this device is looking at; [summon] brings
  /// everyone to it once; [tile] is the call tile this device has full screen.
  /// Ephemeral and rate-limited like [canvasCursor].
  void canvasView(
    String channelId,
    ({double x, double y, double w, double h}) view, {
    bool summon = false,
    String? tile,
  }) =>
      _channel.sink.add(
        jsonEncode({
          'type': 'canvas.view',
          'channel_id': channelId,
          'x': view.x,
          'y': view.y,
          'w': view.w,
          'h': view.h,
          'summon': summon,
          if (tile != null) 'tile': tile,
        }),
      );

  Future<void> close() {
    _liveness.stop();
    return _channel.sink.close();
  }
}

/// The socket could not be established or the handshake was rejected.
class EventConnectionRefused implements Exception {
  const EventConnectionRefused(this.reason);

  final String reason;

  @override
  String toString() => 'EventConnectionRefused: $reason';
}
