// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pen button wears a short bar of the armed colour under its glyph, a
/// little thicker for a thicker pen, and never a stray dot.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_pen_style.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tool_buttons.dart'
    show penBarOutline;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_tools_row_fixtures.dart';

Finder get _bar => find.byKey(const ValueKey('pen-colour-bar'));

void main() {
  clearanceTests();
  for (final width in [
    canvasPenMinWidth,
    canvasDefaultPenWidth,
    canvasPenMaxWidth,
  ]) {
    for (final color in [canvasPenColors.first, canvasPenColors[3]]) {
      testWidgets('$width px ${color.label} shows as a bar in that colour '
          'under the glyph', (tester) async {
        await tester.pumpWidget(
          wrapCanvasToolsRow(
            buildCanvasToolsRow(
              tool: CanvasTool.pan,
              pen: CanvasPenStyle(colorKey: color.key, width: width),
            ),
          ),
        );

        final box = tester.widget<Container>(_bar);
        expect((box.decoration! as BoxDecoration).color, color.color);
        final size = tester.getSize(_bar);
        expect(
          size.width,
          greaterThan(size.height),
          reason: 'a bar, not a dot',
        );
        final button = tester.getRect(
          find.ancestor(
            of: find.byIcon(AppIcons.pen),
            matching: find.byType(AppIconButton),
          ),
        );
        expect(
          tester.getCenter(_bar).dx,
          closeTo(tester.getCenter(find.byIcon(AppIcons.pen)).dx, 0.5),
          reason: 'centred under the glyph, not in a corner',
        );
        expect(tester.getRect(_bar).bottom, lessThanOrEqualTo(button.bottom));
        final glyph = tester.getRect(find.byIcon(AppIcons.pen));
        expect(
          tester.getRect(_bar).top - glyph.bottom,
          lessThan(4),
          reason: "hugs the glyph",
        );
        expect(tester.getRect(_bar).top, greaterThan(button.center.dy));
      });
    }
  }

  testWidgets('a thicker pen draws a thicker bar at once', (tester) async {
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
    final thin = tester.getSize(_bar).height;

    set(() => pen = pen.copyWith(width: 8));
    await tester.pump();
    expect(tester.getSize(_bar).height, greaterThan(thin));
  });
}

void clearanceTests() {
  testWidgets('the pen bar keeps clear of the pill bottom', (tester) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(tool: CanvasTool.pen)),
    );
    final button = tester.getRect(
      find.ancestor(
        of: find.byIcon(AppIcons.pen),
        matching: find.byType(AppIconButton),
      ),
    );
    expect(
      button.bottom - tester.getRect(_bar).bottom,
      greaterThanOrEqualTo(4),
    );
  });

  test('a near-black or near-white pen gets a hairline, a mid colour none', () {
    expect(penBarOutline(const Color(0xFF0A0A0A)), isNotNull);
    expect(penBarOutline(const Color(0xFFF8F8F8)), isNotNull);
    expect(penBarOutline(const Color(0xFFE5604F)), isNull);
  });
}
