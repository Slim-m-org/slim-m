// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A fast eraser sweep must erase a thin stroke it crossed between samples.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasOpsController _ops(CanvasDocument document) {
  final api.SlimmApi client = testApi((request) async {
    throw StateError('no request expected');
  });
  return CanvasOpsController(
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
}

void main() {
  test('a sweep whose samples straddle a thin stroke erases it', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 's',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 100,
          w: 100,
          h: 0,
          points: [0, 0, 100, 0],
          width: 3,
          colorKey: 'annotation',
          authorId: 'me',
        ),
      )
      ..refresh();
    final ops = _ops(document);

    ops
      ..onErasePoint(const Offset(50, 60), manageCanvas: false, selfId: 'me')
      ..onErasePoint(const Offset(50, 140), manageCanvas: false, selfId: 'me');

    expect(
      document.isAlive('s'),
      isFalse,
      reason: 'the pointer moved across the stroke between two samples',
    );
  });
}
