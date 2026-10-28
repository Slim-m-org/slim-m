// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tool strip's order, keys and default, per decision 0047 point 5.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tool_model.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test(
    'the order is pan, pen, note, text, shape, eraser and covers every tool',
    () {
      expect(canvasToolOrder, [
        CanvasTool.pan,
        CanvasTool.pen,
        CanvasTool.note,
        CanvasTool.text,
        CanvasTool.shape,
        CanvasTool.eraser,
      ]);
      expect(canvasToolOrder.first, CanvasTool.pan);
      expect(canvasToolOrder.toSet(), CanvasTool.values.toSet());
    },
  );

  test('the keys are H P N T S E in strip order, one per tool', () {
    expect(canvasToolOrder.map((tool) => tool.shortcutKey), [
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyT,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyE,
    ]);
  });

  test('only the placement tools need a writable canvas', () {
    for (final tool in canvasToolOrder) {
      expect(tool.isAvailable(canDraw: true), isTrue, reason: '$tool');
    }
    expect(
      {
        for (final tool in canvasToolOrder)
          tool: tool.isAvailable(canDraw: false),
      },
      {
        CanvasTool.pan: true,
        CanvasTool.pen: false,
        CanvasTool.note: false,
        CanvasTool.text: false,
        CanvasTool.shape: false,
        CanvasTool.eraser: true,
      },
    );
  });

  test('every open starts on pan, never the pen', () {
    expect(canvasDefaultTool(), CanvasTool.pan);
  });
}
