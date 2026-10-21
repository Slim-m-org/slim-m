// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A selected object small enough that its whole body sits inside
/// `resizeHandleHitRadius`'s own fixed screen-space reach - a resized-down
/// or naturally small pasted image is the easy way there, with
/// `minObjectSize` (8) well under that radius (14) at zoom 1 - used to be
/// stuck: every click on it, including dead centre, resolved to a resize
/// rather than a move. Report 2 in the backlog channel, "unable to move
/// images on canvas".
///
/// `canvas_ops_controller_resize_reorder_test.dart` already covers resize
/// itself on a normal-sized object; this is the narrower case that file's
/// own object (40x20) was too large to expose.
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

class _Harness {
  _Harness() {
    final client = testApi(
      (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        opRequests.add(body);
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
      onError: (_) {},
    );
  }

  final CanvasDocument document = CanvasDocument()
    ..setViewport(const Size(800, 600));
  late final CanvasCommitQueue commits;
  late final CanvasOpsController ops;
  final List<Map<String, dynamic>> opRequests = [];
  var _opSeq = 0;
}

/// A 10x10 image at (100, 100) - just above `minObjectSize` (8), well
/// under `resizeHandleHitRadius * 2` (28), the threshold past which every
/// interior point of the box is within radius of some corner.
CanvasStrokeInput _smallImage(String id) => CanvasStrokeInput(
  id: id,
  seq: 5,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 10,
  h: 10,
  points: const [],
  width: 0,
  colorKey: 'annotation',
  authorId: 'me',
  kind: CanvasObjectKind.image,
);

void main() {
  test('dragging the body of an already-selected small object moves it '
      'rather than resizing it', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_smallImage('small'));
      harness.document.refresh();
      harness.document.selectedObjectId.value = 'small';

      // Dead centre of the 10x10 box - within resizeHandleHitRadius (14) of every one of its four corners, and exactly the point the bug resolved to a resize from.
      harness.ops.beginSelect(
        const Offset(105, 105),
        manageCanvas: false,
        selfId: 'me',
      );
      harness.ops.dragSelect(const Offset(135, 125), lockAspect: false);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();

      expect(harness.opRequests, hasLength(1));
      expect(harness.opRequests.single['kind'], 'move');
      expect(
        harness.opRequests.single['w'],
        10,
        reason: 'a plain drag never resizes, however small the object',
      );
      expect(harness.opRequests.single['h'], 10);
      expect(harness.opRequests.single['x'], 130);
      expect(harness.opRequests.single['y'], 120);
    });
  });

  test('grabbing a corner of a small object still resizes it - the fix only '
      'narrows the interior, never the edges', () {
    fakeAsync((async) {
      final harness = _Harness();
      harness.document.applyPlaced(_smallImage('small'));
      harness.document.refresh();
      harness.document.selectedObjectId.value = 'small';

      // The bottom-right corner of the 100,100,10,10 box is 110,110 - outside the deep-interior zone [102.5, 107.5] on both axes.
      harness.ops.beginSelect(
        const Offset(110, 110),
        manageCanvas: false,
        selfId: 'me',
      );
      harness.ops.dragSelect(const Offset(120, 120), lockAspect: false);
      unawaited(harness.ops.endSelect());
      async.flushMicrotasks();

      expect(harness.opRequests, hasLength(1));
      expect(harness.opRequests.single['kind'], 'move');
      expect(
        harness.opRequests.single['w'],
        20,
        reason:
            'a translate never changes the box size; only a resize '
            'grows it, which is what grabbing a corner must still do',
      );
      expect(harness.opRequests.single['h'], 20);
    });
  });
}
