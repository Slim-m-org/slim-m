// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The exact JSON the client sends for the canvas cursor and object-preview
/// frames, read off a loopback server, against the names `ws/frames.rs` parses.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late EventConnection connection;
  late StreamIterator<Map<String, dynamic>> frames;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = StreamController<Map<String, dynamic>>();
    frames = StreamIterator(received.stream);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['type'] == 'hello') {
          socket
              .add(jsonEncode({'type': 'hello', 'protocol': protocolVersion}));
        } else {
          received.add(frame);
        }
      });
    });
    connection = await EventConnection.connect(
      url: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      ticket: 't',
      timeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Future<Map<String, dynamic>> next() async {
    expect(await frames.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    return frames.current;
  }

  test('a cursor frame carries no left key unless the pointer left', () async {
    connection.canvasCursor('c1', 1.5, 2.5);
    expect(await next(), {
      'type': 'canvas.cursor',
      'channel_id': 'c1',
      'x': 1.5,
      'y': 2.5,
    });
  });

  test('a cursor frame for a pointer that left says so', () async {
    connection.canvasCursor('c1', 0, 0, left: true);
    expect(await next(), {
      'type': 'canvas.cursor',
      'channel_id': 'c1',
      'x': 0,
      'y': 0,
      'left': true,
    });
  });

  test('an object preview carries the id and the whole box', () async {
    connection.canvasObjectPreview('c1', 'o1', (x: 1, y: 2, w: 3, h: 4));
    connection.canvasObjectPreview(
      'c1',
      'o1',
      (x: 5, y: 6, w: 7, h: 8),
      ended: true,
    );
    expect(await next(), {
      'type': 'canvas.object_preview',
      'channel_id': 'c1',
      'object_id': 'o1',
      'x': 1,
      'y': 2,
      'w': 3,
      'h': 4,
      'ended': false,
    });
    expect((await next())['ended'], isTrue);
  });
}
