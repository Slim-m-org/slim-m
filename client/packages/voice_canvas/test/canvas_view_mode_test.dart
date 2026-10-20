// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal view moves a tile and the camera for one viewer only, never
/// leaves the board, and switching back returns the shared arrangement.
/// Decision 0082.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _shared = Rect.fromLTWH(100, 100, 360, 203);
const _viewport = Size(1280, 720);

void main() {
  late CanvasDocument document;
  late CanvasPresenceTileOverrides tiles;
  late CanvasViewMode mode;

  setUp(() {
    document = CanvasDocument()
      ..setBoard(canvasBoard)
      ..setViewport(_viewport);
    tiles = CanvasPresenceTileOverrides()..board = canvasBoard;
    mode = CanvasViewMode(document: document, tiles: tiles);
    tiles.applyServer(
      'screen:a',
      rect: _shared,
      locked: false,
      sentToBack: false,
    );
  });

  tearDown(() {
    mode.dispose();
    tiles.dispose();
    document.dispose();
  });

  test('a personal drag moves the tile for this viewer only', () {
    mode.showPersonal();
    tiles.setRect('screen:a', const Rect.fromLTWH(900, 500, 360, 203));

    expect(tiles.stateFor('screen:a').rect,
        const Rect.fromLTWH(900, 500, 360, 203));
    expect(tiles.sharedRectFor('screen:a'), _shared);
  });

  test('back in the shared view the shared rect is what is painted', () {
    mode.showPersonal();
    tiles.setRect('screen:a', const Rect.fromLTWH(900, 500, 360, 203));
    mode.showShared();

    expect(tiles.stateFor('screen:a').rect, _shared);
    mode.showPersonal();
    expect(tiles.stateFor('screen:a').rect,
        const Rect.fromLTWH(900, 500, 360, 203));
  });

  test('a shared drag in the shared view still writes the shared rect', () {
    tiles.setRect('screen:a', const Rect.fromLTWH(50, 60, 360, 203));

    expect(
        tiles.sharedRectFor('screen:a'), const Rect.fromLTWH(50, 60, 360, 203));
  });

  test('a server update never overwrites the personal place', () {
    mode.showPersonal();
    tiles.setRect('screen:a', const Rect.fromLTWH(900, 500, 360, 203));
    tiles.applyServer(
      'screen:a',
      rect: const Rect.fromLTWH(10, 10, 360, 203),
      locked: true,
      sentToBack: false,
    );

    expect(tiles.stateFor('screen:a').rect,
        const Rect.fromLTWH(900, 500, 360, 203));
    expect(
        tiles.sharedRectFor('screen:a'), const Rect.fromLTWH(10, 10, 360, 203));
    expect(tiles.stateFor('screen:a').locked, isTrue);
  });

  test('a personal tile cannot leave the board', () {
    mode.showPersonal();
    tiles.setRect('screen:a', const Rect.fromLTWH(1800, 1000, 360, 203));

    final placed = tiles.stateFor('screen:a').rect!;
    expect(boardHoldsBox(canvasBoard, placed), isTrue);
  });

  test('the personal camera is remembered across a trip to the shared view',
      () {
    mode.showPersonal();
    document.setCamera(const Camera(x: 400, y: 200, zoom: 1.5));
    final own = document.camera;

    mode.showShared();
    expect(document.isFitted, isTrue);

    mode.showPersonal();
    expect(document.camera, own);
    expect(document.camera.zoom,
        greaterThan(boardFitZoom(canvasBoard, _viewport)));
  });

  test('switching modes notifies listeners once each', () {
    var heard = 0;
    mode.addListener(() => heard++);

    mode.toggle();
    mode.toggle();
    mode.showShared();

    expect(heard, 2);
  });
}
