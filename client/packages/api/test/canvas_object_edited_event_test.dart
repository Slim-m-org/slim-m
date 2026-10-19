// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `canvas.object.edited`, and [CanvasOp.fromJson]'s
/// `edit` case in the catch-up feed.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed canvas.object.edited frame', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.object.edited',
        'channel_id': 'chan-1',
        'seq': 9,
        'op_id': 'op-1',
        'object_id': 'obj-1',
        'props': {'text': '**hi** @alice'},
      }),
    );

    expect(event, isA<CanvasObjectEdited>());
    final edited = event as CanvasObjectEdited;
    expect(edited.channelId, 'chan-1');
    expect(edited.seq, 9);
    expect(edited.opId, 'op-1');
    expect(edited.objectId, 'obj-1');
    expect(edited.props['text'], '**hi** @alice');
  });

  test('a frame without props is ignored, not thrown', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.object.edited',
        'channel_id': 'chan-1',
        'seq': 9,
        'op_id': 'op-1',
        'object_id': 'obj-1',
      }),
    );

    expect(event, isNull);
  });

  test('a canvas op feed row of kind edit parses to CanvasEditOp', () {
    final op = CanvasOp.fromJson({
      'seq': 7,
      'id': 'op-2',
      'actor_id': 'user-1',
      'created_at': 1000,
      'kind': 'edit',
      'object_id': 'obj-2',
      'props': {'text': 'changed'},
    });

    expect(op, isA<CanvasEditOp>());
    final edit = op as CanvasEditOp;
    expect(edit.objectId, 'obj-2');
    expect(edit.props['text'], 'changed');
  });
}
