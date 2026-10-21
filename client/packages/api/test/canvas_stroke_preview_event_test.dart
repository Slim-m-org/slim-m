// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `canvas.stroke_preview.updated`, the same
/// coverage `canvas_cursor_event_test.dart` gives its sibling frame, plus
/// the fields unique to this one: `object_id`, `points` and `ended`.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed canvas.stroke_preview.updated frame', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.stroke_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'object_id': 'draft-1',
        'points': [1.0, 2.0, 3.5, -4.0],
        'ended': false,
      }),
    );

    expect(event, isA<CanvasStrokePreview>());
    final preview = event as CanvasStrokePreview;
    expect(preview.channelId, 'chan-1');
    expect(preview.userId, 'user-1');
    expect(preview.objectId, 'draft-1');
    expect(preview.points, [1.0, 2.0, 3.5, -4.0]);
    expect(preview.ended, isFalse);
  });

  test('accepts integral points, not only doubles', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.stroke_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'object_id': 'draft-1',
        'points': [1, 2],
        'ended': false,
      }),
    );

    expect(event, isA<CanvasStrokePreview>());
    expect((event as CanvasStrokePreview).points, [1.0, 2.0]);
  });

  test('an ended frame may carry an empty points list', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.stroke_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'object_id': 'draft-1',
        'points': <double>[],
        'ended': true,
      }),
    );

    expect(event, isA<CanvasStrokePreview>());
    final preview = event as CanvasStrokePreview;
    expect(preview.points, isEmpty);
    expect(preview.ended, isTrue);
  });

  test('a frame missing a required field is ignored, not thrown', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.stroke_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'points': [1.0, 2.0],
        'ended': false,
        // object_id missing
      }),
    );

    expect(event, isNull);
  });

  test('a frame with a non-boolean ended is ignored, not thrown', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.stroke_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'object_id': 'draft-1',
        'points': [1.0, 2.0],
        'ended': 'no',
      }),
    );

    expect(event, isNull);
  });

  test('carries the drawer pen colour and width when sent', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.stroke_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'object_id': 'draft-1',
        'points': [1.0, 2.0],
        'ended': false,
        'color': 'blue',
        'width': 6,
      }),
    );

    final preview = event! as CanvasStrokePreview;
    expect(preview.color, 'blue');
    expect(preview.width, 6.0);
  });

  test('a frame without a pen has no colour or width', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.stroke_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'object_id': 'draft-1',
        'points': [1.0, 2.0],
        'ended': false,
      }),
    );

    final preview = event! as CanvasStrokePreview;
    expect(preview.color, isNull);
    expect(preview.width, isNull);
  });
}
