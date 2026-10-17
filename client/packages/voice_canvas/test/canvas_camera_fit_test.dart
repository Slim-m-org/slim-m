// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [cameraToFit] and [CanvasDocument.contentBounds]: what "Recenter" fits
/// the camera to instead of resetting to the world origin.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _box(String id, {required double x, required double y}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: x,
      y: y,
      w: 40,
      h: 40,
      points: const [],
      width: 0,
      colorKey: 'shape',
      kind: CanvasObjectKind.shape,
      authorId: 'me',
    );

void main() {
  test('contentBounds is null with nothing drawn', () {
    final document = CanvasDocument();
    addTearDown(document.dispose);

    expect(document.contentBounds, isNull);
  });

  test(
      'contentBounds is the union of every live object, ignoring removed '
      'ones', () {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document
      ..applyPlaced(_box('a', x: 100, y: 100))
      ..applyPlaced(_box('b', x: -50, y: 900))
      ..applyPlaced(_box('gone', x: 5000, y: 5000));
    document.removeObject('gone');

    final bounds = document.contentBounds!;
    expect(bounds.left, -50);
    expect(bounds.top, 100);
    expect(bounds.right, 140);
    expect(bounds.bottom, 940);
  });

  test(
      'cameraToFit falls back to the origin with no bounds or no measured '
      'viewport', () {
    expect(cameraToFit(null, const Size(800, 600)), const Camera());
    const bounds = Rect.fromLTWH(100, 100, 40, 40);
    expect(cameraToFit(bounds, Size.zero), const Camera());
  });

  test('cameraToFit brings distant content into the resulting world view', () {
    const bounds = Rect.fromLTWH(5000, -3000, 40, 40);

    final camera = cameraToFit(bounds, const Size(1000, 800));

    final view = Rect.fromLTWH(
      camera.x,
      camera.y,
      1000 / camera.zoom,
      800 / camera.zoom,
    );
    expect(view.overlaps(bounds), isTrue);
    expect(view.contains(bounds.center), isTrue);
  });

  test(
      'cameraToFit clamps zoom rather than zooming in past maxZoom for a '
      'single small object', () {
    final camera = cameraToFit(
      const Rect.fromLTWH(0, 0, 2, 2),
      const Size(1000, 800),
    );

    expect(camera.zoom, lessThanOrEqualTo(maxZoom));
  });
}
