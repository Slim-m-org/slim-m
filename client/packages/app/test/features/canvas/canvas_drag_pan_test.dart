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
}
