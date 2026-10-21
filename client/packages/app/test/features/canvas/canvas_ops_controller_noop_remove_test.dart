// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A remove the server answers with `affected: 0` (a locked object, or one
/// another client already erased) changed nothing, so it must not hide the
/// object here for good nor push an undo entry whose restore would 404.
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

CanvasStrokeInput _image(String id) => CanvasStrokeInput(
  id: id,
  seq: 5,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 40,
  h: 20,
  points: const [],
  width: 0,
  colorKey: 'annotation',
  authorId: 'me',
  kind: CanvasObjectKind.image,
);

/// A server that skips every id, as it does for locked objects.
class _Harness {
  _Harness() {
    final client = testApi(
      (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        removeRequests.add(body);
        if (removeStatus != 200) return _json({'error': 'nope'}, removeStatus);
        final ids = (body['object_ids'] as List).cast<String>();
        if (ids.any((id) => !serverObjects.contains(id))) {
          return _json({'error': 'not found'}, 404);
        }
        return _json({
          'op': {
            'id': 'op1',
            'seq': 10,
            'kind': 'remove',
            'affected': 0,
            'created_at': 0,
          },
          'fresh': true,
        });
      },
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
    );
    commits = CanvasCommitQueue(
      client: client,
      channelId: 'c1',
      onPlaced: (_) {},
      onFailed: (_, _) {},
      onRemoved: (_) {},
      onEraseOnConfirm: (_) async {},
      timedOutUntil: () => null,
    );
    ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: commits,
      onError: errors.add,
      onRemoveFailed: () async => refetches++,
    );
  }

  final CanvasDocument document = CanvasDocument()
    ..setViewport(const Size(800, 600));
  late final CanvasCommitQueue commits;
  late final CanvasOpsController ops;
  final List<String> errors = [];
  final Set<String> serverObjects = {};
  final List<Map<String, dynamic>> removeRequests = [];
  int removeStatus = 200;
  int refetches = 0;
}

void main() {
  test('a delete that affected nothing pushes no undo entry', () async {
    final h = _Harness();
    h.serverObjects.add('a');
    h.document
      ..applyPlaced(_image('a'))
      ..refresh();

    await h.ops.deleteSelected('a');

    expect(h.ops.canUndo, isFalse, reason: 'undo would restore a phantom op');
  });

  test('a delete that affected nothing brings the object back', () async {
    final h = _Harness();
    h.serverObjects.add('a');
    h.document
      ..applyPlaced(_image('a'))
      ..refresh();

    await h.ops.deleteSelected('a');

    expect(h.refetches, 1, reason: 'the pane re-reads the region');
    expect(h.document.applyPlaced(_image('a')), isNotNull);
  });
}
