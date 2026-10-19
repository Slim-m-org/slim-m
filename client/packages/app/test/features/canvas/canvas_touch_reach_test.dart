// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hit reach and resize handles are screen distances: a finger reaches the
/// same number of pixels at any zoom, and further than a mouse does.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasOpsController _ops(CanvasDocument document) {
  final client = testApi((request) async => throw StateError('no request'));
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
  );
}

CanvasDocument _documentWith(CanvasStrokeInput input, {double zoom = 1}) {
  final document = CanvasDocument()
    ..setViewport(const Size(800, 600))
    ..applyPlaced(input)
    ..refresh()
    ..setCamera(Camera(zoom: zoom));
  addTearDown(document.dispose);
  return document;
}

const _line = CanvasStrokeInput(
  id: 'line',
  seq: 1,
  zIndex: 1,
  x: 0,
  y: 0,
  w: 100,
  h: 0,
  points: [0, 0, 100, 0],
  width: 0,
  colorKey: 'annotation',
  authorId: 'me',
);

const _note = CanvasStrokeInput(
  id: 'note',
  seq: 1,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 200,
  h: 120,
  points: [],
  width: 0,
  colorKey: 'amber',
  authorId: 'me',
  kind: CanvasObjectKind.note,
  text: 'hi',
);

String? _selectedAt(CanvasDocument document, Offset world, {bool? touch}) {
  _ops(document).beginSelect(
    world,
    manageCanvas: false,
    selfId: 'me',
    touch: touch ?? false,
  );
  return document.selectedObjectId.value;
}

void main() {
  test(
    'a finger selects a stroke the mouse misses, at the same screen reach',
    () {
      final document = _documentWith(_line);

      expect(_selectedAt(document, const Offset(50, 8)), isNull);
      expect(_selectedAt(document, const Offset(50, 8), touch: true), 'line');
      expect(_selectedAt(document, const Offset(50, 14), touch: true), isNull);
    },
  );

  test('the reach is the same on screen when zoomed out', () {
    final document = _documentWith(_line, zoom: 0.25);

    // 12 screen px at 0.25 zoom is 48 world units; 4 px is 16.
    expect(_selectedAt(document, const Offset(50, 30)), isNull);
    expect(_selectedAt(document, const Offset(50, 30), touch: true), 'line');
    expect(_selectedAt(document, const Offset(50, 60), touch: true), isNull);
  });

  test('a finger selects a note from just outside its edge', () {
    final document = _documentWith(_note);

    expect(_selectedAt(document, const Offset(94, 150)), isNull);
    expect(_selectedAt(document, const Offset(94, 150), touch: true), 'note');
  });

  test('a finger grabs a resize handle from further than a mouse can', () {
    final document = _documentWith(_note)..selectedObjectId.value = 'note';
    final ops = _ops(document);

    // 18 screen px from the bottom-right corner, along the diagonal's outside.
    const farFromCorner = Offset(300 + 18, 220);
    document.selectedObjectId.value = 'note';
    ops.beginSelect(farFromCorner, manageCanvas: false, selfId: 'me');
    expect(ops.activeMove, isNull, reason: 'a mouse reaches 14 px');
    document.selectedObjectId.value = 'note';
    ops.beginSelect(
      farFromCorner,
      manageCanvas: false,
      selfId: 'me',
      touch: true,
    );
    expect(ops.activeMove?.id, 'note', reason: 'a finger reaches 22 px');
  });
}
