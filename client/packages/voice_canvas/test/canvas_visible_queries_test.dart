// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a screen reader, the bracket keys and a snapping drag ask the document about the objects in view.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _object(
  String id, {
  required int zIndex,
  CanvasObjectKind kind = CanvasObjectKind.stroke,
  double x = 10,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: zIndex + 1,
      zIndex: zIndex,
      x: x,
      y: 10,
      w: 30,
      h: 20,
      points: kind == CanvasObjectKind.stroke
          ? const [0, 0, 30, 20]
          : const <double>[],
      width: 2,
      colorKey: 'ink',
      kind: kind,
      text: kind == CanvasObjectKind.note ? 'text' : null,
    );

CanvasDocument _document(List<CanvasStrokeInput> objects) {
  final document = CanvasDocument()..setViewport(const Size(800, 600));
  objects.forEach(document.applyPlaced);
  return document..refresh();
}

void main() {
  test('boxes come before drawings, each group in paint order', () {
    final document = _document([
      _object('ink-top', zIndex: 5),
      _object('note-top', zIndex: 4, kind: CanvasObjectKind.note),
      _object('ink-bottom', zIndex: 0),
      _object('note-bottom', zIndex: 1, kind: CanvasObjectKind.note),
      _object('image', zIndex: 2, kind: CanvasObjectKind.image),
    ]);
    addTearDown(document.dispose);

    expect(document.visibleIdsInReadingOrder(), [
      'note-bottom',
      'image',
      'note-top',
      'ink-bottom',
      'ink-top',
    ]);
  });

  test('the limit keeps the boxes ahead of the drawings that crowd them', () {
    final document = _document([
      for (var i = 0; i < 60; i++) _object('ink$i', zIndex: i),
      _object('note', zIndex: 100, kind: CanvasObjectKind.note),
      _object('image', zIndex: 101, kind: CanvasObjectKind.image),
    ]);
    addTearDown(document.dispose);

    final ids = document.visibleIdsInReadingOrder(limit: 40);

    expect(ids, hasLength(40));
    expect(ids.take(2), ['note', 'image']);
    expect(ids.last, 'ink37');
  });

  test('objects out of view are left out', () {
    final document = _document([
      _object('near', zIndex: 1, kind: CanvasObjectKind.note),
      _object('far', zIndex: 2, kind: CanvasObjectKind.note, x: 9000),
    ]);
    addTearDown(document.dispose);

    expect(document.visibleIdsInReadingOrder(), ['near']);
  });

  test('snap targets are the boxes in view, without strokes or the mover', () {
    final document = _document([
      _object('ink', zIndex: 0),
      _object('note', zIndex: 1, kind: CanvasObjectKind.note, x: 100),
      _object('mover', zIndex: 2, kind: CanvasObjectKind.image, x: 200),
      _object('far', zIndex: 3, kind: CanvasObjectKind.note, x: 9000),
    ]);
    addTearDown(document.dispose);

    expect(document.visibleBoxRects(exceptId: 'mover'), [
      const Rect.fromLTWH(100, 10, 30, 20),
    ]);
    expect(document.visibleBoxRects(), hasLength(2));
  });
}
