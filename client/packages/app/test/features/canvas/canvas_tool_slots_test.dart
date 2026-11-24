// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A caret takes room only while its tool is armed, so the unarmed gaps stay
/// even, and every caret points the same way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_tools_row_fixtures.dart';

Widget _row(CanvasTool tool, {bool? touch}) => ProviderScope(
  overrides: [canvasStampsSupportedProvider.overrideWithValue(true)],
  child: wrapCanvasToolsRow(buildCanvasToolsRow(tool: tool), touch: touch),
);

void main() {
  testWidgets('arming a tool moves only the buttons after its caret, by the '
      'caret width', (tester) async {
    Future<Map<String, double>> lefts(CanvasTool tool) async {
      await tester.pumpWidget(_row(tool, touch: false));
      return {
        for (final label in ['Pan', 'Pen', 'Eraser', 'Note', 'Text', 'Shape'])
          label: tester.getTopLeft(find.bySemanticsLabel(label).first).dx,
      };
    }

    final baseline = await lefts(CanvasTool.pan);
    final armed = await lefts(CanvasTool.pen);
    expect(armed['Pan'], baseline['Pan']);
    expect(armed['Pen'], baseline['Pen']);
    final shift = armed['Eraser']! - baseline['Eraser']!;
    expect(shift, AppSizes.rowPointer);
    for (final label in ['Note', 'Text', 'Shape']) {
      expect(armed[label]! - baseline[label]!, shift, reason: label);
    }
  });

  testWidgets('every options caret points down', (tester) async {
    for (final tool in [CanvasTool.pen, CanvasTool.shape, CanvasTool.stamp]) {
      await tester.pumpWidget(_row(tool));
      expect(find.byIcon(AppIcons.chevronUp), findsNothing, reason: '$tool');
      expect(
        find.byIcon(AppIcons.chevronDown),
        findsOneWidget,
        reason: '$tool',
      );
    }
  });
}
