// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A secondary-button press belongs to the context menu, never to the armed tool.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  for (final tool in [CanvasTool.eraser, CanvasTool.note, CanvasTool.shape]) {
    testWidgets('right-click with the ${tool.name} tool acts on nothing', (
      tester,
    ) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var acted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: tool,
            onStroke: (_) {},
            onErase: (_) => acted++,
            onNotePlace: (_) => acted++,
            onShapePlace: (c, s, {flipX = false, flipY = false}) => acted++,
          ),
        ),
      );
      final at = tester.getCenter(find.byType(CanvasSurface));
      final mouse = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await tester.pump();
      expect(acted, 0);
    });
  }
}
