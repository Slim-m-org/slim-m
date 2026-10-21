// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Canvas history and ops lose no work: chunked removes, one grouped
/// bring-in step, skipped dead entries, the eraser's cap and sweep, and a
/// rollback that never overwrites newer state.
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _object(
  String id, {
  CanvasObjectKind kind = CanvasObjectKind.stroke,
  double x = 100,
  double y = 100,
}) => CanvasStrokeInput(
  id: id,
  seq: 5,
  zIndex: 1,
  x: x,
  y: y,
  w: kind == CanvasObjectKind.stroke ? 40 : 300,
  h: kind == CanvasObjectKind.stroke ? 0 : 200,
  points: kind == CanvasObjectKind.stroke ? const [0, 0, 40, 0] : const [],
  width: 3,
  colorKey: 'annotation',
  authorId: 'me',
  kind: kind,
  shapeKind: kind == CanvasObjectKind.shape ? CanvasShapeKind.rectangle : null,
);

class _Rig {
  _Rig({this.reply, Set<String> locked = const {}}) {
    final client = testApi(
      (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        final custom = reply?.call(body, requests.length);
        if (custom != null) return custom;
        return http.Response(
          jsonEncode({
            'op': {
              'id': 'op-${requests.length}',
              'seq': requests.length,
              'kind': body['kind'],
              'affected': (body['object_ids'] as List?)?.length ?? 1,
              'created_at': 0,
            },
            'fresh': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
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
      isLocked: locked.contains,
    );
  }

  final http.Response? Function(Map<String, dynamic> body, int n)? reply;
  final CanvasDocument document = CanvasDocument()
    ..setViewport(const Size(800, 600))
    ..setBoard(canvasBoard);
  late final CanvasCommitQueue commits;
  late final CanvasOpsController ops;
  final requests = <Map<String, dynamic>>[];
  final errors = <String>[];

  void place(
    String id, {
    CanvasObjectKind kind = CanvasObjectKind.stroke,
    double x = 100,
  }) => document
    ..applyPlaced(_object(id, kind: kind, x: x))
    ..refresh();

  Iterable<Map<String, dynamic>> ofKind(String kind) =>
      requests.where((r) => r['kind'] == kind);
}

http.Response _status(int code, [Map<String, String> headers = const {}]) =>
    http.Response(
      '{}',
      code,
      headers: {'content-type': 'application/json', ...headers},
    );

void main() {
  test(
    'undoing a gesture of 70 segments removes them in chunks of 64',
    () async {
      final rig = _Rig();
      final ids = [for (var i = 0; i < 70; i++) 's$i'];
      ids.forEach(rig.place);
      rig.ops.recordDraw(ids);

      await rig.ops.undo();

      final removes = rig.ofKind('remove').toList();
      expect(removes.map((r) => (r['object_ids'] as List).length), [64, 6]);
      expect(rig.errors, isEmpty);
      expect(rig.ops.canUndo, isFalse);
    },
  );

  test('a throttled undo retries the same op and then succeeds', () async {
    final rig = _Rig(
      reply: (body, n) => n == 1 ? _status(429, {'retry-after': '0'}) : null,
    )..place('a');
    rig.ops.recordDraw(['a']);

    await rig.ops.undo();

    final removes = rig.ofKind('remove').toList();
    expect(removes, hasLength(2));
    expect(removes[0]['id'], removes[1]['id']);
    expect(rig.errors, isEmpty);
    expect(rig.ops.canRedo, isTrue);
  });

  test('undo right after redo still removes the restored ink', () async {
    final rig = _Rig()..place('a');
    rig.ops.recordDraw(['a']);
    await rig.ops.undo();
    await rig.ops.redo();
    rig.requests.clear();

    await rig.ops.undo();

    expect(rig.ofKind('remove'), hasLength(1));
  });

  test('undo steps over a gesture whose ink is already gone', () async {
    final rig = _Rig()
      ..place('a')
      ..place('b');
    rig.ops
      ..recordDraw(['a'])
      ..recordDraw(['b']);
    rig.document
      ..kill('b')
      ..refresh();

    await rig.ops.undo();

    final removes = rig.ofKind('remove').toList();
    expect(removes.single['object_ids'], ['a']);
  });

  test('a remove the server skipped does not push an undo entry', () async {
    final rig = _Rig(
      reply: (body, n) => http.Response(
        jsonEncode({
          'op': {
            'id': 'x',
            'seq': 1,
            'kind': 'remove',
            'affected': 0,
            'created_at': 0,
          },
          'fresh': true,
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    )..place('a', kind: CanvasObjectKind.shape);

    await rig.ops.deleteSelected('a');

    expect(rig.ops.canUndo, isFalse);
  });

  test('delete does nothing to a locked object', () async {
    final rig = _Rig(locked: {'a'})..place('a', kind: CanvasObjectKind.shape);

    await rig.ops.deleteSelected('a');

    expect(rig.requests, isEmpty);
    expect(rig.document.isAlive('a'), isTrue);
  });

  test('an eraser drag past 64 objects keeps erasing', () async {
    final rig = _Rig();
    for (var i = 0; i < 80; i++) {
      rig.document.applyPlaced(
        CanvasStrokeInput(
          id: 's$i',
          seq: 1,
          zIndex: 1,
          x: 100,
          y: 100.0 + i * 8,
          w: 40,
          h: 0,
          points: const [0, 0, 40, 0],
          width: 3,
          colorKey: 'annotation',
          authorId: 'me',
        ),
      );
    }
    rig.document.refresh();

    for (var i = 0; i < 80; i++) {
      rig.ops.onErasePoint(
        Offset(120, 100.0 + i * 8),
        manageCanvas: false,
        selfId: 'me',
      );
    }
    await rig.ops.endErase();

    final erased = rig.ofKind('remove').expand((r) => r['object_ids'] as List);
    expect(erased.toSet(), hasLength(80));
    expect(
      [for (var i = 0; i < 80; i++) rig.document.isAlive('s$i')].any((a) => a),
      isFalse,
    );
  });

  test(
    'bringing 40 objects in is one undo step and leaves earlier history',
    () async {
      final rig = _Rig();
      rig.place('drawn');
      rig.ops.recordDraw(['drawn']);
      for (var i = 0; i < 40; i++) {
        rig.place('far$i', kind: CanvasObjectKind.shape, x: 1800);
      }

      final result = await rig.ops.bringIntoBoard(
        manageCanvas: false,
        selfId: 'me',
      );
      expect(result.moved, 40);
      rig.requests.clear();

      await rig.ops.undo();

      expect(rig.ofKind('move'), hasLength(40));
      expect(
        rig.ops.canUndo,
        isTrue,
        reason: 'the earlier draw is still there',
      );
    },
  );

  test('bring-in retries a throttled move instead of stopping', () async {
    final rig = _Rig(
      reply: (body, n) => n == 1 ? _status(429, {'retry-after': '0'}) : null,
    )..place('far', kind: CanvasObjectKind.shape, x: 1800);

    final result = await rig.ops.bringIntoBoard(
      manageCanvas: false,
      selfId: 'me',
    );

    expect(result.moved, 1);
    expect(result.failed, isFalse);
  });

  test('a refused move does not overwrite a newer remote position', () async {
    final rig = _Rig(reply: (body, n) => _status(403))
      ..place('a', kind: CanvasObjectKind.shape);
    rig.ops.beginSelect(
      const Offset(150, 150),
      manageCanvas: false,
      selfId: 'me',
    );
    rig.ops.dragSelect(const Offset(250, 250), lockAspect: true);
    rig.document
      ..moveObject('a', 500, 500, 300, 200)
      ..refresh();

    await rig.ops.endSelect();

    expect(rig.document.objectBounds('a')!.x, 500);
    expect(rig.errors, isNotEmpty);
  });

  test('a scoped clear an older server rejects says so', () async {
    final rig = _Rig(reply: (body, n) => _status(400));

    final ok = await rig.ops.clear(
      3,
      scope: const api.CanvasClearScope(kinds: ['stroke']),
    );

    expect(ok, isFalse);
    expect(rig.errors.single, contains('cannot clear by type'));
  });
}
