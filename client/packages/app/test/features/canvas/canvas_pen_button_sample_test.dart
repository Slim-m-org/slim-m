// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pen button wears the armed colour and thickness, at the size the stroke
/// will have on the drawer's own screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_tools_row_fixtures.dart';

Finder get _sample => find.descendant(
  of: find.ancestor(
    of: find.byIcon(AppIcons.pen),
    matching: find.byType(Stack),
  ),
  matching: find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.constraints?.maxWidth ?? 0) > 0 &&
        (w.constraints?.maxHeight ?? 99) < 7,
  ),
);

void main() {
  for (final width in canvasPenWidths) {
    for (final color in [canvasPenColors.first, canvasPenColors[3]]) {
      testWidgets('${width.label} ${color.label} shows as a ${width.width}px '
          'sample in that colour', (tester) async {
        await tester.pumpWidget(
          wrapCanvasToolsRow(
            buildCanvasToolsRow(
              tool: CanvasTool.pan,
              pen: CanvasPenStyle(colorKey: color.key, width: width.width),
            ),
          ),
        );

        final box = tester.widget<Container>(_sample);
        expect(box.constraints!.maxHeight, width.width);
        expect((box.decoration! as BoxDecoration).color, color.color);
        expect(tester.getSize(_sample).height, width.width);
      });
    }
  }

  testWidgets('choosing another width changes the sample at once', (
    tester,
  ) async {
    var pen = const CanvasPenStyle();
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
    expect(tester.getSize(_sample).height, canvasDefaultPenWidth);

    set(() => pen = pen.copyWith(width: 6));
    await tester.pump();
    expect(tester.getSize(_sample).height, 6);
  });
}
