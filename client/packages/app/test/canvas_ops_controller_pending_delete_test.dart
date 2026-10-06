// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Deleting a stroke that is still being saved goes through the placement
/// queue the way the eraser and undo do: a stroke not yet sent is cancelled, a
/// stroke in flight is removed once it lands, and nothing is left on the
/// server that the author no longer sees.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_commit_queue.dart';
import 'package:slimm_app/src/screens/canvas/canvas_ops_controller.dart';
import 'package:slimm_app/src/screens/canvas/canvas_sync.dart'
    show canvasStrokeInputFrom;
import 'package:slimm_voice_canvas/voice_canvas.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

CanvasStrokeInput _stroke(String id) => CanvasStrokeInput(
  id: id,
  seq: 0,
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

CanvasCommit _commit(String id) => CanvasCommit(
  id: id,
  x: 100,
  y: 100,
  w: 40,
  h: 0,
  props: const {
    'points': [0.0, 0.0, 40.0, 0.0],
  },
);

/// A tiny server: a placement waits on its own gate, a remove 404s for an id
/// the server has not received.
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
        if (request.url.path.endsWith('/canvas/objects')) {
          final id = body['id'] as String;
          placeRequests.add(id);
          await placeGate.future;
          serverObjects.add(id);
          return _json({
            ...body,
            'z_index': 1,
            'author_id': 'me',
            'seq': 9,
            'created_at': 0,
          });
        }
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
      onPlaced: (object) {
        final input = canvasStrokeInputFrom(object);
        if (input != null) {
          document
            ..applyPlaced(input)
            ..refresh();
        }
      },
      onFailed: (_, _) {},
      onRemoved: (_) {},
      onEraseOnConfirm: (id) => unawaited(ops.eraseOnConfirm(id)),
      timedOutUntil: () => null,
    );
    ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: commits,
      onError: errors.add,
    );
  }

  final CanvasDocument document = CanvasDocument()
    ..setViewport(const Size(800, 600));
  late final CanvasCommitQueue commits;
  late final CanvasOpsController ops;
  final List<String> errors = [];
  final List<String> placeRequests = [];
  final Set<String> serverObjects = {};
  Completer<void> placeGate = Completer<void>();

  void addPending(String id) {
    document
      ..applyPlaced(_stroke(id))
      ..refresh();
    commits.add(_commit(id));
  }

  Future<void> landPlacements() async {
    placeGate.complete();
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test('deleting the stroke in flight removes it once it lands', () async {
    final h = _Harness()..addPending('s');
    await pumpEventQueue();

    await h.ops.deleteSelected('s');
    await h.landPlacements();

    expect(h.errors, isEmpty);
    expect(h.document.isAlive('s'), isFalse);
    expect(h.serverObjects, isNot(contains('s')));
  });

  test('deleting a stroke not yet sent never sends it', () async {
    final h = _Harness()
      ..addPending('first')
      ..addPending('second');
    await pumpEventQueue();

    await h.ops.deleteSelected('second');
    await h.landPlacements();

    expect(h.errors, isEmpty);
    expect(h.placeRequests, ['first']);
    expect(h.serverObjects, isNot(contains('second')));
    expect(h.document.isAlive('second'), isFalse);
  });

  test('deleting a landed object still sends an ordinary remove', () async {
    final h = _Harness();
    h.serverObjects.add('a');
    h.document
      ..applyPlaced(_stroke('a'))
      ..refresh();

    await h.ops.deleteSelected('a');

    expect(h.errors, isEmpty);
    expect(h.serverObjects, isNot(contains('a')));
    expect(h.ops.canUndo, isTrue);
  });
}
