// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `canvas.cursor.moved`, the one canvas frame with
/// no counterpart in the durable object or op stream.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed canvas.cursor.moved frame', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.cursor.moved',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'x': 12.5,
        'y': -4.0,
      }),
    );

    expect(event, isA<CanvasCursorMoved>());
    final cursor = event as CanvasCursorMoved;
    expect(cursor.channelId, 'chan-1');
    expect(cursor.userId, 'user-1');
    expect(cursor.x, 12.5);
    expect(cursor.y, -4.0);
  });

  test('accepts integral x/y, not only doubles', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.cursor.moved',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'x': 5,
        'y': 0,
      }),
    );

    expect(event, isA<CanvasCursorMoved>());
    expect((event as CanvasCursorMoved).x, 5.0);
    expect(event.y, 0.0);
  });

  test('a frame missing a required field is ignored, not thrown', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.cursor.moved',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'x': 1.0,
        // y missing
      }),
    );

    expect(event, isNull);
  });

  test('a left frame says the pointer left the canvas', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.cursor.moved',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'x': 0,
        'y': 0,
        'left': true,
      }),
    );

    expect((event as CanvasCursorMoved).left, isTrue);
  });
}
