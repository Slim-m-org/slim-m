// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pinch moves the camera once per gesture event: each camera change culls the scene and wakes every listener.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_camera_pinch.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _viewport = Size(800, 600);

/// The zoom-then-pan pair a pinch used to apply, as the reference behaviour.
Camera _zoomThenPan(
  CanvasDocument document,
  Camera start,
  Offset anchor,
  Offset focal,
  double scale,
) {
  document.setCamera(start.copyWith(zoom: start.zoom * scale));
  final camera = document.camera;
  document.setCamera(
    camera.copyWith(
      x: anchor.dx - focal.dx / camera.zoom,
      y: anchor.dy - focal.dy / camera.zoom,
    ),
  );
  return document.camera;
}

CanvasDocument _document({Rect? board}) {
  final document = CanvasDocument()..setViewport(_viewport);
  if (board != null) document.setBoard(board);
  return document;
}

void main() {
  const scales = <double>[0.2, 0.9, 1, 1.4, 3, 50, 1e6];
  const focals = [Offset(400, 300), Offset(10, 590), Offset(790, 20)];

  for (final board in [null, const Rect.fromLTWH(0, 0, 4000, 3000)]) {
    test('one set lands where zoom-then-pan did (board: $board)', () {
      final reference = _document(board: board);
      final single = _document(board: board);
      addTearDown(reference.dispose);
      addTearDown(single.dispose);
      final start = reference.camera.copyWith(zoom: 1.5, x: 300, y: 250);
      reference.setCamera(start);
      single.setCamera(start);

      for (final scale in scales) {
        for (final focal in focals) {
          reference.setCamera(start);
          single.setCamera(start);
          final anchor = Offset(
            start.x + focal.dx / start.zoom,
            start.y + focal.dy / start.zoom,
          );

          final expected = _zoomThenPan(reference, start, anchor, focal, scale);
          single.setCamera(
            cameraAfterPinch(
              single.camera,
              anchor: anchor,
              focal: focal,
              scale: scale,
              zoomFloor: single.zoomFloor,
            ),
          );

          expect(single.camera, expected, reason: 'scale $scale at $focal');
        }
      }
    });
  }

  testWidgets('a pinch update notifies the document once', (tester) async {
    final document = _document();
    addTearDown(document.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.pan,
          onStroke: (_) {},
        ),
      ),
    );
    await tester.pump();
    document.setCamera(const Camera(x: 1000, y: 1000));

    final first = await tester.startGesture(const Offset(300, 300));
    final second = await tester.startGesture(const Offset(400, 300));
    await second.moveBy(const Offset(40, 0));
    await second.moveBy(const Offset(40, 0));
    var notifies = 0;
    document.addListener(() => notifies++);

    await second.moveBy(const Offset(20, 0));

    expect(notifies, 1, reason: 'zoom and pan together are one camera change');
    await first.up();
    await second.up();
  });
}
