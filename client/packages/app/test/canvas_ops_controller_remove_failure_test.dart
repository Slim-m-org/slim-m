// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A remove the server refuses (403, 5xx, a network blip, a 429) must not
/// leave the object hidden here for the rest of the session while it still
/// exists for everyone else: the document forgets the tombstone and the pane
/// is asked to read the region again, the same recovery a restore uses.
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_commit_queue.dart';
import 'package:slimm_app/src/screens/canvas/canvas_ops_controller.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

CanvasStrokeInput _stroke(String id, {int seq = 5}) => CanvasStrokeInput(
  id: id,
  seq: seq,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 40,
  h: 0,
  points: const [0, 0, 40, 0],
  width: 4,
  colorKey: 'annotation',
  authorId: 'me',
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

/// A tiny in-memory server: remove 404s for an unknown id.
class _Harness {
  _Harness() {
    final client = api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        removeRequests.add(body);
        if (removeStatus != 200) return _json({'error': 'nope'}, removeStatus);
        final ids = (body['object_ids'] as List).cast<String>();
        if (ids.any((id) => !serverObjects.contains(id))) {
          return _json({'error': 'not found'}, 404);
        }
        serverObjects.removeAll(ids);
        return _json({
          'op': {
            'id': 'op1',
            'seq': 10,
            'kind': 'remove',
            'affected': ids.length,
            'created_at': 0,
          },
          'fresh': true,
        });
      }),
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
  test('a failed delete of the selection brings the object back', () async {
    final h = _Harness()..removeStatus = 403;
    h.serverObjects.add('a');
    h.document
      ..applyPlaced(_image('a'))
      ..refresh();

    await h.ops.deleteSelected('a');

    expect(h.errors, ['That could not be deleted.']);
    expect(h.refetches, 1, reason: 'the pane is asked to read the region');
    expect(
      h.document.applyPlaced(_image('a')),
      isNotNull,
      reason: 'the tombstone is gone, so the fetch can place it again',
    );
  });

  test('a failed eraser drag brings the stroke back', () async {
    final h = _Harness()..removeStatus = 403;
    h.serverObjects.add('s');
    h.document
      ..applyPlaced(_stroke('s'))
      ..refresh();
    h.ops.onErasePoint(
      const Offset(120, 100),
      manageCanvas: false,
      selfId: 'me',
    );

    await h.ops.endErase();

    expect(h.errors, ['That stroke could not be erased.']);
    expect(h.refetches, 1);
    expect(h.document.applyPlaced(_stroke('s')), isNotNull);
  });

  test(
    'a failed undo of a draw brings the stroke back and keeps the entry',
    () async {
      final h = _Harness()..removeStatus = 403;
      h.serverObjects.add('s');
      h.document
        ..applyPlaced(_stroke('s'))
        ..refresh();
      h.ops.recordDraw(['s']);

      await h.ops.undo();

      expect(h.errors, isNotEmpty);
      expect(h.refetches, 1);
      expect(h.document.applyPlaced(_stroke('s')), isNotNull);
      expect(h.ops.canUndo, isTrue, reason: 'the undo can be tried again');
    },
  );

  test('a remove the server accepts asks for no refetch', () async {
    final h = _Harness();
    h.serverObjects.add('a');
    h.document
      ..applyPlaced(_image('a'))
      ..refresh();

    await h.ops.deleteSelected('a');

    expect(h.errors, isEmpty);
    expect(h.refetches, 0);
    expect(
      h.document.applyPlaced(_image('a')),
      isNull,
      reason: 'stays removed',
    );
  });
}
