// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Paint order ties, a failed stroke whose commit landed, and the pending
/// stroke placeholder layer (issues 2040, 2039, 2038).
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _stroke(String id, {required int zIndex, required int seq}) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: zIndex,
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      points: const [0, 0, 10, 10],
      width: 3,
      colorKey: 'annotation',
    );

CanvasDocument _document() =>
    CanvasDocument()..setViewport(const Size(800, 600));

void main() {
  test('equal z-indexes paint in the order the server placed them', () {
    final document = _document();
    for (final (id, seq) in [('late', 9), ('early', 2), ('middle', 5)]) {
      document.applyPlaced(_stroke(id, zIndex: 4, seq: seq));
    }
    document.refresh();
    expect(
      document.paintOrder.map((slot) => document.strokeAt(slot).id),
      ['early', 'middle', 'late'],
    );
  });

  test('a stroke killed as failed comes back when its commit lands', () {
    final document = _document();
    document.applyPlaced(_stroke('s', zIndex: 1, seq: 0));
    document.kill('s');
    expect(document.objectCount.value, 0);

    document
      ..applyPlaced(_stroke('s', zIndex: 1, seq: 7))
      ..refresh();
    expect(document.objectCount.value, 1);
    expect(
        document.paintOrder.map((slot) => document.strokeAt(slot).id), ['s']);
  });

  test('a pending stroke placeholder layer is left out of the z-index range',
      () {
    final document = _document();
    document.applyPlaced(_stroke('a', zIndex: 3, seq: 1));
    document.applyPlaced(_stroke('b', zIndex: 8, seq: 2));
    document.applyPlaced(
        _stroke('pending', zIndex: provisionalLocalZIndex, seq: 0));
    expect(document.zIndexRange, (3, 8));
  });
}
