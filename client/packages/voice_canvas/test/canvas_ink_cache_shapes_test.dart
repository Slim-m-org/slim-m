// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shape's outline and an arrow's head reach past its box, and the texture patch must clear and repaint all of it.
/// A box padded for a pen line left an arrowhead's wing tip behind as ghost ink, and wiped one poking into a neighbour's box.
library;

import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';
import 'support/ink_texture_pixels.dart';

CanvasStrokeInput _shape(
  String id,
  CanvasShapeKind kind,
  Rect box,
) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: box.left,
      y: box.top,
      w: box.width,
      h: box.height,
      points: const [],
      width: 0,
      colorKey: 'ink',
      kind: CanvasObjectKind.shape,
      shapeKind: kind,
    );

CanvasStrokeInput _pen(String id, Rect box) => CanvasStrokeInput(
      id: id,
      seq: 2,
      zIndex: 2,
      x: box.left,
      y: box.top,
      w: box.width,
      h: box.height,
      points: Float32List.fromList(<double>[0, 0, box.width, box.height]),
      width: 2,
      colorKey: 'ink',
    );

/// An arrow drawn about level: its lower wing ends about five world units below its box.
const _arrow = Rect.fromLTWH(300, 300, 200, 8);

void main() {
  late CanvasDocument document;
  late StrokePainter painter;

  Future<void> warm(
    WidgetTester tester,
    Camera camera,
    List<CanvasStrokeInput> objects,
  ) async {
    document = CanvasDocument()..setViewport(inkTestSize);
    addTearDown(document.dispose);
    objects.forEach(document.applyPlaced);
    document
      ..setCamera(camera)
      ..refresh();
    painter = StrokePainter(document: document, ink: ink);
    addTearDown(painter.dispose);
    await warmInkTexture(tester, painter);
  }

  for (final zoom in [1.0, 4.0]) {
    testWidgets(
        'an arrow moved and then removed at ${(zoom * 100).round()}% leaves no '
        'wing behind', (tester) async {
      await warm(tester, Camera(x: 280, y: 280, zoom: zoom), [
        _shape('a', CanvasShapeKind.arrow, _arrow),
      ]);

      document
        ..moveObject('a', 300, 360, 200, 8)
        ..refresh();
      await expectInkMatchesLive(tester, painter, document);
      expect(painter.debugHasInkTexture, isTrue);

      document
        ..removeObject('a')
        ..refresh();
      await expectInkMatchesLive(tester, painter, document);
    });
  }

  testWidgets('a rectangle moved at 400% leaves no outline ring', (
    tester,
  ) async {
    await warm(tester, const Camera(x: 280, y: 280, zoom: 4), [
      _shape('r', CanvasShapeKind.rectangle,
          const Rect.fromLTWH(300, 300, 60, 40)),
    ]);

    document
      ..moveObject('r', 320, 360, 60, 40)
      ..refresh();
    await expectInkMatchesLive(tester, painter, document);
  });

  testWidgets('a stroke removed beside an arrow keeps the arrow\'s wing', (
    tester,
  ) async {
    await warm(tester, const Camera(x: 280, y: 280), [
      _shape('a', CanvasShapeKind.arrow, _arrow),
      _pen('p', const Rect.fromLTWH(470, 314, 30, 20)),
    ]);

    document
      ..removeObject('p')
      ..refresh();
    await expectInkMatchesLive(tester, painter, document);
  });
}
