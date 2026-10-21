// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The eraser tooltip promises ink and shapes only; a drift off the ink must
/// not take the image underneath (audit C-084).
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test('wiping ink that drifts off the stroke leaves the image under it', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'img',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 400,
          h: 300,
          points: [],
          width: 0,
          colorKey: '',
          authorId: 'me',
          kind: CanvasObjectKind.image,
          attachmentId: 'att',
        ),
      )
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'ink',
          seq: 2,
          zIndex: 2,
          x: 0,
          y: 0,
          w: 100,
          h: 0,
          points: [0, 0, 100, 0],
          width: 3,
          colorKey: 'annotation',
          authorId: 'me',
        ),
      )
      ..refresh();
    final api.SlimmApi client = testApi((request) async {
      throw StateError('no request expected');
    });
    final ops = CanvasOpsController(
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
      onError: (_) {},
      isLocked: (_) => false,
    );

    ops.onErasePoint(const Offset(50, 0), manageCanvas: false, selfId: 'me');
    ops.onErasePoint(const Offset(200, 150), manageCanvas: false, selfId: 'me');

    expect(document.isAlive('ink'), isFalse);
    expect(
      document.isAlive('img'),
      isTrue,
      reason: 'tooltip: "Eraser - erases ink and shapes"',
    );
  });
}
