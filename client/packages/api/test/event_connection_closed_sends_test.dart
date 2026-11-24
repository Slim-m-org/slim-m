// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ephemeral frames sent after the client closed the socket are dropped, not thrown.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['type'] == 'hello') {
          socket
              .add(jsonEncode({'type': 'hello', 'protocol': protocolVersion}));
        }
      });
    });
  });

  tearDown(() => server.close(force: true));

  test('every ephemeral sender is a no-op after close', () async {
    final connection = await EventConnection.connect(
      url: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      ticket: 't',
      timeout: const Duration(seconds: 2),
    );
    await connection.close();
    expect(() => connection.typing('c'), returnsNormally);
    expect(() => connection.viewing(['c']), returnsNormally);
    expect(() => connection.active(), returnsNormally);
    expect(() => connection.canvasWatch(['c']), returnsNormally);
    expect(() => connection.canvasCursor('c', 1, 2), returnsNormally);
  });
}
