// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pixel checks for the ink texture: a frame drawn from it against a fresh painter's live ink.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'canvas_painter_fixtures.dart';

const inkTestSize = Size(1000, 1000);

/// Antialiased edges differ by a few levels between two raster paths.
const inkEdgeTolerance = 24;

/// One frame of [painter] at its own pixel ratio, read back as RGBA bytes, the way the engine scales a layer to the screen.
Future<Uint8List> inkFramePixels(
  WidgetTester tester,
  StrokePainter painter,
) async =>
    (await tester.runAsync(() async {
      final dpr = painter.devicePixelRatio;
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder)..scale(dpr), inkTestSize);
      final image = await recorder.endRecording().toImage(
            (inkTestSize.width * dpr).ceil(),
            (inkTestSize.height * dpr).ceil(),
          );
      final bytes = await image.toByteData();
      image.dispose();
      return bytes!.buffer.asUint8List();
    }))!;

/// Paints twice at [dpr], so the second frame draws from a texture.
Future<void> warmInkTexture(
  WidgetTester tester,
  StrokePainter painter, {
  double dpr = 1,
}) async {
  painter.devicePixelRatio = dpr;
  await inkFramePixels(tester, painter);
  await inkFramePixels(tester, painter);
  expect(painter.debugHasInkTexture, isTrue);
}

/// The next frame of [painter] against a fresh painter's live strokes, with [stray] the share of pixels allowed past [inkEdgeTolerance].
/// Skia shades a round cap differently at different whole-pixel positions, which a texture drawn elsewhere shows at a few cap pixels; a misplaced texture shows at every edge.
Future<void> expectInkMatchesLive(
  WidgetTester tester,
  StrokePainter painter,
  CanvasDocument document, {
  double stray = 0,
}) async {
  final cached = await inkFramePixels(tester, painter);
  final reference = StrokePainter(
    document: document,
    ink: ink,
    inkColors: painter.inkColors,
  )..devicePixelRatio = painter.devicePixelRatio;
  addTearDown(reference.dispose);
  final live = await inkFramePixels(tester, reference);
  final pixels = cached.length ~/ 4;
  expect(
    _pixelsPastTolerance(cached, live),
    lessThanOrEqualTo((pixels * stray).floor()),
    reason: 'worst channel gap ${worstChannelGap(cached, live)}',
  );
}

int _pixelsPastTolerance(Uint8List a, Uint8List b) {
  var count = 0;
  for (var i = 0; i < a.length; i += 4) {
    for (var c = i; c < i + 4; c++) {
      if ((a[c] - b[c]).abs() >= inkEdgeTolerance) {
        count++;
        break;
      }
    }
  }
  return count;
}

int worstChannelGap(Uint8List a, Uint8List b) {
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final gap = (a[i] - b[i]).abs();
    if (gap > worst) worst = gap;
  }
  return worst;
}
