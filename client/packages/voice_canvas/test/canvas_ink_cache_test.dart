// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The committed ink is drawn from a texture while nothing it holds changes,
/// and falls back to the live strokes the moment anything does.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

const _size = Size(1000, 1000);

CanvasStrokeInput _stroke(String id, double x, double y, {int seq = 1}) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: seq,
      x: x,
      y: y,
      w: 16,
      h: 16,
      points: Float32List.fromList(<double>[0, 0, 16, 16]),
      width: 2,
      colorKey: 'ink',
    );

CanvasDocument _board({int count = 400}) {
  final document = CanvasDocument()..setViewport(_size);
  for (var i = 0; i < count; i++) {
    document.applyPlaced(_stroke('s$i', (i % 20) * 30.0, (i ~/ 20) * 30.0));
  }
  document.setCamera(const Camera(x: 100, y: 100));
  return document;
}

int _strokesDrawn(StrokePainter painter) {
  final canvas = RecordingCanvas();
  painter.paint(canvas, _size);
  return canvas.deviceStrokeWidths.length;
}

/// Antialiased edges differ by a few levels between two raster paths.
const _edgeTolerance = 24;

int _worstChannelGap(Uint8List a, Uint8List b) {
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final gap = (a[i] - b[i]).abs();
    if (gap > worst) worst = gap;
  }
  return worst;
}

void main() {
  late CanvasDocument document;
  late StrokePainter painter;

  setUp(() {
    document = _board();
    painter = StrokePainter(document: document, ink: ink);
  });
  tearDown(() {
    painter.dispose();
    document.dispose();
  });

  test('a pan inside the texture re-issues no committed stroke', () {
    final live = _strokesDrawn(painter);
    expect(live, greaterThan(100));
    _strokesDrawn(painter);
    expect(painter.debugHasInkTexture, isTrue);

    document.setCamera(const Camera(x: 130, y: 120));
    expect(_strokesDrawn(painter), 0);
  });

  test('a moved object is drawn live again, then cached again', () {
    _strokesDrawn(painter);
    _strokesDrawn(painter);

    document
      ..moveObject('s3', 500, 500, 16, 16)
      ..refresh();
    final canvas = RecordingCanvas();
    painter.paint(canvas, _size);
    expect(canvas.deviceStrokeWidths.length, greaterThan(100));
    expect(
        canvas.deviceBounds, contains(const Rect.fromLTRB(400, 400, 416, 416)));
    expect(_strokesDrawn(painter), 0);
  });

  test('a stroke added after the texture is drawn over it, alone', () {
    _strokesDrawn(painter);
    _strokesDrawn(painter);

    document
      ..applyPlaced(_stroke('late', 200, 200, seq: 999))
      ..refresh();
    expect(_strokesDrawn(painter), 1);
  });

  test('the dragged object paints live and its moves keep the texture', () {
    document.elevatedObjectId.value = 's5';
    _strokesDrawn(painter);
    _strokesDrawn(painter);

    document
      ..moveObject('s5', 300, 300, 16, 16)
      ..refresh();
    final canvas = RecordingCanvas();
    painter.paint(canvas, _size);
    expect(canvas.deviceStrokeWidths.length, 1);
    expect(canvas.deviceBounds.single, const Rect.fromLTRB(200, 200, 216, 216));
  });

  test('a drag that begins and ends between two frames still repaints it', () {
    _strokesDrawn(painter);
    _strokesDrawn(painter);

    document
      ..elevatedObjectId.value = 's5'
      ..moveObject('s5', 300, 300, 16, 16)
      ..elevatedObjectId.value = null
      ..refresh();
    final canvas = RecordingCanvas();
    painter.paint(canvas, _size);
    expect(
      canvas.deviceBounds,
      contains(const Rect.fromLTRB(200, 200, 216, 216)),
    );
  });

  test('a removed object leaves the texture on the next frame', () {
    _strokesDrawn(painter);
    _strokesDrawn(painter);

    document
      ..removeObject('s0')
      ..refresh();
    final live = _strokesDrawn(painter);
    expect(live, greaterThan(100), reason: 'the texture still held s0');
  });

  test('a zoom past the texture range rebuilds it at the new zoom', () {
    _strokesDrawn(painter);
    _strokesDrawn(painter);
    document.setCamera(const Camera(x: 100, y: 100, zoom: 3));
    expect(_strokesDrawn(painter), 0);
    document.setCamera(const Camera(x: 101, y: 100, zoom: 3));
    expect(_strokesDrawn(painter), 0);
    expect(painter.debugHasInkTexture, isTrue);
  });

  testWidgets('the texture draws the same pixels as the live strokes', (
    tester,
  ) async {
    painter.devicePixelRatio = 1;
    await tester.runAsync(() async {
      Future<Uint8List> frame() async {
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), _size);
        final image = await recorder.endRecording().toImage(1000, 1000);
        final bytes = await image.toByteData();
        image.dispose();
        return bytes!.buffer.asUint8List();
      }

      final live = await frame();
      expect(painter.debugHasInkTexture, isFalse);
      final cached = await frame();
      expect(painter.debugHasInkTexture, isTrue);

      expect(_worstChannelGap(live, cached), lessThan(_edgeTolerance));

      document.setCamera(const Camera(x: 130, y: 100));
      final panned = await frame();
      final reference = StrokePainter(document: document, ink: ink)
        ..devicePixelRatio = 1;
      final recorder = ui.PictureRecorder();
      reference.paint(Canvas(recorder), _size);
      final image = await recorder.endRecording().toImage(1000, 1000);
      final expected = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();
      reference.dispose();
      expect(_worstChannelGap(panned, expected), lessThan(_edgeTolerance));
    });
  });

  testWidgets('a live frame asks for a later one that builds the texture', (
    tester,
  ) async {
    var notified = 0;
    document.addListener(() => notified++);
    _strokesDrawn(painter);
    expect(painter.debugHasInkTexture, isFalse);
    expect(notified, 0);

    await tester.pump(const Duration(milliseconds: 300));
    expect(notified, 1, reason: 'nothing else would repaint the stale strokes');
    _strokesDrawn(painter);
    expect(painter.debugHasInkTexture, isTrue);
  });
}
