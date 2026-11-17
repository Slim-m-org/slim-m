// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Arming a tool never moves the buttons: pen, shape and stamp each keep
/// their caret slot, and every caret points the same way.
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
  for (final touch in [false, true]) {
    testWidgets('no button moves when a tool is armed (touch: $touch)', (
      tester,
    ) async {
      Future<Map<String, double>> lefts(CanvasTool tool) async {
        await tester.pumpWidget(_row(tool, touch: touch));
        return {
          for (final label in [
            'Pan',
            'Pen',
            'Note',
            'Text',
            'Shape',
            'Stamp',
            'Eraser',
          ])
            label: tester
                .getTopLeft(
                  find
                      .ancestor(
                        of: find.bySemanticsLabel(label),
                        matching: find.byType(AppIconButton),
                      )
                      .first,
                )
                .dx,
        };
      }

      final baseline = await lefts(CanvasTool.pan);
      for (final tool in [CanvasTool.pen, CanvasTool.shape, CanvasTool.stamp]) {
        expect(await lefts(tool), baseline, reason: 'armed: $tool');
      }
    });
  }

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
