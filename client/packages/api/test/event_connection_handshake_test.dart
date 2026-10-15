// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every way the event socket handshake can end, against a loopback server.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

/// Called for each client frame; the server owns the one listener on the socket.
typedef _OnHello = void Function(WebSocket socket);

void main() {
  late HttpServer server;
  late Uri url;
  final sockets = <WebSocket>[];
  var upgradeDelay = Duration.zero;
  late _OnHello onHello;
  late Completer<void> clientClosed;

  setUp(() async {
    upgradeDelay = Duration.zero;
    clientClosed = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('ws://127.0.0.1:${server.port}/ws');
    server.listen((request) async {
      await Future<void>.delayed(upgradeDelay);
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        if ((jsonDecode(raw as String) as Map)['type'] == 'hello') {
          onHello(socket);
        }
      }, onDone: clientClosed.complete);
    });
  });

  tearDown(() async {
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    await server.close(force: true);
  });

  /// Answers the client's hello with [frame] (a map, or a raw string).
  _OnHello answerHelloWith(Object frame) =>
      (socket) => socket.add(frame is String ? frame : jsonEncode(frame));

  Future<void> expectRefused(
    Future<EventConnection> attempt, {
    Pattern? reason,
  }) async {
    await expectLater(
      attempt,
      throwsA(
        isA<EventConnectionRefused>().having(
          (e) => e.reason,
          'reason',
          reason == null ? anything : contains(reason),
        ),
      ),
    );
  }

  Future<EventConnection> connect([
    Duration timeout = const Duration(seconds: 2),
  ]) =>
      EventConnection.connect(url: url, ticket: 't', timeout: timeout);

  test('a hello for another protocol is refused and the socket closed',
      () async {
    onHello = answerHelloWith({'type': 'hello', 'protocol': 99});
    await expectRefused(connect(), reason: 'protocol 99');
    await clientClosed.future.timeout(const Duration(seconds: 3));
  });

  test('an error frame is refused with the server message', () async {
    onHello = answerHelloWith({'type': 'error', 'message': 'bad ticket'});
    await expectRefused(connect(), reason: 'bad ticket');
    await clientClosed.future.timeout(const Duration(seconds: 3));
  });

  test('a first frame that is not a hello is refused', () async {
    onHello = answerHelloWith({
      'type': 'message.deleted',
      'channel_id': 'c',
      'message_id': 'm',
    });
    await expectRefused(connect(), reason: 'hello');
  });

  test('a silent server times out as a refusal and the socket closes',
      () async {
    onHello = (_) {};
    await expectRefused(
      connect(const Duration(milliseconds: 200)),
      reason: 'did not answer',
    );
    await clientClosed.future.timeout(const Duration(seconds: 3));
  });

  test('a socket that closes before any frame is a refusal, not a StateError',
      () async {
    onHello = (socket) => socket.close();
    await expectRefused(connect());
  });

  test('an upgrade that lands after the timeout is closed, not leaked',
      () async {
    upgradeDelay = const Duration(milliseconds: 600);
    onHello = (_) {};
    await expectRefused(connect(const Duration(milliseconds: 200)));
    while (sockets.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await clientClosed.future.timeout(const Duration(seconds: 3));
  });

  test('a malformed frame after hello is dropped without an uncaught error',
      () async {
    onHello = (socket) => socket
      ..add(jsonEncode({'type': 'hello', 'protocol': protocolVersion}))
      ..add(jsonEncode({'type': 'message.created', 'message': {}}))
      ..add(jsonEncode({'type': 'pong'}));
    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final connection = await connect();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await connection.close();
    }, (error, _) => uncaught.add(error));
    expect(uncaught, isEmpty);
  });
}
