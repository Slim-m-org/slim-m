// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `canvas.screen_annotation.updated`.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, Object?> _frame([Map<String, Object?> over = const {}]) => {
      'type': 'canvas.screen_annotation.updated',
      'channel_id': 'c',
      'user_id': 'viewer',
      'target_user_id': 'sharer',
      'kind': 'stroke',
      'annotation_id': 'a1',
      'points': [0.25, 0.5, 0.75, 1],
      'color': 'red',
      'ended': false,
      'allowed': false,
      ...over,
    };

void main() {
  test('parses a stroke with its normalised points', () {
    final event = ServerEvent.parse(jsonEncode(_frame()));
    final a = event as CanvasScreenAnnotation;
    expect((a.userId, a.targetUserId, a.kind), ('viewer', 'sharer', 'stroke'));
    expect(a.points, [0.25, 0.5, 0.75, 1.0]);
    expect((a.annotationId, a.color, a.ended), ('a1', 'red', false));
  });

  test('parses a consent frame with the screen shape', () {
    final event = ServerEvent.parse(
      jsonEncode(
        _frame({
          'kind': 'consent',
          'annotation_id': null,
          'points': <double>[],
          'allowed': true,
          'aspect': 1.7778,
        }),
      ),
    );
    final a = event as CanvasScreenAnnotation;
    expect(a.annotationId, isNull);
    expect((a.allowed, a.aspect), (true, 1.7778));
  });

  test('a frame with no target is not an annotation', () {
    final event = ServerEvent.parse(
      jsonEncode(_frame({'target_user_id': null})),
    );
    expect(event, isNot(isA<CanvasScreenAnnotation>()));
  });
}
