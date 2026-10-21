// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `canvas.media_slot_preview.updated`.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed frame', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.media_slot_preview.updated',
        'channel_id': 'c',
        'user_id': 'mover',
        'kind': 'screen',
        'slot_user_id': 'owner',
        'x': 1,
        'y': 2.5,
        'w': 360,
        'h': 203,
        'ended': false,
      }),
    );
    expect(event, isA<CanvasMediaSlotPreview>());
    final p = event as CanvasMediaSlotPreview;
    expect((p.userId, p.slotUserId, p.kind), ('mover', 'owner', 'screen'));
    expect((p.x, p.y, p.w, p.h), (1.0, 2.5, 360.0, 203.0));
  });

  test('a frame missing its box is not a preview', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.media_slot_preview.updated',
        'channel_id': 'c',
        'user_id': 'u',
        'kind': 'camera',
        'slot_user_id': 'o',
        'ended': true,
      }),
    );
    expect(event, isNot(isA<CanvasMediaSlotPreview>()));
  });
}
