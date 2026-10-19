// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scoped clear on the wire: the live `canvas.cleared` frame and the
/// catch-up feed row both carry the kinds and author the clear was limited to.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('canvas.cleared without a scope clears everything', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.cleared',
        'channel_id': 'c',
        'seq': 3,
        'op_id': 'op',
        'before_seq': 2,
      }),
    );

    expect((event as CanvasCleared).scope.isEverything, isTrue);
  });

  test('canvas.cleared carries its kinds and author', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.cleared',
        'channel_id': 'c',
        'seq': 3,
        'op_id': 'op',
        'before_seq': 2,
        'kinds': ['stroke', 'note'],
        'author_id': 'ann',
      }),
    );

    final scope = (event as CanvasCleared).scope;
    expect(scope.kinds, ['stroke', 'note']);
    expect(scope.authorId, 'ann');
    expect(scope.isEverything, isFalse);
  });

  test('a clear row of the catch-up feed parses its scope', () {
    final op = CanvasOp.fromJson({
      'seq': 7,
      'id': 'op-2',
      'actor_id': 'user-1',
      'created_at': 1000,
      'kind': 'clear',
      'before_seq': 6,
      'kinds': ['image'],
    });

    final scope = (op as CanvasClearOp).scope;
    expect(scope.kinds, ['image']);
    expect(scope.authorId, isNull);
  });
}
