// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strokes whose saves are slow fold into the ink texture once too many paint live, and still fade, fail and restack as the live ink does.
/// They once stayed out of the texture until saved, so a slow or absent server repainted every one of them every frame.
library;

import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';
import 'support/ink_texture_pixels.dart';

const _blue = Color(0xFF2050E0);
const _unsavedCount = 60;

CanvasStrokeInput _stroke(
  String id,
  double x,
  double y, {
  required int seq,
  required int z,
  String colorKey = 'ink',
}) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: z,
      x: x,
      y: y,
      w: 16,
      h: 16,
      points: Float32List.fromList(<double>[0, 0, 16, 16]),
      width: 2,
      colorKey: colorKey,
    );

/// The unsaved stroke [k], laid over a corner of a saved one so a restack shows.
CanvasStrokeInput _unsaved(int k, {int seq = 0, int? z}) => _stroke(
      'u$k',
      200 + (k % 10) * 30 + 8,
      200 + (k ~/ 10) * 30 + 8,
      seq: seq,
      z: z ?? provisionalLocalZIndex + k,
      colorKey: 'blue',
    );

int _drawnLive(StrokePainter painter) {
  final canvas = RecordingCanvas();
  painter.paint(canvas, inkTestSize);
  return canvas.deviceStrokeWidths.length;
}

void main() {
  late CanvasDocument document;
  late StrokePainter painter;

  setUp(() {
    document = CanvasDocument()..setViewport(inkTestSize);
    for (var i = 0; i < 400; i++) {
      document.applyPlaced(
        _stroke('s$i', (i % 20) * 30.0, (i ~/ 20) * 30.0, seq: i + 1, z: 1),
      );
    }
    document.setCamera(const Camera(x: 100, y: 100));
    painter = StrokePainter(
      document: document,
      ink: ink,
      inkColors: const {'blue': _blue},
    );
  });
  tearDown(() {
    painter.dispose();
    document.dispose();
  });

  testWidgets(
      'unsaved strokes past the live cap fold in and still fade, '
      'fail and restack as drawn live', (tester) async {
    await warmInkTexture(tester, painter);
    for (var k = 0; k < _unsavedCount; k++) {
      document
        ..applyPlaced(_unsaved(k))
        ..refresh();
      await inkFramePixels(tester, painter);
    }
    expect(_drawnLive(painter), lessThan(_unsavedCount));
    await expectInkMatchesLive(tester, painter, document);

    document.setUnsaved('u3', unsaved: true);
    await expectInkMatchesLive(tester, painter, document);

    document
      ..kill('u4')
      ..refresh();
    await expectInkMatchesLive(tester, painter, document);

    document
      ..applyPlaced(_unsaved(5, seq: 1000, z: 0))
      ..refresh();
    await expectInkMatchesLive(tester, painter, document);

    document
      ..applyPlaced(_unsaved(6, seq: 1001, z: 2))
      ..refresh();
    await expectInkMatchesLive(tester, painter, document);
    expect(painter.debugHasInkTexture, isTrue);
  });
}
