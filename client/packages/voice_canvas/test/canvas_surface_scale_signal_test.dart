// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web delivers ctrl-wheel and trackpad pinch as a scale signal.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
        kind: PointerDeviceKind.mouse,
        scale: 1.5,
      ),
    );
    await tester.pump();

    expect(document.camera.zoom, closeTo(1.5, 1e-9));
    expect(document.camera.x + 100 / 1.5, closeTo(world.dx, 1e-9));
    expect(document.camera.y + 100 / 1.5, closeTo(world.dy, 1e-9));
  });
}
