// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasDocument.showWorldRect] aspect-fits a world rectangle, with or without a board.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  const rect = Rect.fromLTWH(600, 300, 320, 180);

  test('on a board the rect fills the limiting axis and is centred', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
      ..setViewport(const Size(1280, 800));
    addTearDown(document.dispose);

    document.showWorldRect(rect);

    final view = document.worldView;
    expect(document.camera.zoom, closeTo(4, 1e-9));
    expect(view.width, closeTo(rect.width, 1e-6));
    expect(view.center.dx, closeTo(rect.center.dx, 1e-6));
    expect(view.center.dy, closeTo(rect.center.dy, 1e-6));
  });

  test('without a board it fits too', () {
    final document = CanvasDocument()..setViewport(const Size(800, 800));
    addTearDown(document.dispose);

    document.showWorldRect(rect);

    expect(document.camera.zoom, closeTo(2.5, 1e-9));
    expect(document.worldView.center.dx, closeTo(rect.center.dx, 1e-6));
    expect(document.worldView.center.dy, closeTo(rect.center.dy, 1e-6));
  });

  test('nothing happens before the viewport is measured', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea);
    addTearDown(document.dispose);
    final before = document.camera;

    document.showWorldRect(rect);

    expect(document.camera, before);
  });
}
