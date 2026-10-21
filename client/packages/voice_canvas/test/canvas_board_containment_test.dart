// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Nothing the canvas paints lands on the letterbox, whatever the document
/// holds or a viewer drags past the board's edge. Decision 0080.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _letterbox = Color(0xFF101010);
const _ink = Color(0xFFE86A5C);
const _screens = [Size(390, 844), Size(1280, 800), Size(1920, 1080)];

CanvasStrokeInput _stroke(
  String id,
  List<Offset> world, {
  double width = 4,
}) {
  final left = world.map((p) => p.dx).reduce((a, b) => a < b ? a : b);
  final top = world.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
  final right = world.map((p) => p.dx).reduce((a, b) => a > b ? a : b);
  final bottom = world.map((p) => p.dy).reduce((a, b) => a > b ? a : b);
  return CanvasStrokeInput(
    id: id,
    seq: 1,
    zIndex: 1,
    x: left,
    y: top,
    w: right - left,
    h: bottom - top,
    points: [
      for (final p in world) ...[p.dx - left, p.dy - top]
    ],
    width: width,
    colorKey: 'ink',
  );
}

CanvasStrokeInput _shape(String id, Rect box) => CanvasStrokeInput(
      id: id,
      seq: 2,
      zIndex: 2,
      x: box.left,
      y: box.top,
      w: box.width,
      h: box.height,
      points: const [],
      width: 0,
      colorKey: 'ink',
      kind: CanvasObjectKind.shape,
      shapeKind: CanvasShapeKind.rectangle,
    );

Rect _boardOnScreen(CanvasDocument document) {
  final camera = document.camera;
  final board = document.board!;
  return Rect.fromLTWH(
    (board.left - camera.x) * camera.zoom,
    (board.top - camera.y) * camera.zoom,
    board.width * camera.zoom,
    board.height * camera.zoom,
  );
}

/// Pixels that differ from the letterbox colour outside [board].
Future<int> _paintedOutside(
  WidgetTester tester,
  GlobalKey key,
  Rect board,
) async {
  final bytes = await tester.runAsync<ByteData>(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    return (await image.toByteData())!;
  });
  final width = tester.view.physicalSize.width.round();
  final height = tester.view.physicalSize.height.round();
  final inner = board.inflate(1.5);
  var painted = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (inner.contains(Offset(x + 0.5, y + 0.5))) continue;
      final o = (y * width + x) * 4;
      final matches = bytes!.getUint8(o) == (_letterbox.r * 255).round() &&
          bytes.getUint8(o + 1) == (_letterbox.g * 255).round() &&
          bytes.getUint8(o + 2) == (_letterbox.b * 255).round();
      if (!matches) painted++;
    }
  }
  return painted;
}

Future<CanvasDocument> _pump(
  WidgetTester tester,
  Size size,
  GlobalKey key, {
  void Function(List<Offset>)? onStroke,
  double strokeWidth = 4,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final document = CanvasDocument()..setBoard(canvasBoard);
  addTearDown(document.dispose);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: _letterbox,
          child: CanvasSurface(
            document: document,
            ink: _ink,
            strokeWidth: strokeWidth,
            tool: CanvasTool.pen,
            onStroke: onStroke ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return document;
}

void main() {
  for (final size in _screens) {
    group('at $size', () {
      testWidgets('legacy objects outside the frame paint nothing', (
        tester,
      ) async {
        final key = GlobalKey();
        final document = await _pump(tester, size, key);
        document
          ..applyPlaced(_stroke(
              'above', [const Offset(100, -300), const Offset(900, -200)]))
          ..applyPlaced(_stroke(
              'below', [const Offset(100, 1300), const Offset(900, 1500)]))
          ..applyPlaced(_stroke(
              'left', [const Offset(-900, 100), const Offset(-200, 900)]))
          ..applyPlaced(_stroke(
              'right', [const Offset(2100, 100), const Offset(2900, 900)]))
          ..refresh();
        await tester.pump();

        expect(await _paintedOutside(tester, key, _boardOnScreen(document)), 0);
      });

      testWidgets('an object straddling the edge is cut at the edge', (
        tester,
      ) async {
        final key = GlobalKey();
        final document = await _pump(tester, size, key);
        document
          ..applyPlaced(_stroke(
            'edge',
            [
              const Offset(0, 0),
              const Offset(1920, 0),
              const Offset(1920, 1080)
            ],
            width: 120,
          ))
          ..applyPlaced(_shape('box', const Rect.fromLTWH(1700, -80, 400, 300)))
          ..refresh();
        await tester.pump();

        final board = _boardOnScreen(document);
        expect(await _paintedOutside(tester, key, board), 0);
      });

      testWidgets('ink dragged past the edge stays on the board', (
        tester,
      ) async {
        final key = GlobalKey();
        List<Offset>? drawn;
        final document = await _pump(
          tester,
          size,
          key,
          onStroke: (points) => drawn = points,
          strokeWidth: 60,
        );
        final board = _boardOnScreen(document);
        final gesture = await tester.startGesture(board.center);
        await gesture.moveTo(Offset(board.center.dx, 0));
        await gesture.moveTo(const Offset(0, 0));
        await gesture.moveTo(Offset(board.center.dx, size.height));
        await tester.pump();
        expect(
          await _paintedOutside(tester, key, board),
          0,
          reason: 'the draft',
        );
        await gesture.up();
        await tester.pump();

        for (final point in drawn!) {
          expect(canvasBoard.inflate(1e-6).contains(point), isTrue);
        }
        expect(await _paintedOutside(tester, key, board), 0);
      });
    });
  }

  test('every object sits inside the board after any move or resize', () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..applyPlaced(_shape('shape', const Rect.fromLTWH(100, 100, 300, 200)))
      ..applyPlaced(
          _stroke('ink', [const Offset(50, 50), const Offset(150, 90)]));
    addTearDown(document.dispose);
    for (final target in const [
      Offset(-500, -500),
      Offset(5000, 5000),
      Offset(1900, 1000),
      Offset(-1, 540),
    ]) {
      for (final id in ['shape', 'ink']) {
        final from = document.objectBounds(id)!;
        final fit =
            document.boxOnBoard(id, target.dx, target.dy, from.w, from.h);
        document.moveObject(id, fit.x, fit.y, fit.w, fit.h);
        final box = document.objectBounds(id)!;
        expect(
          boardHoldsBox(
            canvasBoard.inflate(1e-6),
            Rect.fromLTWH(box.x, box.y, box.w, box.h),
          ),
          isTrue,
          reason: '$id moved to $target is $box',
        );
      }
    }
    final big = document.boxOnBoard('shape', 0, 0, 9000, 4000);
    document.moveObject('shape', big.x, big.y, big.w, big.h);
    final grown = document.objectBounds('shape')!;
    expect(grown.w, lessThanOrEqualTo(canvasBoard.width + 1e-6));
    expect(grown.h, lessThanOrEqualTo(canvasBoard.height + 1e-6));
  });

  test('moveObject applies the box it is given, so a rollback can leave it out',
      () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..applyPlaced(_shape('shape', const Rect.fromLTWH(100, 100, 300, 200)));
    addTearDown(document.dispose);

    document.moveObject('shape', 2500, 100, 300, 200);

    expect(document.objectBounds('shape')!.x, 2500);
    expect(document.idsOutsideBoard, ['shape']);
  });

  test('content outside the frame is counted, and bringing it in clears it',
      () {
    final document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..applyPlaced(_shape('out', const Rect.fromLTWH(2500, 100, 300, 200)))
      ..applyPlaced(_shape('in', const Rect.fromLTWH(100, 100, 300, 200)));
    addTearDown(document.dispose);
    expect(document.outsideBoardCount.value, 1);
    expect(document.idsOutsideBoard, ['out']);
    final from = document.objectBounds('out')!;
    final to = document.boxOnBoard('out', from.x, from.y, from.w, from.h);
    document.moveObject('out', to.x, to.y, to.w, to.h);
    expect(document.outsideBoardCount.value, 0);
  });

  test('a tile is held inside the board when dragged or told by the server',
      () {
    final overrides = CanvasPresenceTileOverrides()..board = canvasBoard;
    addTearDown(overrides.dispose);
    overrides.setRect('camera:a', const Rect.fromLTWH(1800, 1000, 220, 160));
    final dragged = overrides.stateFor('camera:a').rect!;
    expect(dragged.right, lessThanOrEqualTo(canvasBoard.right));
    expect(dragged.bottom, lessThanOrEqualTo(canvasBoard.bottom));
    overrides.applyServer(
      'camera:b',
      rect: const Rect.fromLTWH(-300, -300, 220, 160),
      locked: false,
      sentToBack: false,
    );
    expect(overrides.stateFor('camera:b').rect!.topLeft, Offset.zero);
  });

  test('every screen sees objects at the same place on the board', () {
    const point = Offset(480, 270);
    final seen = <Offset>{};
    for (final size in _screens) {
      final document = CanvasDocument()
        ..setBoard(canvasBoard)
        ..setViewport(size);
      final board = _boardOnScreen(document);
      final camera = document.camera;
      final screen = Offset(
        (point.dx - camera.x) * camera.zoom,
        (point.dy - camera.y) * camera.zoom,
      );
      seen.add(
        Offset(
          ((screen.dx - board.left) / board.width * 1000).roundToDouble(),
          ((screen.dy - board.top) / board.height * 1000).roundToDouble(),
        ),
      );
      document.dispose();
    }
    expect(seen, {const Offset(250, 250)});
  });
}
