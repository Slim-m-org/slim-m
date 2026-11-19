// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's signalling socket, opened over the server's own network when the app offers a way there.
library;

// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/core/signal_client.dart' as lk_signal;
// ignore: implementation_imports
import 'package:livekit_client/src/support/websocket.dart' as lk_ws;
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens the call's signalling socket another way than LiveKit would; null leaves it to LiveKit.
typedef SignalSocketOpen = Future<WebSocketChannel?> Function(
  Uri url,
  Map<String, String>? headers,
);

/// Every signalling connect of a session's calls, first through [SignalSocketOpen].
class SignalRoute {
  SignalRoute(this._open, {lk_ws.WebSocketConnector? fallback})
      : _fallback = fallback ?? lk_ws.LiveKitWebSocket.connect;

  final SignalSocketOpen _open;
  final lk_ws.WebSocketConnector _fallback;
  bool _direct = false;

  /// Whether the socket opened last came from [SignalSocketOpen] rather than LiveKit.
  bool get direct => _direct;

  /// The signal client for one room's engine.
  lk_signal.SignalClient client() => lk_signal.SignalClient(connect);

  /// The [lk_ws.WebSocketConnector] a signal client dials with.
  Future<lk_ws.LiveKitWebSocket> connect(
    Uri uri, {
    lk_ws.WebSocketEventHandlers? options,
    Map<String, String>? headers,
    lk.NetworkOptions? networkOptions,
  }) async {
    final channel = await _tryOpen(uri, headers);
    _direct = channel != null;
    if (channel != null) return _ChannelSocket(channel, options);
    return _fallback(
      uri,
      options: options,
      headers: headers,
      networkOptions: networkOptions,
    );
  }

  Future<WebSocketChannel?> _tryOpen(
    Uri uri,
    Map<String, String>? headers,
  ) async {
    try {
      return await _open(uri, headers);
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'The other way to the call signalling failed; LiveKit connects',
        error,
        stack,
      );
      return null;
    }
  }
}

/// LiveKit's socket over a [WebSocketChannel], behaving as LiveKit's own dart:io one does.
class _ChannelSocket extends lk_ws.LiveKitWebSocket {
  _ChannelSocket(this._channel, this._handlers) {
    _subscription = _channel.stream.listen(
      (data) {
        if (!isDisposed) _handlers?.onData?.call(data);
      },
      onError: (Object error) => _handlers?.onError?.call(error),
      onDone: () async {
        _open = false;
        await _subscription.cancel();
        _handlers?.onDispose?.call();
      },
    );
    onDispose(() async {
      if (!_open) return;
      _open = false;
      await _channel.sink.close();
    });
  }

  final WebSocketChannel _channel;
  final lk_ws.WebSocketEventHandlers? _handlers;
  late final StreamSubscription<dynamic> _subscription;
  bool _open = true;

  @override
  void send(List<int> data) {
    if (!_open) return;
    try {
      _channel.sink.add(data);
    } on StateError catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'The call signalling closed under a send; LiveKit reconnects',
        error,
        stack,
      );
    }
  }
}
