// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web delivers ctrl-wheel and trackpad pinch as a scale signal.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('a scale signal zooms about the pointer', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
        ),
      ),
    );
    await tester.pump();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(const Offset(100, 100)),
    );
    final world = Offset(
      document.camera.x + 100 / document.camera.zoom,
      document.camera.y + 100 / document.camera.zoom,
    );
    await tester.sendEventToBinding(
      const PointerScaleEvent(
        position: Offset(100, 100),
        device: 1,
        kind: PointerDeviceKind.trackpad,
        scale: 1.5,
      ),
    );
    await tester.pump();

    expect(document.camera.zoom, closeTo(1.5, 1e-9));
    expect(document.camera.x + 100 / 1.5, closeTo(world.dx, 1e-9));
    expect(document.camera.y + 100 / 1.5, closeTo(world.dy, 1e-9));
  });

  testWidgets('a mouse wheel scale notch is held to one wheel step', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
        ),
      ),
    );
    await tester.pump();

    await tester.sendEventToBinding(
      const PointerScaleEvent(
        position: Offset(100, 100),
        device: 1,
        kind: PointerDeviceKind.mouse,
        scale: 1.82,
      ),
    );
    await tester.pump();

    expect(document.camera.zoom, closeTo(maxWheelZoomStep, 1e-9));
  });

  testWidgets(
    'scale and trackpad pan-zoom signals reach a board zoom floor below minZoom',
    (tester) async {
      tester.view.physicalSize = const Size(500, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final document = CanvasDocument()
        ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
        ..setViewport(const Size(500, 400));
      addTearDown(document.dispose);
      final floor = document.zoomFloor;
      expect(floor, lessThan(minZoom));
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            onStroke: (_) {},
          ),
        ),
      );
      await tester.pump();

      await tester.sendEventToBinding(
        const PointerScaleEvent(
          position: Offset(100, 100),
          device: 1,
          kind: PointerDeviceKind.trackpad,
          scale: 0.01,
        ),
      );
      await tester.pump();
      expect(document.camera.zoom, closeTo(floor, 1e-6));

      document.setCamera(document.camera.copyWith(zoom: 1));
      await tester.sendEventToBinding(
        const PointerPanZoomStartEvent(position: Offset(100, 100), device: 2),
      );
      await tester.sendEventToBinding(
        const PointerPanZoomUpdateEvent(
          position: Offset(100, 100),
          device: 2,
          scale: 0.01,
        ),
      );
      await tester.sendEventToBinding(
        const PointerPanZoomEndEvent(position: Offset(100, 100), device: 2),
      );
      await tester.pump();
      expect(document.camera.zoom, closeTo(floor, 1e-6));
    },
  );

  testWidgets(
    'holding Space and dragging with the primary mouse button pans the camera without drawing',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var strokes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            onStroke: (_) => strokes++,
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(const Offset(100, 100), buttons: kPrimaryButton),
      );
      await tester.sendEventToBinding(pointer.move(const Offset(60, 130)));
      await tester.sendEventToBinding(pointer.up());
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(strokes, 0);
      expect(document.camera.x, 40);
      expect(document.camera.y, -30);
    },
  );
}
