// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A restore replayed for an id that is still live must not make the next
/// fetch of that object paint a second copy.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput stroke(String id) => CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      points: const [0, 0, 10, 10],
      width: 3,
      colorKey: 'annotation',
    );

void main() {
  test('forgetRemoved on a live id does not let a refetch double the ink', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a'))
      ..refresh();
    expect(document.objectCount.value, 1);

    document.forgetRemoved(['a']);
    document
      ..applyPlaced(stroke('a'))
      ..refresh();

    expect(document.objectCount.value, 1);
    expect(document.paintOrder, hasLength(1));
  });
}
