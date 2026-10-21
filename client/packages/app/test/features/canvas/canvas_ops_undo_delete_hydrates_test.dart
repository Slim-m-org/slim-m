// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Undoing a delete places the image again under a new id, and nothing else
/// tells the hydrator about it, so the controller has to.
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_ops_rig.dart';

Map<String, dynamic> _row(String id, {Map<String, dynamic>? body}) => {
  'id': id,
  'kind': 'image',
  'z_index': 1,
  'x': 100.0,
  'y': 100.0,
  'w': 40.0,
  'h': 20.0,
  'props': body?['props'] ?? {'attachment': 'sha-a'},
  'author_id': 'me',
  'seq': 9,
  'created_at': 0,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('undo of a deleted image asks for the new object bitmap', () async {
    final client = testApi((request) async {
      if (request.method == 'DELETE') return _json(_row('a'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _json(_row(body['id'] as String, body: body));
    });
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    final placed = <api.CanvasObject>[];
    final ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: plainCommitQueue(client),
      onError: (_) {},
      onObjectPlaced: placed.add,
    );
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'a',
          seq: 5,
          zIndex: 1,
          x: 100,
          y: 100,
          w: 40,
          h: 20,
          points: [],
          width: 0,
          colorKey: 'annotation',
          authorId: 'me',
          kind: CanvasObjectKind.image,
        ),
      )
      ..refresh();

    await ops.deleteSelected('a');
    await ops.undo();

    expect(placed.single.kind, 'image');
    expect(placed.single.id, isNot('a'));
    expect(placed.single.props['attachment'], 'sha-a');
  });
}
