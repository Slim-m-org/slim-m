// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A stroke belongs to the pointer whose accepted primary press began it:
/// a finger that survives a pinch, or a press that never began a draft,
/// must not draw when it moves afterwards.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('the surviving finger of a pinch does not draw a stroke', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final strokes = <List<Offset>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: strokes.add,
        ),
      ),
    );

    final first = await tester.startGesture(
      const Offset(100, 100),
      pointer: 1,
    );
    final second = await tester.startGesture(
      const Offset(200, 200),
      pointer: 2,
    );
    await second.up();
    await first.moveBy(const Offset(30, 30));
    await first.moveBy(const Offset(30, 30));
    await first.up();
    await tester.pump();

    expect(strokes, isEmpty);
  });
}
