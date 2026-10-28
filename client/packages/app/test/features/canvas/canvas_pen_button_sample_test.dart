// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pen button wears a dot of the armed colour, a little larger for a
/// thicker pen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_tools_row_fixtures.dart';

Finder get _dot => find.descendant(
  of: find.ancestor(
    of: find.byIcon(AppIcons.pen),
    matching: find.byType(Stack),
  ),
  matching: find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).shape == BoxShape.circle,
  ),
);

void main() {
  for (final width in [
    canvasPenMinWidth,
    canvasDefaultPenWidth,
    canvasPenMaxWidth,
  ]) {
    for (final color in [canvasPenColors.first, canvasPenColors[3]]) {
      testWidgets('$width px ${color.label} shows as a round dot in that '
          'colour', (tester) async {
        await tester.pumpWidget(
          wrapCanvasToolsRow(
            buildCanvasToolsRow(
              tool: CanvasTool.pan,
              pen: CanvasPenStyle(colorKey: color.key, width: width),
            ),
          ),
        );

        final box = tester.widget<Container>(_dot);
        expect((box.decoration! as BoxDecoration).color, color.color);
        final size = tester.getSize(_dot);
        expect(size.width, size.height, reason: 'a dot, not a line');
      });
    }
  }

  testWidgets('a thicker pen draws a larger dot at once', (tester) async {
    var pen = const CanvasPenStyle(width: 1.5);
    late StateSetter set;
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return buildCanvasToolsRow(tool: CanvasTool.pan, pen: pen);
          },
        ),
      ),
    );
    final thin = tester.getSize(_dot).width;

    set(() => pen = pen.copyWith(width: 6));
    await tester.pump();
    expect(tester.getSize(_dot).width, greaterThan(thin));
  });
}
