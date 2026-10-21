// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Snap to grid on a drag: the moved box lands on the grid the canvas draws,
/// lining up with a neighbour still wins on its axis, and Alt (snap: false)
/// bypasses both.
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
  test('with snap to grid on, a dragged box lands on a grid line', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.snapToGrid.value = true;
      harness.document.applyPlaced(_image('a'));
      harness.document.refresh();

      harness.ops.beginSelect(
        const Offset(120, 110),
        manageCanvas: false,
        selfId: 'me',
      );
      harness.ops.dragSelect(
        const Offset(210, 215),
        lockAspect: true,
        snap: true,
      );
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();

      final spacing = gridSpacingFor(harness.document.camera.zoom);
      final x = harness.opRequests.single['x'] as num;
      final y = harness.opRequests.single['y'] as num;
      expect(x % spacing, 0, reason: 'x on a grid line');
      expect(y % spacing, 0, reason: 'y on a grid line');
    });
  });

  test(
    'with snap to grid off, the drag lands exactly where it was dropped',
    () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.document.applyPlaced(_image('a'));
        harness.document.refresh();

        harness.ops.beginSelect(
          const Offset(120, 110),
          manageCanvas: false,
          selfId: 'me',
        );
        harness.ops.dragSelect(
          const Offset(210, 215),
          lockAspect: true,
          snap: true,
        );
        unawaited(harness.ops.endSelect());
        async.flushMicrotasks();

        expect(harness.opRequests.single['x'], 190);
        expect(harness.opRequests.single['y'], 205);
      });
    },
  );

  test('Alt bypasses the grid as it bypasses object snapping', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.snapToGrid.value = true;
      harness.document.applyPlaced(_image('a'));
      harness.document.refresh();

      harness.ops.beginSelect(
        const Offset(120, 110),
        manageCanvas: false,
        selfId: 'me',
      );
      harness.ops.dragSelect(const Offset(210, 215), lockAspect: true);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();

      expect(harness.opRequests.single['x'], 190);
      expect(harness.opRequests.single['y'], 205);
    });
  });
}
