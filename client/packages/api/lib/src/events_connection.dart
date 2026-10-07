// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'events.dart';

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

  /// Connects, mints nothing itself: pass a ticket from
  /// [SlimmApi.webSocketTicket]. Completes once the server's hello arrives, so
  /// a returned connection is authenticated and ready.
  static Future<EventConnection> connect({
    required Uri url,
    required String ticket,
    Duration timeout = const Duration(seconds: 15),
    Duration keepaliveInterval = const Duration(seconds: 20),
  }) async {
    final channel = WebSocketChannel.connect(url);
    await channel.ready.timeout(timeout);

    // Owned here so a silent socket can be ended without waiting on a close that never comes.
    final events = StreamController<ServerEvent>.broadcast();
    SocketLiveness? liveness;
    final subscription = channel.stream.listen(
      (raw) {
        liveness?.heard();
        final event = ServerEvent.parse(
          raw is String ? raw : utf8.decode(raw as List<int>),
        );
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

  /// Reports this user's pointer position on a channel's canvas.
  ///
  /// Ephemeral like [typing]: no acknowledgement, no retry, and safe to call
  /// as often as the caller likes - the server rate-limits and drops the
  /// excess silently. The caller is expected to throttle on its own so a
  /// well-behaved client rarely hits that limit in the first place.
  void canvasCursor(String channelId, double x, double y) => _channel.sink.add(
        jsonEncode({
          'type': 'canvas.cursor',
          'channel_id': channelId,
          'x': x,
          'y': y,
        }),
      );

  /// Relays this device's own in-flight stroke, a delta of [points] since
  /// this [objectId]'s last frame. The same ephemeral shape as
  /// [canvasCursor]: no acknowledgement, safe to call as often as the caller
  /// likes, and the server rate-limits it (by the frame's own byte size
  /// rather than by count) and drops the excess silently. [ended] marks the
  /// gesture's last frame.
  void canvasStrokePreview(
    String channelId,
    String objectId,
    List<double> points, {
    bool ended = false,
  }) =>
      _channel.sink.add(
        jsonEncode({
          'type': 'canvas.stroke_preview',
          'channel_id': channelId,
          'object_id': objectId,
          'points': points,
          'ended': ended,
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
