// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasDocument _document(Size viewport, {double inset = 0}) => CanvasDocument()
  ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
  ..setViewport(viewport)
  ..setBottomInset(inset);

void _expectInsideBoard(CanvasDocument document, {double inset = 0}) {
  final camera = document.camera;
  final view = Rect.fromLTWH(
    camera.x,
    camera.y,
    document.viewport.width / camera.zoom,
    (document.viewport.height - inset) / camera.zoom,
  );
  expect(canvasBoard.inflate(1e-6).contains(view.topLeft), isTrue);
  expect(canvasBoard.inflate(1e-6).contains(view.bottomRight), isTrue);
}

void main() {
  const panes = [Size(1200, 900), Size(390, 844), Size(2560, 1000)];

  test('the cover zoom is the larger fit ratio', () {
    expect(boardCoverZoom(canvasBoard, const Size(1200, 900)),
        closeTo(900 / 2160, 1e-9));
    expect(boardCoverZoom(canvasBoard, const Size(1920, 1080)),
        closeTo(0.5, 1e-9));
  });

  test('zooming out to the floor never shows past the board edge', () {
    for (final pane in panes) {
      final document = _document(pane);
      document.setCamera(const Camera(zoom: 0.01));
      expect(document.camera.zoom, closeTo(document.zoomFloor, 1e-9));
      expect(
          document.zoomFloor, closeTo(boardCoverZoom(canvasBoard, pane), 1e-9));
      _expectInsideBoard(document);
    }
  });

  test('panning at the floor stays on the board', () {
    for (final pane in panes) {
      final document = _document(pane);
      document.setCamera(const Camera(x: -5000, y: -5000, zoom: 0.01));
      _expectInsideBoard(document);
      document.setCamera(const Camera(x: 9000, y: 9000, zoom: 0.01));
      _expectInsideBoard(document);
    }
  });

  test('the dock inset keeps the view above the dock on the board', () {
    const pane = Size(1200, 900);
    final document = _document(pane, inset: 180);
    document.setCamera(const Camera(x: 9000, y: 9000, zoom: 0.01));
    _expectInsideBoard(document, inset: 180);
    document.setCamera(const Camera(x: -9000, y: -9000, zoom: 0.01));
    _expectInsideBoard(document, inset: 180);
  });

  test('fit and recenter still reach the shared area', () {
    for (final pane in panes) {
      final document = _document(pane);
      final opening = document.camera;
      document.setCamera(const Camera(x: 700, y: 400, zoom: 2));
      document.fitBoard();
      expect(document.camera, opening);
      expect(document.isFitted, isTrue);
    }
  });

  test('a follower view larger than the floor is held at the floor', () {
    const pane = Size(1200, 900);
    final camera = cameraForBoardView(canvasBoard, canvasBoard, pane);
    expect(camera.zoom, closeTo(boardCoverZoom(canvasBoard, pane), 1e-9));
  });

  test('a small rect still zooms in to fit, as a focused tile does', () {
    final document = _document(const Size(1200, 900));
    const tile = Rect.fromLTWH(100, 100, 320, 180);
    document.showWorldRect(tile);
    expect(document.camera.zoom, closeTo(1200 / 320, 1e-9));
    expect(document.worldView.contains(tile.center), isTrue);
  });

  test('a tall pane opens at the floor and still reads as 100 percent', () {
    final document = _document(const Size(390, 844));
    expect(document.isFitted, isTrue);
    expect(document.camera.zoom, closeTo(document.zoomFloor, 1e-9));
    expect(document.sharedFitZoom, closeTo(document.camera.zoom, 1e-9));
  });
}
