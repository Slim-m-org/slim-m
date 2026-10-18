// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The eraser removes every kind of object it can see, not only strokes.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _box(
  String id,
  CanvasObjectKind kind, {
  String? authorId,
}) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: 0,
  y: 0,
  w: 100,
  h: 80,
  points: const [],
  width: 0,
  colorKey: '',
  authorId: authorId,
  kind: kind,
  text: kind == CanvasObjectKind.note ? 'hi' : null,
  shapeKind: kind == CanvasObjectKind.shape ? CanvasShapeKind.rectangle : null,
  attachmentId: kind == CanvasObjectKind.image ? 'att' : null,
);

CanvasOpsController _ops(
  CanvasDocument document, {
  bool Function(String)? locked,
}) {
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
    isLocked: locked ?? (_) => false,
  );
}

void main() {
  for (final kind in [
    CanvasObjectKind.shape,
    CanvasObjectKind.note,
    CanvasObjectKind.image,
  ]) {
    test('the eraser removes a $kind of its own', () {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      document
        ..applyPlaced(_box('o', kind, authorId: 'me'))
        ..refresh();

      _ops(document).onErasePoint(
        const Offset(50, 40),
        manageCanvas: false,
        selfId: 'me',
      );

      expect(document.isAlive('o'), isFalse);
    });
  }

  test('the eraser leaves another member\'s shape without manage rights', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(_box('o', CanvasObjectKind.shape, authorId: 'them'))
      ..refresh();

    _ops(document).onErasePoint(
      const Offset(50, 40),
      manageCanvas: false,
      selfId: 'me',
    );

    expect(document.isAlive('o'), isTrue);
  });

  test('the eraser leaves a locked shape', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(_box('o', CanvasObjectKind.shape, authorId: 'me'))
      ..refresh();

    _ops(document, locked: (id) => id == 'o').onErasePoint(
      const Offset(50, 40),
      manageCanvas: true,
      selfId: 'me',
    );

    expect(document.isAlive('o'), isTrue);
  });
}
