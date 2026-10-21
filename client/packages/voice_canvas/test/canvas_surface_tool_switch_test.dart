// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tool change while a pointer is down must close the old tool's gesture.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('switching tool mid-erase still ends the erase gesture', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var eraseEnds = 0;
    var strokes = 0;
    final tool = ValueNotifier(CanvasTool.eraser);
    addTearDown(tool.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<CanvasTool>(
          valueListenable: tool,
          builder: (context, value, child) => CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: value,
            onStroke: (_) => strokes++,
            onErase: (_) {},
            onEraseEnd: () => eraseEnds++,
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    tool.value = CanvasTool.pen;
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(eraseEnds, 1, reason: 'the erase never submitted its batch');
    expect(strokes, 0, reason: 'the new tool must not commit a stray stroke');
  });
}
