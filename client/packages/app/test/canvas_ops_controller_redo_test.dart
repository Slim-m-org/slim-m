// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Redo: each undo leaves its inverse behind, a fresh edit drops it, and the
/// inverse of a removal is a `restore` naming the removal so the server's own
/// fencing keeps a concurrent edit from being clobbered.
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

CanvasStrokeInput _object(
  String id, {
  CanvasObjectKind kind = CanvasObjectKind.image,
  int zIndex = 1,
}) => CanvasStrokeInput(
  id: id,
  seq: 5,
  zIndex: zIndex,
  x: 100,
  y: 100,
  w: 40,
  h: 20,
  points: const [],
  width: 0,
  colorKey: 'annotation',
  authorId: 'me',
  kind: kind,
);

class _Harness {
  _Harness() {
    final api.SlimmApi client = api.SlimmApi(
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
        opRequests.add(body);
        if (failNext) {
          failNext = false;
          return http.Response('{}', 500);
        }
        _opSeq++;
        return http.Response(
          jsonEncode({
            'op': {
              'id': 'server-op-$_opSeq',
              'seq': _opSeq,
              'kind': body['kind'],
              'affected': 1,
              'created_at': 0,
            },
            'fresh': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: CanvasCommitQueue(
        client: client,
        channelId: 'c1',
        onPlaced: (_) {},
        onFailed: (_, _) {},
        onRemoved: (_) {},
        onEraseOnConfirm: (_) async {},
        timedOutUntil: () => null,
      ),
      onError: errors.add,
    );
  }

  final CanvasDocument document = CanvasDocument()
    ..setViewport(const Size(800, 600));
  late final CanvasOpsController ops;
  final List<Map<String, dynamic>> opRequests = [];
  final List<String> errors = [];
  bool failNext = false;
  var _opSeq = 0;

  /// What a live restored frame does: forget the tombstone, bring it back.
  void restoreLocally(String id, {CanvasObjectKind? kind}) {
    document.forgetRemoved([id]);
    place(id, kind: kind);
  }

  void place(String id, {CanvasObjectKind? kind, int zIndex = 1}) => document
    ..applyPlaced(
      _object(id, kind: kind ?? CanvasObjectKind.image, zIndex: zIndex),
    )
    ..refresh();

  Future<void> drag(Offset from, Offset to) async {
    ops
      ..beginSelect(from, manageCanvas: false, selfId: 'me')
      ..dragSelect(to, lockAspect: true);
    await ops.endSelect();
  }
}

void main() {
  test('redo with nothing undone does nothing', () async {
    final harness = _Harness();
    expect(harness.ops.canRedo, isFalse);

    await harness.ops.redo();

    expect(harness.opRequests, isEmpty);
  });

  test('redoing an undone draw restores the removal that undid it', () async {
    final harness = _Harness()..place('a');
    harness.ops.recordDraw(['a']);

    await harness.ops.undo();
    expect(harness.opRequests.single['kind'], 'remove');
    expect(harness.ops.canRedo, isTrue);

    await harness.ops.redo();

    final redo = harness.opRequests.last;
    expect(redo['kind'], 'restore');
    expect(
      redo['target_op'],
      'server-op-1',
      reason: 'naming the removal keeps a later edit by someone else fenced',
    );
    expect(harness.opRequests, hasLength(2));
    expect(harness.ops.canRedo, isFalse);
    expect(harness.ops.canUndo, isTrue);
  });

  test('undo, redo, undo again removes the same object once more', () async {
    final harness = _Harness()..place('a');
    harness.ops.recordDraw(['a']);

    await harness.ops.undo();
    await harness.ops.redo();
    // The server's restored frame is what brings the object back locally.
    harness.restoreLocally('a');
    await harness.ops.undo();

    final last = harness.opRequests.last;
    expect(last['kind'], 'remove');
    expect(last['object_ids'], ['a']);
  });

  test('redoing an undone erase removes the same objects again', () async {
    final harness = _Harness()..place('a', kind: CanvasObjectKind.stroke);
    await harness.ops.deleteSelected('a');

    await harness.ops.undo();
    expect(harness.opRequests.last['kind'], 'restore');
    harness.restoreLocally('a', kind: CanvasObjectKind.stroke);
    expect(harness.document.isAlive('a'), isTrue);

    await harness.ops.redo();

    final redo = harness.opRequests.last;
    expect(redo['kind'], 'remove');
    expect(redo['object_ids'], ['a']);
    expect(harness.document.isAlive('a'), isFalse);
    expect(harness.ops.canUndo, isTrue);
  });

  test('a fresh edit after an undo drops the redo', () async {
    final harness = _Harness()
      ..place('a')
      ..place('b');
    harness.ops.recordDraw(['a']);
    await harness.ops.undo();
    expect(harness.ops.canRedo, isTrue);

    harness.ops.recordDraw(['b']);

    expect(harness.ops.canRedo, isFalse);
    await harness.ops.redo();
    expect(harness.opRequests, hasLength(1));
  });

  test('redoing an undone move puts the object back where it went', () async {
    final harness = _Harness()..place('a');
    await harness.drag(const Offset(120, 110), const Offset(220, 210));
    await harness.ops.undo();
    expect(harness.document.objectBounds('a')!.x, 100);

    await harness.ops.redo();

    final redo = harness.opRequests.last;
    expect(redo['kind'], 'move');
    expect(redo['x'], 200);
    expect(redo['y'], 200);
    expect(harness.document.objectBounds('a')!.x, 200);
    expect(harness.ops.canUndo, isTrue);
  });

  test('redoing an undone reorder resubmits the z_index it had', () async {
    final harness = _Harness()
      ..place('a')
      ..place('b', zIndex: 5);
    await harness.ops.bringToFront('a');
    final raisedTo = harness.opRequests.single['z_index'];
    await harness.ops.undo();

    await harness.ops.redo();

    final redo = harness.opRequests.last;
    expect(redo['kind'], 'reorder');
    expect(redo['z_index'], raisedTo);
  });

  test('a refused redo says so and leaves nothing to redo again', () async {
    final harness = _Harness()..place('a');
    harness.ops.recordDraw(['a']);
    await harness.ops.undo();
    harness.failNext = true;

    await harness.ops.redo();

    expect(harness.errors, ['That could not be redone.']);
    expect(harness.ops.canRedo, isFalse);
  });
}
