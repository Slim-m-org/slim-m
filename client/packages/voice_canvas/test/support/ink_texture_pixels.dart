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

/// One frame of [painter], read back as RGBA bytes.
Future<Uint8List> inkFramePixels(
  WidgetTester tester,
  StrokePainter painter,
) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), inkTestSize);
      final image = await recorder.endRecording().toImage(
            inkTestSize.width.toInt(),
            inkTestSize.height.toInt(),
          );
      final bytes = await image.toByteData();
      image.dispose();
      return bytes!.buffer.asUint8List();
    }))!;

/// Paints twice, so the second frame draws from a texture.
Future<void> warmInkTexture(WidgetTester tester, StrokePainter painter) async {
  painter.devicePixelRatio = 1;
  await inkFramePixels(tester, painter);
  await inkFramePixels(tester, painter);
  expect(painter.debugHasInkTexture, isTrue);
}

/// The next frame of [painter] against a fresh painter's live strokes.
Future<void> expectInkMatchesLive(
  WidgetTester tester,
  StrokePainter painter,
  CanvasDocument document,
) async {
  final cached = await inkFramePixels(tester, painter);
  final reference = StrokePainter(document: document, ink: ink)
    ..devicePixelRatio = 1;
  addTearDown(reference.dispose);
  final live = await inkFramePixels(tester, reference);
  expect(worstChannelGap(cached, live), lessThan(inkEdgeTolerance));
}

int worstChannelGap(Uint8List a, Uint8List b) {
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final gap = (a[i] - b[i]).abs();
    if (gap > worst) worst = gap;
  }
  return worst;
}
