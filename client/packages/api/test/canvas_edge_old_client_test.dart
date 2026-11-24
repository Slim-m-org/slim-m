// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a client built before connections does with them (decision 0137), read through the frozen 0.114 parser so a later parser change cannot hide a regression.
///
/// The shipped client is client-v0.136.0: `canvas_object_inputs.dart:23` answers `_ => null` for a kind it does not draw, `canvas_sync.dart:364-365` skips a null input, and `canvas_engine.dart:446-447` returns on one.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

import 'fixtures/old_canvas_ops_0_114.dart' as old;

const _edge = {
  'id': 'e1',
  'kind': 'edge',
  'z_index': 4,
  'x': 0.0,
  'y': 0.0,
  'w': 400.0,
  'h': 50.0,
  'props': {
    'from': {'object_id': 'a'},
    'to': {'object_id': 'b', 'side': 'left'},
    'arrow': 'end',
  },
  'author_id': 'u1',
  'seq': 4,
  'created_at': 0,
};

void main() {
  test(
      'an old parser reads a place op of an edge as an object with an unknown kind',
      () {
    final op = old.CanvasOp.fromJson({
      'seq': 4,
      'id': 'op',
      'actor_id': 'u1',
      'created_at': 0,
      'kind': 'place',
      'object': _edge,
    });
    expect((op as old.CanvasPlaceOp).object?.kind, 'edge');
  });

  test('an old parser reads a remove that names ids it never held', () {
    final op = old.CanvasOp.fromJson({
      'seq': 9,
      'id': 'op',
      'actor_id': 'u1',
      'created_at': 0,
      'kind': 'remove',
      'object_ids': ['never-held-1', 'never-held-2'],
    });
    expect(
        (op as old.CanvasRemoveOp).objectIds, ['never-held-1', 'never-held-2']);
  });

  test(
      'the current parser keeps an edge as a plain object whose props stay opaque',
      () {
    final object = CanvasObject.fromJson(_edge);
    expect(object.kind, 'edge');
    expect(object.props['to'], {'object_id': 'b', 'side': 'left'});
  });

  test('an edit op with a null prop parses, since a merge deletes by null', () {
    final op = CanvasOp.fromJson({
      'seq': 5,
      'id': 'op',
      'actor_id': 'u1',
      'created_at': 0,
      'kind': 'edit',
      'object_id': 'e1',
      'props': {'label': null},
    });
    expect((op as CanvasEditOp).props, {'label': null});
  });

  test('/version carries canvas_edges and an older server reads as false', () {
    Version parse(Map<String, dynamic> extra) => Version.fromJson({
          'name': 'slim-m',
          'version': '0.118.0',
          'protocol': 1,
          ...extra,
        });
    expect(parse({'canvas_edges': true}).canvasEdges, isTrue);
    expect(parse({}).canvasEdges, isFalse);
  });
}
