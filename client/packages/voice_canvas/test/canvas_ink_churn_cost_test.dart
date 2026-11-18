// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one more stroke, and one undo, cost to draw on a board of a thousand strokes.
/// A save reply or an undo once replayed the whole board twice, which is what dropped a busy web canvas to a few frames a second.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

const _size = Size(1000, 700);
const _board = 1000;
const _drawn = 60;

CanvasStrokeInput _circle(String id, math.Random rng, int seq, int z) {
  final r = 20 + rng.nextDouble() * 80;
  final cx = 100 + rng.nextDouble() * 800;
  final cy = 100 + rng.nextDouble() * 500;
  final points = Float32List(52);
  for (var k = 0; k <= 25; k++) {
    final a = k / 25 * 2 * math.pi;
    points[2 * k] = r + r * math.cos(a);
    points[2 * k + 1] = r + r * math.sin(a);
  }
  return CanvasStrokeInput(
    id: id,
    seq: seq,
    zIndex: z,
    x: cx - r,
    y: cy - r,
    w: 2 * r,
    h: 2 * r,
    points: points,
    width: 3,
    colorKey: 'ink',
  );
}

CanvasStrokeInput _confirmed(CanvasStrokeInput local, int seq) =>
    CanvasStrokeInput(
      id: local.id,
      seq: seq,
      zIndex: seq,
      x: local.x,
      y: local.y,
      w: local.w,
      h: local.h,
      points: local.points,
      width: local.width,
      colorKey: local.colorKey,
    );

void main() {
  late CanvasDocument document;
  late StrokePainter painter;
  final rng = math.Random(7);

  void frame() => painter.paint(RecordingCanvas(), _size);

  setUp(() {
    document = CanvasDocument()..setViewport(_size);
    for (var i = 0; i < _board; i++) {
      document.applyPlaced(_circle('s$i', rng, i + 1, i + 1));
    }
    document
      ..setCamera(const Camera())
      ..refresh();
    painter = StrokePainter(document: document, ink: ink)..devicePixelRatio = 1;
    frame();
    frame();
    expect(painter.debugHasInkTexture, isTrue);
  });
  tearDown(() {
    painter.dispose();
    document.dispose();
  });

  test('a stroke drawn, saved and echoed back redraws a few objects', () {
    final before = painter.debugObjectsPainted;
    for (var k = 0; k < _drawn; k++) {
      final local = _circle('d$k', rng, 0, provisionalLocalZIndex + k);
      document
        ..applyPlaced(local)
        ..refresh();
      frame();
      document
        ..applyPlaced(_confirmed(local, _board + 1 + k))
        ..refresh();
      frame();
      document
        ..applyPlaced(_confirmed(local, _board + 1 + k))
        ..refresh();
      frame();
      frame();
    }
    final perStroke = (painter.debugObjectsPainted - before) / _drawn;
    printOnFailure('objects drawn per new stroke: $perStroke');
    expect(
      perStroke,
      lessThan(_board / 5),
      reason: 'each new stroke replayed $perStroke objects of a $_board '
          'stroke board',
    );
  });

  test('an undo redraws only what sat under the removed stroke', () {
    final before = painter.debugObjectsPainted;
    for (var k = 0; k < _drawn; k++) {
      document
        ..removeObject('s${_board - 1 - k}')
        ..refresh();
      frame();
      frame();
    }
    final perUndo = (painter.debugObjectsPainted - before) / _drawn;
    printOnFailure('objects drawn per undo: $perUndo');
    expect(
      perUndo,
      lessThan(_board / 5),
      reason: 'each undo replayed $perUndo objects of a $_board stroke board',
    );
  });
}
