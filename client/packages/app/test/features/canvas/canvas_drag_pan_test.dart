// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Owner report: "unable to drag with one finger while on move tool on
/// mobile, need to do two finger drag". A one-finger drag on empty board with
/// the pan tool pans a zoomed-in board.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

void main() {
  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('one ${kind.name} drag on empty board pans a zoomed board', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container, board: true, tool: null);
      final document = surfaceDocument(tester);
      document.setCamera(
        document.camera.copyWith(zoom: document.camera.zoom * 6),
      );
      await tester.pump();
      final before = document.camera;

      final surface = tester.getRect(find.byType(CanvasSurface));
      final gesture = await tester.startGesture(surface.center, kind: kind);
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(-20, -15));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();

      final after = document.camera;
      expect(after.x, greaterThan(before.x + 1));
      expect(after.y, greaterThan(before.y + 1));
    });
  }

  Future<(CanvasDocument, Rect)> pumpZoomed(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    final document = surfaceDocument(tester);
    document.setCamera(
      document.camera.copyWith(zoom: document.camera.zoom * 6),
    );
    await tester.pump();
    return (document, tester.getRect(find.byType(CanvasSurface)));
  }

  testWidgets(
    'a touch tap that jitters a few pixels does not move the camera',
    (tester) async {
      final (document, surface) = await pumpZoomed(tester);
      final before = document.camera;

      final gesture = await tester.startGesture(surface.center);
      await gesture.moveBy(const Offset(3, 2));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(document.camera, before);
    },
  );

  testWidgets('a pan that passes the slop does not lurch by it', (
    tester,
  ) async {
    final (document, surface) = await pumpZoomed(tester);
    final before = document.camera;

    final gesture = await tester.startGesture(surface.center);
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump();
    await gesture.up();

    final moved = (document.camera.x - before.x) * document.camera.zoom;
    expect(moved, closeTo(10, 0.5), reason: 'only the move past the crossing');
  });

  testWidgets('one finger lifting after a pinch leaves the camera alone', (
    tester,
  ) async {
    final (document, surface) = await pumpZoomed(tester);

    final first = await tester.startGesture(
      surface.center - const Offset(40, 0),
    );
    final second = await tester.startGesture(
      surface.center + const Offset(40, 0),
    );
    await first.moveBy(const Offset(-30, 0));
    await second.moveBy(const Offset(30, 0));
    await tester.pump();
    await second.up();
    await tester.pump();
    final afterPinch = document.camera;

    await first.moveBy(const Offset(0, -25));
    await tester.pump();
    await first.up();
    await tester.pump();

    expect(document.camera, afterPinch);
  });
}
