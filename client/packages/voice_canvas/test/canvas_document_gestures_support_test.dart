// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Document state the gesture owner leans on: a viewport that has no size yet
/// does not count as "fitted", and the pieces of one mark answer together.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _piece(String id, {String? group, int z = 1}) =>
    CanvasStrokeInput(
      id: id,
      seq: z,
      zIndex: z,
      x: 0,
      y: 0,
      w: 10,
      h: 0,
      points: const [0, 0, 10, 0],
      width: 3,
      colorKey: 'annotation',
      groupId: group,
    );

void main() {
  test('a zero-size layout does not make the camera look fitted', () {
    final document = CanvasDocument()
      ..setViewport(const Size(800, 600))
      ..setBoard(canvasBoard);
    document.setCamera(const Camera(x: 200, y: 100, zoom: 2));
    expect(document.isFitted, isFalse);

    document.setViewport(Size.zero);
    document.setViewport(const Size(800, 600));

    expect(document.camera.zoom, 2);
    expect(document.isFitted, isFalse);
  });

  test('the zoom floor is the board fit when that sits under the usual floor',
      () {
    final document = CanvasDocument()
      ..setViewport(const Size(400, 225))
      ..setBoard(canvasBoard);

    expect(document.zoomFloor, lessThan(minZoom));
  });

  test('pieces of one mark answer together and a loner answers alone', () {
    final document = CanvasDocument()
      ..applyPlaced(_piece('a', group: 'g'))
      ..applyPlaced(_piece('b', group: 'g'))
      ..applyPlaced(_piece('c'));

    expect(document.groupOf('a'), unorderedEquals(['a', 'b']));
    expect(document.groupOf('c'), ['c']);
  });

  test('a removed piece drops out of its mark', () {
    final document = CanvasDocument()
      ..applyPlaced(_piece('a', group: 'g'))
      ..applyPlaced(_piece('b', group: 'g'))
      ..removeObject('b');

    expect(document.groupOf('a'), ['a']);
  });
}
