// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `objectIdsNear` answers from the spatial index, so a board far from the point costs nothing to ask about.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _image(String id, double x, double y, {int z = 0}) =>
    CanvasStrokeInput(
      id: id,
      seq: z,
      zIndex: z,
      x: x,
      y: y,
      w: 50,
      h: 50,
      points: const [],
      width: 0,
      colorKey: '',
      kind: CanvasObjectKind.image,
      attachmentId: 'sha-$id',
    );

void main() {
  test('far objects are not returned and near ones come back bottom first', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(_image('upper', 0, 0, z: 2))
      ..applyPlaced(_image('lower', 10, 10, z: 1));
    for (var i = 0; i < 400; i++) {
      document.applyPlaced(_image('far$i', 5000 + i * 60.0, 5000));
    }
    document.refresh();

    final near = objectIdsNear(document, const Offset(30, 30), 20);

    expect(near, ['lower', 'upper']);
  });

  test('a removed object is not returned', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(_image('gone', 0, 0))
      ..refresh()
      ..removeObject('gone')
      ..refresh();

    expect(objectIdsNear(document, const Offset(10, 10), 20), isEmpty);
  });
}
