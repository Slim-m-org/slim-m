// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `canvas.object_preview.updated`.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed canvas.object_preview.updated frame', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.object_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'object_id': 'obj-1',
        'x': 1,
        'y': 2.5,
        'w': 40,
        'h': 20.5,
        'ended': false,
      }),
    );

    expect(event, isA<CanvasObjectPreview>());
    final preview = event as CanvasObjectPreview;
    expect(preview.objectId, 'obj-1');
    expect(
        (preview.x, preview.y, preview.w, preview.h), (1.0, 2.5, 40.0, 20.5));
    expect(preview.ended, isFalse);
  });

  test('a frame missing its box is not a preview', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.object_preview.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'object_id': 'obj-1',
        'ended': false,
      }),
    );

    expect(event, isNot(isA<CanvasObjectPreview>()));
  });
}
