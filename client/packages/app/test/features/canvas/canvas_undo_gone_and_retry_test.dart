// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An undo entry whose object another client deleted is dropped so the stack
/// keeps moving, and a half-failed undo of a delete places each row once.
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_ops_rig.dart';

CanvasStrokeInput _note(String id, String text) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 120,
  h: 80,
  points: const [],
  width: 0,
  colorKey: 'note',
  authorId: 'me',
  kind: CanvasObjectKind.note,
  text: text,
);

CanvasStrokeInput _piece(String id, double x) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: x,
  y: 0,
  w: 100,
  h: 0,
  points: const [0, 0, 100, 0],
  width: 3,
  colorKey: 'annotation',
  authorId: 'me',
  groupId: 'g',
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _row(String id, double x) => {
  'id': id,
  'kind': 'stroke',
  'z_index': 1,
  'x': x,
  'y': 0.0,
  'w': 100.0,
  'h': 0.0,
  'props': {
    'points': [0.0, 0.0, 100.0, 0.0],
    'width': 3.0,
    'color': 'annotation',
  },
  'author_id': 'me',
  'seq': 9,
  'created_at': 0,
};

void main() {
  test('undo skips an entry whose note was deleted elsewhere', () async {
    final gone = <String>{};
    final errors = <String>[];
    final edits = <String>[];
    final client = testApi((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final id = body['object_id'] as String?;
      if (gone.contains(id)) return _json({'error': 'not found'}, 404);
      edits.add(id!);
      return acceptedOp(n: edits.length, kind: body['kind'], affected: 1);
    });
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    final ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: plainCommitQueue(client),
      onError: errors.add,
    );
    document
      ..applyPlaced(_note('m', 'm0'))
      ..applyPlaced(_note('n', 'n0'))
      ..refresh();
    await ops.editNote('m', 'm1');
    await ops.editNote('n', 'n1');
    await ops.editNote('n', 'n2');
    gone.add('n');
    edits.clear();

    await ops.undo();

    expect(edits, ['m'], reason: 'the entries for the gone note are dropped');
    expect(document.noteTextOf('m'), 'm0');
    expect(errors, isEmpty);
  });

  test(
    'retrying a half-failed undo of a delete places each row once',
    () async {
      var places = 0;
      var failNext = false;
      final errors = <String>[];
      final client = testApi((request) async {
        if (request.method == 'DELETE') {
          final id = request.url.pathSegments.last;
          return _json(
            _row(
              id,
              id == 'a'
                  ? 0
                  : id == 'b'
                  ? 100
                  : 200,
            ),
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (failNext && body['x'] == 200.0) {
          failNext = false;
          return _json({'error': 'down'}, 403);
        }
        places++;
        return _json(_row(body['id'] as String, (body['x'] as num).toDouble()));
      });
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      final ops = CanvasOpsController(
        channelId: 'c1',
        client: client,
        document: document,
        commits: plainCommitQueue(client),
        onError: errors.add,
      );
      document
        ..applyPlaced(_piece('a', 0))
        ..applyPlaced(_piece('b', 100))
        ..applyPlaced(_piece('c', 200))
        ..refresh();
      await ops.deleteSelected('a');
      failNext = true;

      await ops.undo();
      expect(errors, isNotEmpty);
      await ops.undo();

      expect(places, 3, reason: 'two rows, then the one that failed');
    },
  );
}
