// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tile is a rectangle the app fills: hit across its box, listed with its
/// box and key in paint order, counted on its own, and left out once removed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _tile(String id, Rect box, {int z = 1, String? key}) =>
    CanvasStrokeInput(
      id: id,
      seq: z,
      zIndex: z,
      x: box.left,
      y: box.top,
      w: box.width,
      h: box.height,
      points: const [],
      width: 0,
      colorKey: '',
      kind: CanvasObjectKind.tile,
      tileKey: key ?? 'mod/$id',
    );

void main() {
  late CanvasDocument document;

  setUp(() {
    document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(_tile('back', const Rect.fromLTWH(100, 100, 300, 200)))
      ..applyPlaced(
        _tile('front', const Rect.fromLTWH(200, 150, 300, 200), z: 5),
      )
      ..refresh();
  });

  tearDown(() => document.dispose());

  test('it lists every tile in view with its box, back to front', () {
    expect(document.visibleTiles, [
      (
        id: 'back',
        rect: const Rect.fromLTWH(100, 100, 300, 200),
        tileKey: 'mod/back',
      ),
      (
        id: 'front',
        rect: const Rect.fromLTWH(200, 150, 300, 200),
        tileKey: 'mod/front',
      ),
    ]);
  });

  test('a press anywhere in its box hits the topmost tile', () {
    expect(hitTestTopmost(document, const Offset(120, 120)), 'back');
    expect(hitTestTopmost(document, const Offset(300, 200)), 'front');
    expect(hitTestTopmost(document, const Offset(700, 500)), isNull);
  });

  test('a moved tile is listed at its new box', () {
    document
      ..moveObject('back', 10, 20, 300, 200)
      ..refresh();
    expect(
      document.visibleTiles.first.rect,
      const Rect.fromLTWH(10, 20, 300, 200),
    );
  });

  test('a removed tile is no longer listed or counted', () {
    expect(document.liveCountsByKind.tiles, 2);
    document
      ..kill('front')
      ..refresh();
    expect(document.visibleTiles.map((t) => t.id), ['back']);
    expect(document.liveCountsByKind.tiles, 1);
    expect(document.liveCountsByKind.images, 0);
  });

  test('a tile off screen is not listed', () {
    document
      ..setCamera(const Camera(x: 5000, y: 5000))
      ..refresh();
    expect(document.visibleTiles, isEmpty);
  });
}
