// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Resize (a corner-handle drag on the current selection) and reorder
/// (bring-to-front/send-to-back), driven directly against
/// `CanvasOpsController` and a real `CanvasCommitQueue`, the same shape
/// `canvas_ops_controller_test.dart` already uses for draw/erase/clear.
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
import '../../support/canvas_ops_rig.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

CanvasStrokeInput _image(
  String id, {
  double x = 100,
  double y = 100,
  double w = 40,
  double h = 20,
  int zIndex = 1,
  String? authorId = 'me',
}) => CanvasStrokeInput(
  id: id,
  seq: 5,
  zIndex: zIndex,
  x: x,
  y: y,
  w: w,
  h: h,
  points: const [],
  width: 0,
  colorKey: 'annotation',
  authorId: authorId,
  kind: CanvasObjectKind.image,
);

/// A straight horizontal stroke from (x, y) to (x + 40, y), so a tap
/// anywhere along that line is within `hitTestStroke`'s own tolerance.
CanvasStrokeInput _stroke(
  String id, {
  double x = 100,
  double y = 100,
  int zIndex = 1,
  String? authorId = 'me',
}) => CanvasStrokeInput(
  id: id,
  seq: 5,
  zIndex: zIndex,
  x: x,
  y: y,
  w: 40,
  h: 0,
  points: const [0, 0, 40, 0],
  width: 4,
  colorKey: 'annotation',
  authorId: authorId,
);

class _Harness {
  _Harness() {
    final api.SlimmApi client = testApi(
      (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
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
    commits = plainCommitQueue(client);
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
  final List<Map<String, dynamic>> opRequests = [];
  final List<String> errors = [];
  var _opSeq = 0;

  /// Overridable per test; defaults to a normal fresh, effective op.
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
}

void main() {
  test('selecting an image and dragging its body moves it', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a'));
      harness.document.refresh();

      harness.ops.beginSelect(
        const Offset(120, 110),
        manageCanvas: false,
        selfId: 'me',
      );
      expect(harness.document.selectedObjectId.value, 'a');

      harness.ops.dragSelect(const Offset(220, 210), lockAspect: true);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();

      expect(harness.opRequests.single['kind'], 'move');
      expect(harness.opRequests.single['x'], 200);
      expect(harness.opRequests.single['y'], 200);
      expect(
        harness.opRequests.single['w'],
        40,
        reason: 'a plain drag never resizes',
      );
      expect(harness.opRequests.single['h'], 20);
    });
  });

  test('tapping empty space clears the selection', () {
    final harness = _Harness();
    harness.document.applyPlaced(_image('a'));
    harness.document.refresh();
    harness.ops.beginSelect(
      const Offset(120, 110),
      manageCanvas: false,
      selfId: 'me',
    );
    expect(harness.document.selectedObjectId.value, 'a');

    harness.ops.beginSelect(
      const Offset(500, 500),
      manageCanvas: false,
      selfId: 'me',
    );
    expect(harness.document.selectedObjectId.value, isNull);
  });

  test('grabbing a handle on the selection resizes instead of moving', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a'));
      harness.document.refresh();
      harness.document.selectedObjectId.value = 'a';

      // The bottom-right corner of the 100,100,40,20 box is 140,120.
      harness.ops.beginSelect(
        const Offset(140, 120),
        manageCanvas: false,
        selfId: 'me',
      );
      harness.ops.dragSelect(const Offset(180, 140), lockAspect: false);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();

      expect(harness.opRequests.single['kind'], 'move');
      expect(
        harness.opRequests.single['x'],
        100,
        reason: 'the opposite (top-left) corner is the fixed anchor',
      );
      expect(harness.opRequests.single['y'], 100);
      expect(harness.opRequests.single['w'], 80);
      expect(harness.opRequests.single['h'], 40);
    });
  });

  test('aspect locks by default; the free drag distorts', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a', w: 40, h: 20));
      harness.document.refresh();
      harness.document.selectedObjectId.value = 'a';

      harness.ops.beginSelect(
        const Offset(140, 120),
        manageCanvas: false,
        selfId: 'me',
      );
      // Free-form this is 80x100; locked, both scale by the larger factor.
      harness.ops.dragSelect(const Offset(180, 200), lockAspect: true);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();

      expect(harness.opRequests.single['w'], closeTo(200, 0.01));
      expect(harness.opRequests.single['h'], closeTo(100, 0.01));
    });
  });

  test('undoing a resize restores the exact original bounds', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a'));
      harness.document.refresh();
      harness.document.selectedObjectId.value = 'a';

      harness.ops.beginSelect(
        const Offset(140, 120),
        manageCanvas: false,
        selfId: 'me',
      );
      harness.ops.dragSelect(const Offset(180, 140), lockAspect: false);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();
      expect(harness.ops.canUndo, isTrue);

      unawaited(harness.ops.undo());
      async.flushMicrotasks();

      final undoRequest = harness.opRequests.last;
      expect(undoRequest['kind'], 'move');
      expect(undoRequest['x'], 100);
      expect(undoRequest['y'], 100);
      expect(undoRequest['w'], 40);
      expect(undoRequest['h'], 20);
    });
  });

  test(
    'a non-owner without manageCanvas cannot pick up or resize a foreign image',
    () {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a', authorId: 'someone-else'));
      harness.document.refresh();

      harness.ops.beginSelect(
        const Offset(120, 110),
        manageCanvas: false,
        selfId: 'me',
      );
      expect(
        harness.document.selectedObjectId.value,
        isNull,
        reason: 'a foreign image must not be selectable without manageCanvas',
      );
    },
  );

  test('bringToFront restacks above every known object and pushes an undo', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a', zIndex: 1));
      harness.document.applyPlaced(_image('b', x: 500, zIndex: 5));
      harness.document.refresh();

      unawaited(harness.ops.bringToFront('a'));
      async.flushMicrotasks();

      expect(harness.opRequests.single['kind'], 'reorder');
      expect(harness.opRequests.single['object_id'], 'a');
      expect(harness.opRequests.single['z_index'], 6);
      expect(harness.document.zIndexOf('a'), 6);
      expect(harness.ops.canUndo, isTrue);
    });
  });

  test('sendToBack restacks below every known object', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a', zIndex: 1));
      harness.document.applyPlaced(_image('b', x: 500, zIndex: 5));
      harness.document.refresh();

      unawaited(harness.ops.sendToBack('b'));
      async.flushMicrotasks();

      expect(harness.opRequests.single['kind'], 'reorder');
      expect(harness.opRequests.single['z_index'], 0);
    });
  });

  test('bringToFront on the object already in front submits nothing', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a', zIndex: 1));
      harness.document.applyPlaced(_image('b', x: 500, zIndex: 5));
      harness.document.refresh();

      unawaited(harness.ops.bringToFront('b'));
      async.flushMicrotasks();

      expect(
        harness.opRequests,
        isEmpty,
        reason: 'already strictly above everything known - nothing to do',
      );
    });
  });

  test('undoing a reorder resubmits the exact prior z_index', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a', zIndex: 1));
      harness.document.applyPlaced(_image('b', x: 500, zIndex: 5));
      harness.document.refresh();

      unawaited(harness.ops.bringToFront('a'));
      async.flushMicrotasks();
      harness.opRequests.clear();

      unawaited(harness.ops.undo());
      async.flushMicrotasks();

      expect(harness.opRequests.single['kind'], 'reorder');
      expect(harness.opRequests.single['z_index'], 1);
      expect(harness.document.zIndexOf('a'), 1);
    });
  });

  test(
    'a reorder that fails reverts the local z_index and reports an error',
    () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.document.applyPlaced(_image('a', zIndex: 1));
        harness.document.applyPlaced(_image('b', x: 500, zIndex: 5));
        harness.document.refresh();
        harness.onOp = (_) => _json({'error': 'nope'}, 403);

        unawaited(harness.ops.bringToFront('a'));
        async.flushMicrotasks();

        expect(harness.document.zIndexOf('a'), 1);
        expect(harness.errors, ['That could not be reordered.']);
        expect(harness.ops.canUndo, isFalse);
      });
    },
  );

  test('a moving image is elevated for the drag and lands back on the '
      'plane once it commits', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a'));
      harness.document.refresh();

      harness.ops.beginSelect(
        const Offset(120, 110),
        manageCanvas: false,
        selfId: 'me',
      );
      expect(harness.document.elevatedObjectId.value, 'a');

      harness.ops.dragSelect(const Offset(220, 210), lockAspect: true);
      expect(harness.document.elevatedObjectId.value, 'a');

      unawaited(harness.ops.endSelect());
      expect(
        harness.document.elevatedObjectId.value,
        isNull,
        reason:
            'the object is optimistically back in place the instant the '
            'pointer lifts, before the request even lands',
      );
      async.flushMicrotasks();
    });
  });

  test('a resizing image is elevated for the drag, and a failed commit '
      'still lands it back on the plane', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_image('a'));
      harness.document.refresh();
      harness.document.selectedObjectId.value = 'a';
      harness.onOp = (_) => _json({'error': 'nope'}, 403);

      harness.ops.beginSelect(
        const Offset(140, 120),
        manageCanvas: false,
        selfId: 'me',
      );
      expect(harness.document.elevatedObjectId.value, 'a');

      harness.ops.dragSelect(const Offset(180, 140), lockAspect: false);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();

      expect(harness.document.elevatedObjectId.value, isNull);
    });
  });

  test('tapping a bare stroke selects it for reorder, never for a drag', () {
    final harness = _Harness();
    harness.document.applyPlaced(_stroke('line'));
    harness.document.refresh();

    harness.ops.beginSelect(
      const Offset(120, 100),
      manageCanvas: false,
      selfId: 'me',
    );

    expect(harness.document.selectedObjectId.value, 'line');
    expect(
      harness.document.elevatedObjectId.value,
      isNull,
      reason: 'a stroke is never draggable, so nothing ever lifts it',
    );

    harness.ops.dragSelect(const Offset(220, 200), lockAspect: true);
    unawaited(harness.ops.endSelect());
    expect(
      harness.opRequests,
      isEmpty,
      reason:
          'a stroke selection carries no drag state for endSelect '
          'to commit',
    );
  });

  test('an image on top of a stroke is what a tap over it still selects', () {
    final harness = _Harness();
    harness.document.applyPlaced(_stroke('line', zIndex: 1));
    harness.document.applyPlaced(_image('pic', x: 90, y: 90, zIndex: 2));
    harness.document.refresh();

    harness.ops.beginSelect(
      const Offset(110, 100),
      manageCanvas: false,
      selfId: 'me',
    );

    expect(
      harness.document.selectedObjectId.value,
      'pic',
      reason: 'whatever visually covers the point wins the tap',
    );
  });

  test('bringToFront restacks a selected stroke the same as an image', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_stroke('line', zIndex: 1));
      harness.document.applyPlaced(_image('pic', x: 500, zIndex: 5));
      harness.document.refresh();

      unawaited(harness.ops.bringToFront('line'));
      async.flushMicrotasks();

      expect(harness.opRequests.single['kind'], 'reorder');
      expect(harness.opRequests.single['object_id'], 'line');
      expect(harness.opRequests.single['z_index'], 6);
      expect(harness.document.zIndexOf('line'), 6);
    });
  });
}
