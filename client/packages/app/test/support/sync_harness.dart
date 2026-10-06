// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives a real [SyncController] against a fake server: REST answered by a
/// router the test controls, and a WebSocket this harness actually accepts
/// and can push frames down at a chosen moment.
///
/// Every widget test in this suite before this file substituted a no-op for
/// `SyncController` (see `_NoopSyncController` in
/// `channel_screen_day_divider_flash_test.dart`), which meant nothing could
/// drive a real catch-up round or a real live socket frame landing at a
/// specific moment relative to some other write in flight - only ever the
/// store directly, or the screen with sync stubbed out. This is that missing
/// piece, built for the day-divider-flash backlog entry but not specific to
/// it: any test of a live-versus-local interleaving needs the same two
/// things, a controllable catch-up response and a controllable socket.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;

/// One REST answer for [RestRouter.on].
typedef RestHandler = FutureOr<http.Response> Function(http.Request request);

/// `http.Response` shorthand for a JSON body, matching the fixtures already
/// written by hand in this suite's other tests.
http.Response jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// Routes REST calls to handlers a test registers, falling back to an empty
/// JSON list for anything unmatched - the right default for most of the
/// endpoints [SyncController]'s catch-up and channel refresh touch that a
/// given test is not about (DMs, per-channel read state, and so on).
class RestRouter {
  final _routes = <(String, String, RestHandler)>[];

  /// Registers a handler for one exact (method, path) pair. The first
  /// registered match wins, so a more specific rule should be added before a
  /// catch-all for the same path.
  void on(String method, String path, RestHandler handler) =>
      _routes.add((method, path, handler));

  /// Whether a handler is registered for this exact (method, path) pair.
  bool hasRoute(String method, String path) =>
      _routes.any((r) => r.$1 == method && r.$2 == path);

  http.Client build() => MockClient((request) async {
    for (final (method, path, handler) in _routes) {
      if (request.method == method && request.url.path == path) {
        return handler(request);
      }
    }
    return jsonResponse(const <dynamic>[]);
  });
}

/// The WebSocket half a [SlimmApi] under test actually connects to.
///
/// REST never touches the network here - [RestRouter.build] answers it
/// directly through [MockClient] - but `EventConnection.connect` calls
/// `WebSocketChannel.connect` itself and cannot be handed a fake transport,
/// so this binds one real loopback [HttpServer] for `/ws` alone. [baseUrl]
/// still has to be this server's address: [SlimmApi.webSocketUrl] is derived
/// from it, independently of whatever client answers REST.
///
/// **Both [start] and [close] must be called through `tester.runAsync`**, or
/// the whole test hangs for a fixed ~90s and then crashes with "Cannot close
/// sink while adding stream" rather than failing cleanly - the same class of
/// trap as `RenderRepaintBoundary.toImage()` needing `runAsync` (see the
/// knowledge base's Fedora-build entry), for the same underlying reason.
/// `HttpServer.bind` starts its own periodic idle-timeout timer; created
/// inside a widget test's own fake-time zone, that timer is captured as a
/// `FakeTimer`, and the test binding's shutdown then waits on it for real
/// wall-clock time before giving up. `runAsync` runs the call in the real
/// zone instead, so the timer is a real one nothing waits on. Every other
/// call on this class (`pushEvent`, reading [baseUrl]) is plain Dart with no
/// timer of its own and needs no such wrapping.
class SyncTestServer {
  SyncTestServer._(this._server);

  final HttpServer _server;
  final _sockets = <WebSocket>[];

  /// The base URL a [SlimmApi] under test should be constructed with.
  Uri get baseUrl => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port);

  /// Call as `await tester.runAsync(SyncTestServer.start)` - see the class doc.
  static Future<SyncTestServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final harness = SyncTestServer._(server);
    unawaited(harness._acceptLoop());
    return harness;
  }

  Future<void> _acceptLoop() async {
    await for (final request in _server) {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        unawaited(_accept(request));
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    }
  }

  Future<void> _accept(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.listen((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      // Only the handshake needs an answer; other frame types are fire-and-forget.
      if (frame['type'] == 'hello') {
        socket.add(
          jsonEncode({'type': 'hello', 'protocol': api.protocolVersion}),
        );
      }
    }, onDone: () => _sockets.remove(socket));
  }

  /// Sends one server event frame down every socket currently connected.
  /// These tests hold exactly one client, so this is always "the" socket.
  void pushEvent(Map<String, dynamic> frame) {
    for (final socket in _sockets) {
      socket.add(jsonEncode(frame));
    }
  }

  /// Closes every connected socket the way a restarting server would, leaving
  /// the listener up so the client's retry can connect again. Call as
  /// `await tester.runAsync(server.dropSockets)` - see the class doc.
  Future<void> dropSockets() async {
    for (final socket in List.of(_sockets)) {
      await socket.close();
    }
  }

  /// Call as `await tester.runAsync(server.close)` - see the class doc.
  Future<void> close() async {
    for (final socket in List.of(_sockets)) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
