// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scoped clear on the wire. It travels under its own frame type and feed
/// kind so a client that predates scopes never reads it as clear-everything.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

import 'fixtures/old_canvas_ops_0_114.dart' as old;

const _scopedRow = {
  'seq': 7,
  'id': 'op-2',
  'actor_id': 'user-1',
  'created_at': 1000,
  'kind': 'clear_scoped',
  'before_seq': 6,
  'kinds': ['image'],
};

void main() {
  test('canvas.cleared stays a whole-canvas clear', () {
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

  test('canvas.cleared_scoped carries its kinds and author', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'canvas.cleared_scoped',
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
  });

  test('a clear_scoped feed row parses its scope', () {
    final scope = (CanvasOp.fromJson(_scopedRow) as CanvasClearOp).scope;

    expect(scope.kinds, ['image']);
    expect(scope.authorId, isNull);
  });

  test('a plain clear feed row is a whole-canvas clear', () {
    final op = CanvasOp.fromJson({..._scopedRow, 'kind': 'clear'});

    expect((op as CanvasClearOp).scope.isEverything, isTrue);
  });

  // The 0.114 parser is copied verbatim into test/fixtures; it clears on `clear` and resyncs on unknown.
  test('0.114 reads a scoped feed row as an unknown op, never a clear', () {
    final op = old.CanvasOp.fromJson(_scopedRow);

    expect(op, isA<old.CanvasUnknownOp>());
    expect(op, isNot(isA<old.CanvasClearOp>()));
  });
}
