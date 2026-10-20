// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The undo ledger, the eraser's authorship scoping, and the clear control -
/// driven directly against `CanvasOpsController` and a real
/// `CanvasCommitQueue`, rather than through the widget tree.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
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

/// A stroke input placed straight onto the document, bypassing the queue -
/// standing in for ink the pane already fetched or already confirmed.
CanvasStrokeInput _liveStroke(
  String id, {
  double x = 0,
  double y = 0,
  String? authorId,
}) => CanvasStrokeInput(
  id: id,
  seq: 5,
  zIndex: 5,
  x: x,
  y: y,
  w: 100,
  h: 0,
  points: const [0, 0, 100, 0],
  width: 3,
  colorKey: 'annotation',
  authorId: authorId,
);

class _Harness {
  _Harness() {
    final api.SlimmApi client = testApi(
      (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (request.url.path.endsWith('/canvas/objects')) {
          placeRequests.add(body);
          return onPlace(body);
        }
        opRequests.add(body);
        return onOp(body);
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
      onPlaced: (object) {
        final input = CanvasStrokeInput(
          id: object.id,
          seq: object.seq,
          zIndex: object.zIndex,
          x: object.x,
          y: object.y,
          w: object.w,
          h: object.h,
          points: (object.props['points'] as List)
              .cast<num>()
              .map((n) => n.toDouble())
              .toList(),
          width: 3,
          colorKey: 'annotation',
          authorId: object.authorId,
        );
        document.applyPlaced(input);
        document.refresh();
      },
      onFailed: (id, message) {
        document
          ..kill(id)
          ..refresh();
      },
      onRemoved: (id) {
        document
          ..removeObject(id)
          ..refresh();
      },
      onEraseOnConfirm: (id) => ops.eraseOnConfirm(id),
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
  final List<Map<String, dynamic>> placeRequests = [];
  final List<Map<String, dynamic>> opRequests = [];
  final List<String> errors = [];
  var _opSeq = 0;

  http.Response Function(Map<String, dynamic>) onPlace = (body) => _json({
    ...body,
    'kind': 'stroke',
    'z_index': 1,
    'author_id': 'me',
    'seq': 1,
    'created_at': 0,
  });

  late http.Response Function(Map<String, dynamic>) onOp = (body) {
    _opSeq++;
    return _json({
      'op': {
        'id': 'server-op-$_opSeq',
        'seq': _opSeq,
        'kind': body['kind'],
        'affected': 1,
        'created_at': 0,
      },
      'fresh': true,
    });
  };

  /// Places a stroke through the real queue and drains it, so the document
  /// and the queue agree the id has genuinely committed.
  void commitOne(String id) {
    document.applyPlaced(_liveStroke(id, authorId: 'me'));
    commits.add(
      CanvasCommit(
        id: id,
        x: 0,
        y: 0,
        w: 100,
        h: 0,
        props: const {
          'points': [0.0, 0.0, 100.0, 0.0],
        },
      ),
    );
  }
}

void main() {
  test('canUndo is false with nothing recorded', () {
    final harness = _Harness();
    expect(harness.ops.canUndo, isFalse);
  });

  test('undo of an already-committed draw issues one remove op naming '
      'exactly that gesture\'s ids', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.commitOne('a');
      harness.commitOne('b');
      async.flushMicrotasks();
      harness.ops.recordDraw(['a', 'b']);
      expect(harness.ops.canUndo, isTrue);

      unawaited(harness.ops.undo());
      async.flushMicrotasks();

      expect(harness.opRequests, hasLength(1));
      expect(harness.opRequests.single['kind'], 'remove');
      expect(harness.opRequests.single['object_ids'], ['a', 'b']);
      expect(harness.ops.canUndo, isFalse);
    });
  });

  test('undo of a still-unsent gesture cancels the placements and issues '
      'no op', () {
    fakeAsync((async) {
      final harness = _Harness();
      // A held commit occupies the in-flight slot so 'a' stays pending.
      harness.commitOne('held');
      harness.document.applyPlaced(_liveStroke('a', x: 20, authorId: 'me'));
      harness.commits.add(
        CanvasCommit(
          id: 'a',
          x: 20,
          y: 0,
          w: 100,
          h: 0,
          props: const {
            'points': [0.0, 0.0, 100.0, 0.0],
          },
        ),
      );
      harness.ops.recordDraw(['a']);

      unawaited(harness.ops.undo());
      async.flushMicrotasks();

      expect(
        harness.opRequests,
        isEmpty,
        reason: 'a never-sent placement has nothing to remove server-side',
      );
      expect(harness.document.isAlive('a'), isFalse);
    });
  });

  test('undo of an in-flight gesture erases on confirm, not before', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_liveStroke('a', authorId: 'me'));
      harness.commits.add(
        CanvasCommit(
          id: 'a',
          x: 0,
          y: 0,
          w: 100,
          h: 0,
          props: const {
            'points': [0.0, 0.0, 100.0, 0.0],
          },
        ),
      );
      harness.ops.recordDraw(['a']);

      unawaited(harness.ops.undo());
      expect(
        harness.opRequests,
        isEmpty,
        reason: 'issuing the op before the placement lands would 404',
      );
      expect(
        harness.document.isAlive('a'),
        isFalse,
        reason: 'removed from view at once, regardless of server timing',
      );

      async.flushMicrotasks();
      expect(harness.opRequests, hasLength(1));
      expect(harness.opRequests.single['kind'], 'remove');
      expect(harness.opRequests.single['object_ids'], ['a']);
    });
  });

  test('the eraser collects no foreign ink when manageCanvas is false', () {
    final harness = _Harness();
    harness.document
      ..applyPlaced(_liveStroke('foreign', authorId: 'someone-else'))
      ..refresh();

    harness.ops.onErasePoint(
      const Offset(50, 0),
      manageCanvas: false,
      selfId: 'me',
    );

    expect(
      harness.document.isAlive('foreign'),
      isTrue,
      reason:
          'without MANAGE_CANVAS the eraser must not touch another '
          'member\'s ink',
    );
  });

  test('the eraser erases foreign ink when manageCanvas is true', () {
    final harness = _Harness();
    harness.document
      ..applyPlaced(_liveStroke('foreign', authorId: 'someone-else'))
      ..refresh();

    harness.ops.onErasePoint(
      const Offset(50, 0),
      manageCanvas: true,
      selfId: 'me',
    );

    expect(harness.document.isAlive('foreign'), isFalse);
  });

  test('a drag erasing several objects submits exactly one batched op', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document
        ..applyPlaced(_liveStroke('a', x: 0, authorId: 'me'))
        ..applyPlaced(_liveStroke('b', x: 200, authorId: 'me'))
        ..refresh();

      harness.ops
        ..onErasePoint(const Offset(50, 0), manageCanvas: false, selfId: 'me')
        ..onErasePoint(const Offset(250, 0), manageCanvas: false, selfId: 'me');
      expect(harness.document.isAlive('a'), isFalse);
      expect(harness.document.isAlive('b'), isFalse);

      unawaited(harness.ops.endErase());
      async.flushMicrotasks();

      expect(harness.opRequests, hasLength(1));
      expect(harness.opRequests.single['kind'], 'remove');
      expect(harness.opRequests.single['object_ids'], ['a', 'b']);
      expect(harness.ops.canUndo, isTrue);
    });
  });

  test('ending an erase drag that collected nothing submits no op', () {
    fakeAsync((async) {
      final harness = _Harness();
      unawaited(harness.ops.endErase());
      async.flushMicrotasks();
      expect(harness.opRequests, isEmpty);
    });
  });

  test('a scoped clear goes out as its own kind, never as clear', () {
    fakeAsync((async) {
      final harness = _Harness();
      unawaited(
        harness.ops.clear(
          10,
          scope: const api.CanvasClearScope(kinds: ['stroke']),
        ),
      );
      async.flushMicrotasks();

      expect(harness.opRequests.single['kind'], 'clear_scoped');
      expect(harness.opRequests.single['kinds'], ['stroke']);
    });
  });

  test('clear removes local ink at or below the fencing seq and can be '
      'undone by restoring it', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document
        ..applyPlaced(_liveStroke('old'))
        ..refresh();

      unawaited(harness.ops.clear(10));
      async.flushMicrotasks();

      expect(harness.opRequests.single['kind'], 'clear');
      expect(harness.opRequests.single['before_seq'], 10);
      expect(harness.document.isAlive('old'), isFalse);
      expect(harness.ops.canUndo, isTrue);

      unawaited(harness.ops.undo());
      async.flushMicrotasks();
      expect(harness.opRequests, hasLength(2));
      expect(harness.opRequests[1]['kind'], 'restore');
      expect(harness.opRequests[1]['target_op'], 'server-op-1');
    });
  });

  test('a clear that fails reports an error and pushes no undo entry', () {
    fakeAsync((async) {
      final harness = _Harness()..onOp = (_) => _json({'error': 'nope'}, 403);

      unawaited(harness.ops.clear(10));
      async.flushMicrotasks();

      expect(harness.errors, ['The canvas could not be cleared.']);
      expect(harness.ops.canUndo, isFalse);
    });
  });

  test('a scoped clear posts its scope and removes only that author', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document
        ..applyPlaced(_liveStroke('ann-ink', authorId: 'ann'))
        ..applyPlaced(_liveStroke('bob-ink', x: 200, authorId: 'bob'))
        ..refresh();

      unawaited(
        harness.ops.clear(
          10,
          scope: const api.CanvasClearScope(kinds: ['stroke'], authorId: 'ann'),
        ),
      );
      async.flushMicrotasks();

      expect(harness.opRequests.single['kinds'], ['stroke']);
      expect(harness.opRequests.single['author_id'], 'ann');
      expect(harness.document.isAlive('ann-ink'), isFalse);
      expect(harness.document.isAlive('bob-ink'), isTrue);
      expect(harness.ops.canUndo, isTrue);
    });
  });

  test('an unscoped clear posts no scope fields', () {
    fakeAsync((async) {
      final harness = _Harness();
      unawaited(harness.ops.clear(10));
      async.flushMicrotasks();

      expect(harness.opRequests.single.containsKey('kinds'), isFalse);
      expect(harness.opRequests.single.containsKey('author_id'), isFalse);
    });
  });
}
