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
    ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
    ..setViewport(physical);
  final camera = document.camera;
  return Offset(
    (boardPoint.dx - camera.x) * camera.zoom / physical.width,
    (boardPoint.dy - camera.y) * camera.zoom / physical.height,
  );
}

void main() {
  const screens = [Size(390, 844), Size(1280, 800), Size(2560, 1440)];
  const landscapeScreens = [Size(1280, 800), Size(2560, 1440)];

  test('a board object keeps its place on the board at every size and DPR', () {
    const point = Offset(480, 270);
    for (final screen in screens) {
      for (final dpr in [1.0, 2.0]) {
        final document = CanvasDocument()
          ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
          ..setViewport(Size(screen.width * dpr, screen.height * dpr));
        final camera = document.camera;
        final board = Rect.fromLTWH(
          (canvasBoard.left - camera.x) * camera.zoom,
          (canvasBoard.top - camera.y) * camera.zoom,
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
          closeTo(0.375, 1e-9),
          reason: '$screen @$dpr',
        );
        expect(
          (onScreen.dy - board.top) / board.height,
          closeTo(0.375, 1e-9),
          reason: '$screen @$dpr',
        );
      }
    }
  });

  test('the shared area is fitted on every landscape screen shape', () {
    for (final screen in landscapeScreens) {
      final document = CanvasDocument()
        ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
        ..setViewport(screen);
      final view = document.worldView;
      expect(view.contains(canvasSharedArea.topLeft), isTrue,
          reason: '$screen');
      expect(view.inflate(1e-6).contains(canvasSharedArea.bottomRight), isTrue,
          reason: '$screen');
      expect(document.isFitted, isTrue);
      // One axis is filled exactly, the other shows more of the board.
      expect(
        (view.width - canvasSharedArea.width).abs() < 1e-6 ||
            (view.height - canvasSharedArea.height).abs() < 1e-6,
        isTrue,
        reason: '$screen',
      );
      expect(view.center.dx, closeTo(canvasSharedArea.center.dx, 1e-6));
      expect(view.center.dy, closeTo(canvasSharedArea.center.dy, 1e-6));
    }
  });

  test('the same board point sits at the same fraction on 16:9 screens', () {
    const point = Offset(960, 540);
    final a = relativeScreenPosition(point, const Size(1280, 720), 1);
    final b = relativeScreenPosition(point, const Size(2560, 1440), 2);
    expect(a.dx, closeTo(b.dx, 1e-9));
    expect(a.dy, closeTo(b.dy, 1e-9));
  });

  test('a viewer cannot zoom out past the whole board nor pan off it', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
      ..setViewport(const Size(1280, 800));
    document.setCamera(const Camera(x: 9000, y: -4000, zoom: 0.05));
    expect(document.camera.zoom, closeTo(800 / canvasBoard.height, 1e-9));
    expect(document.worldView.right, closeTo(canvasBoard.right, 1e-6));
    expect(document.worldView.top, closeTo(canvasBoard.top, 1e-6));
    expect(document.isFitted, isFalse);
  });

  test('a temporary zoom stays over the board and fitBoard brings it back', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
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
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
      ..setViewport(const Size(390, 844));
    document.setViewport(const Size(2560, 1440));
    expect(document.isFitted, isTrue);
    expect(document.camera.zoom, closeTo(2560 / canvasSharedArea.width, 1e-9));
  });

  test('a followed view is fitted to the follower aspect, board part only', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
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

  test('a leader on the shared area reports it, not the board around it', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
      ..setViewport(const Size(390, 844));
    expect(document.visibleBoard, canvasSharedArea);
  });

  test('ink cannot start outside the board and is clamped when it leaves', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
      ..setViewport(const Size(1280, 800));
    expect(document.acceptsPlacementAt(const Offset(-5, 10)), isTrue);
    expect(document.acceptsPlacementAt(const Offset(-5000, 10)), isFalse);
    expect(document.clampToBoard(const Offset(9000, -2000)),
        Offset(canvasBoard.right, canvasBoard.top));
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

  group('the bigger board', () {
    CanvasDocument opened(Size screen) => CanvasDocument()
      ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
      ..setViewport(screen);

    test('the board is twice the shared area, grown around its centre', () {
      expect(canvasBoard.size, canvasSharedArea.size * 2);
      expect(canvasBoard.center, canvasSharedArea.center);
    });

    test('opening shows the shared area at its old fit zoom', () {
      final document = opened(const Size(1280, 720));
      expect(document.camera.zoom, closeTo(1280 / 1920, 1e-9));
      expect(document.worldView.left, closeTo(0, 1e-6));
      expect(document.worldView.top, closeTo(0, 1e-6));
      expect(document.worldView.width, closeTo(1920, 1e-6));
      expect(document.sharedFitZoom, document.camera.zoom);
    });

    test('a viewer can pan from the opening view in every direction', () {
      for (final step in const [
        Offset(400, 0),
        Offset(-400, 0),
        Offset(0, 300),
        Offset(0, -300),
      ]) {
        final document = opened(const Size(1280, 720));
        final from = document.camera;
        document.setCamera(
          Camera(
            x: from.x + step.dx,
            y: from.y + step.dy,
            zoom: from.zoom,
          ),
        );
        expect(document.camera.x, closeTo(from.x + step.dx, 1e-6),
            reason: '$step');
        expect(document.camera.y, closeTo(from.y + step.dy, 1e-6),
            reason: '$step');
        expect(document.isFitted, isFalse, reason: '$step');
      }
    });

    test('zooming out reaches the whole board', () {
      final document = opened(const Size(1280, 720));
      document.setCamera(const Camera(zoom: 0.01));
      expect(document.worldView.inflate(1e-6).contains(canvasBoard.topLeft),
          isTrue);
      expect(
        document.worldView.inflate(1e-6).contains(canvasBoard.bottomRight),
        isTrue,
      );
      expect(document.zoomFloor, closeTo(1280 / canvasBoard.width, 1e-9));
    });

    test('old content keeps its world coordinates', () {
      final document = opened(const Size(1280, 720))
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'old',
            seq: 1,
            zIndex: 1,
            x: 1500,
            y: 900,
            w: 100,
            h: 50,
            points: [],
            width: 0,
            colorKey: 'shape',
            kind: CanvasObjectKind.shape,
          ),
        );
      final stroke = document.boardContentBounds!;
      expect(stroke, const Rect.fromLTWH(1500, 900, 100, 50));
      expect(canvasSharedArea.contains(stroke.topLeft), isTrue);
      expect(document.idsOutsideBoard, isEmpty);
    });

    test('fit returns to the shared area after a pan or zoom', () {
      final document = opened(const Size(1280, 720));
      final home = document.camera;
      document.setCamera(const Camera(x: 700, y: 400, zoom: 2));
      expect(document.isFitted, isFalse);
      document.fitBoard();
      expect(document.camera, home);
      expect(document.isFitted, isTrue);
    });
  });
}
