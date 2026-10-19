// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hello's `active` claim and the `active` frame, read off a loopback
/// server, against the names `ws/frames.rs` parses.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late StreamController<Map<String, dynamic>> received;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    received = StreamController<Map<String, dynamic>>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        received.add(frame);
        if (frame['type'] == 'hello') {
          socket
              .add(jsonEncode({'type': 'hello', 'protocol': protocolVersion}));
        }
      });
    });
  });

  tearDown(() => server.close(force: true));

  Future<EventConnection> open({bool? active}) => EventConnection.connect(
        url: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        ticket: 't',
        timeout: const Duration(seconds: 2),
        active: active,
      );

  test('a hello without a claim carries no active key', () async {
    final connection = await open();
    final hello = await received.stream.first;
    expect(hello.containsKey('active'), isFalse);
    await connection.close();
  });

  test('a hello says whether the person is here, and active frames follow',
      () async {
    final frames = StreamIterator(received.stream);
    final connection = await open(active: false);
    expect(await frames.moveNext(), isTrue);
    expect(frames.current['active'], false);
    connection.active();
    expect(await frames.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(frames.current, {'type': 'active'});
    await connection.close();
  });
}
