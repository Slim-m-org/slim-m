// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `canvas.view.updated`.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed canvas.view.updated frame', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.view.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'x': 0,
        'y': 10.5,
        'w': 960,
        'h': 540,
        'summon': true,
      }),
    );

    final view = event as CanvasView;
    expect(view.userId, 'user-1');
    expect((view.x, view.y, view.w, view.h), (0.0, 10.5, 960.0, 540.0));
    expect(view.summon, isTrue);
  });

  test('a frame missing its rectangle is not a view', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.view.updated',
        'channel_id': 'chan-1',
        'user_id': 'user-1',
        'summon': false,
      }),
    );

    expect(event, isNot(isA<CanvasView>()));
  });
}
