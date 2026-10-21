// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Where a board point lands on screen, as a fraction of the screen, for a
/// document fitted to [screen] at device pixel ratio [dpr].
Offset relativeScreenPosition(Offset boardPoint, Size screen, double dpr) {
  final physical = Size(screen.width * dpr, screen.height * dpr);
  final document = CanvasDocument()
    ..setBoard(canvasBoard)
    ..setViewport(physical);
  final camera = document.camera;
  return Offset(
    (boardPoint.dx - camera.x) * camera.zoom / physical.width,
    (boardPoint.dy - camera.y) * camera.zoom / physical.height,
  );
}

void main() {
  const screens = [Size(390, 844), Size(1280, 800), Size(2560, 1440)];

  test('a board object keeps its place on the board at every size and DPR', () {
    const point = Offset(480, 270);
    for (final screen in screens) {
      for (final dpr in [1.0, 2.0]) {
        final document = CanvasDocument()
          ..setBoard(canvasBoard)
          ..setViewport(Size(screen.width * dpr, screen.height * dpr));
        final camera = document.camera;
        final board = Rect.fromLTWH(
          -camera.x * camera.zoom,
          -camera.y * camera.zoom,
          canvasBoard.width * camera.zoom,
          canvasBoard.height * camera.zoom,
        );
        final onScreen = Offset(
          (point.dx - camera.x) * camera.zoom,
          (point.dy - camera.y) * camera.zoom,
        );
        // Relative to the board's own frame, never to the window.
        expect(
          (onScreen.dx - board.left) / board.width,
          closeTo(0.25, 1e-9),
          reason: '$screen @$dpr',
        );
        expect(
          (onScreen.dy - board.top) / board.height,
          closeTo(0.25, 1e-9),
          reason: '$screen @$dpr',
        );
      }
    }
  });

  test('the whole board is fitted and letterboxed on every screen shape', () {
    for (final screen in screens) {
      final document = CanvasDocument()
        ..setBoard(canvasBoard)
        ..setViewport(screen);
      final view = document.worldView;
      expect(view.contains(canvasBoard.topLeft), isTrue, reason: '$screen');
      expect(view.inflate(1e-6).contains(canvasBoard.bottomRight), isTrue,
          reason: '$screen');
      expect(document.isFitted, isTrue);
      final fitted = view.width / canvasBoard.width;
      // One axis is filled exactly, the other letterboxed evenly.
      expect(
        view.width == canvasBoard.width || view.height == canvasBoard.height,
        isTrue,
        reason: '$screen',
      );
      expect(fitted, greaterThanOrEqualTo(1 - 1e-9));
      expect(view.center.dx, closeTo(canvasBoard.center.dx, 1e-6));
      expect(view.center.dy, closeTo(canvasBoard.center.dy, 1e-6));
    }
  });

  test('the same board point sits at the same fraction on 16:9 screens', () {
    const point = Offset(960, 540);
    final a = relativeScreenPosition(point, const Size(1280, 720), 1);
    final b = relativeScreenPosition(point, const Size(2560, 1440), 2);
    expect(a.dx, closeTo(b.dx, 1e-9));
    expect(a.dy, closeTo(b.dy, 1e-9));
  });

  test('a viewer cannot zoom out past the fit nor pan off a fitted board', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(const Size(1280, 800));
    final fit = document.camera;
    document.setCamera(const Camera(x: 900, y: -400, zoom: 0.05));
    expect(document.camera, fit);
  });

  test('a temporary zoom stays over the board and fitBoard brings it back', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(const Size(1280, 800));
    document.setCamera(const Camera(x: 5000, y: 5000, zoom: 3));
    expect(document.isFitted, isFalse);
    expect(document.worldView.right, closeTo(canvasBoard.right, 1e-6));
    expect(document.worldView.bottom, closeTo(canvasBoard.bottom, 1e-6));
    document.fitBoard();
    expect(document.isFitted, isTrue);
  });

  test('a resize while fitted refits instead of keeping a stale zoom', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(const Size(390, 844));
    document.setViewport(const Size(2560, 1440));
    expect(document.isFitted, isTrue);
    expect(document.camera.zoom, closeTo(2560 / 1920, 1e-9));
  });

  test('a followed view is fitted to the follower aspect, board part only', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(const Size(390, 844));
    const leader = Rect.fromLTWH(480, 270, 960, 540);
    document.showBoardView(leader);
    final view = document.worldView;
    expect(view.contains(leader.topLeft), isTrue);
    expect(view.inflate(1e-6).contains(leader.bottomRight), isTrue);
    expect(view.center.dx, closeTo(leader.center.dx, 1e-6));
    // Portrait follower: the width is the binding axis, extra board above and below.
    expect(view.width, closeTo(leader.width, 1e-6));
    expect(view.height, greaterThan(leader.height));
  });

  test('a leader letterboxed on a tall phone reports the whole board', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(const Size(390, 844));
    expect(document.visibleBoard, canvasBoard);
  });

  test('ink cannot start outside the board and is clamped when it leaves', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(const Size(1280, 800));
    expect(document.acceptsPlacementAt(const Offset(-5, 10)), isFalse);
    expect(document.acceptsPlacementAt(const Offset(5, 10)), isTrue);
    expect(
        document.clampToBoard(const Offset(3000, -20)), const Offset(1920, 0));
  });

  test('a follower is centred on a leader zoomed past the limit', () {
    const viewport = Size(1600, 900);
    final view = Rect.fromCenter(
      center: const Offset(960, 540),
      width: 200,
      height: 112.5,
    );

    final camera = cameraForBoardView(view, canvasBoard, viewport);

    final shown = Rect.fromLTWH(
      camera.x,
      camera.y,
      viewport.width / camera.zoom,
      viewport.height / camera.zoom,
    );
    expect(camera.zoom, maxZoom);
    expect(shown.center.dx, closeTo(960, 1e-6));
    expect(shown.center.dy, closeTo(540, 1e-6));
  });
}
