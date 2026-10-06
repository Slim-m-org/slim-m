// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A socket that goes mute without closing must end, and a healthy one must
/// not: [SocketLiveness] for the beat logic, [EventConnection] against a real
/// loopback server for the wiring.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_api/src/socket_liveness.dart';
import 'package:test/test.dart';

void main() {
  group('SocketLiveness', () {
    test('pings every beat and stays quiet while frames keep arriving', () {
      fakeAsync((async) {
        var pings = 0;
        var silent = false;
        final liveness = SocketLiveness(
          ping: () => pings++,
          onSilent: () => silent = true,
        )..start();
        for (var i = 0; i < 10; i++) {
          liveness.heard();
          async.elapse(const Duration(seconds: 20));
        }
        expect(pings, 10);
        expect(silent, isFalse);
        liveness.stop();
      });
    });

    test('fires once after maxSilentBeats beats with nothing heard', () {
      fakeAsync((async) {
        var pings = 0;
        var silent = 0;
        SocketLiveness(ping: () => pings++, onSilent: () => silent++).start();
        async.elapse(const Duration(seconds: 20));
        expect(silent, 0);
        async.elapse(const Duration(seconds: 20));
        expect(silent, 0);
        async.elapse(const Duration(seconds: 20));
        expect(silent, 1);
        async.elapse(const Duration(minutes: 5));
        expect(silent, 1, reason: 'stopped after firing');
        expect(pings, 2);
      });
    });

    test('a heard frame between silent beats restarts the count', () {
      fakeAsync((async) {
        var silent = 0;
        final liveness = SocketLiveness(ping: () {}, onSilent: () => silent++)
          ..start();
        async.elapse(const Duration(seconds: 20));
        async.elapse(const Duration(seconds: 20));
        expect(silent, 0, reason: 'one silent beat so far');
        liveness.heard();
        async.elapse(const Duration(seconds: 20));
        async.elapse(const Duration(seconds: 20));
        expect(silent, 0, reason: 'the heard frame restarted the count');
        async.elapse(const Duration(seconds: 20));
        expect(silent, 1, reason: 'two consecutive silent beats since then');
      });
    });
  });

  group('EventConnection', () {
    late HttpServer server;
    late Uri url;
    var answerPings = true;
    final sockets = <WebSocket>[];

    // A ping can land as the client closes, and the sink can close between a readyState check and add, so a closed sink is ignored.
    void reply(WebSocket socket, Map<String, Object?> frame) {
      if (socket.readyState != WebSocket.open) return;
      try {
        socket.add(jsonEncode(frame));
      } on StateError {
        return;
      }
    }

    setUp(() async {
      answerPings = true;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = Uri.parse('ws://127.0.0.1:${server.port}/ws');
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final type = (jsonDecode(raw as String) as Map)['type'];
          if (type == 'hello') {
            reply(socket, {'type': 'hello', 'protocol': 1});
          } else if (type == 'ping' && answerPings) {
            reply(socket, {'type': 'pong'});
          }
        });
      });
    });

    tearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      sockets.clear();
      await server.close(force: true);
    });

    test('a peer that stops answering ends the events stream', () async {
      final connection = await EventConnection.connect(
        url: url,
        ticket: 't',
        keepaliveInterval: const Duration(milliseconds: 50),
      );
      final done = Completer<void>();
      connection.events.listen((_) {}, onDone: done.complete);

      answerPings = false;
      await done.future.timeout(const Duration(seconds: 3));
    });

    test('a peer that keeps answering stays connected', () async {
      final connection = await EventConnection.connect(
        url: url,
        ticket: 't',
        keepaliveInterval: const Duration(milliseconds: 50),
      );
      var closed = false;
      final events = <ServerEvent>[];
      connection.events.listen(events.add, onDone: () => closed = true);

      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(closed, isFalse);
      expect(events, isEmpty, reason: 'pongs are not surfaced as events');
      await connection.close();
    });
  });
}
