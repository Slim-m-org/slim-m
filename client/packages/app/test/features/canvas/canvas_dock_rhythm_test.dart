// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock draws one rhythm: equal gaps inside every group and equal room on
/// both sides of every group divider.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_edge_style.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_overflow_menu.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_tools_row_fixtures.dart';

Future<void> _pump(WidgetTester tester, {required bool touch}) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [
          canvasEdgesSupportedProvider.overrideWithValue(true),
          canvasStampsSupportedProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: AppTouchTargets(
                enabled: touch,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: buildCanvasToolsRow(tool: CanvasTool.pan),
                ),
              ),
            ),
          ),
        ),
      ),
    );

Rect _button(WidgetTester tester, String label) => tester.getRect(
  find
      .byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label)
      .first,
);

void main() {
  for (final touch in [false, true]) {
    testWidgets('gaps inside a group are equal and dividers are centred '
        '(${touch ? 'touch' : 'pointer'})', (tester) async {
      tester.view.physicalSize = const Size(2400, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, touch: touch);

      final groups = [
        for (final labels in [
          ['Pan', 'Pen', 'Eraser'],
          ['Note', 'Text', 'Shape', 'Connect', 'Stamp'],
          ['Undo', 'Redo'],
        ])
          [for (final l in labels) _button(tester, l)],
        [
          tester.getRect(
            find.byWidgetPredicate((w) => w is CanvasOverflowMenu),
          ),
        ],
      ];
      final expectedGap = touch ? 0.0 : AppSpacing.s4;
      for (final group in groups) {
        for (var i = 1; i < group.length; i++) {
          expect(
            group[i].left - group[i - 1].right,
            closeTo(expectedGap, 0.01),
          );
        }
      }

      final dividers = find.byWidgetPredicate((w) => w is DockVerticalDivider);
      expect(dividers, findsNWidgets(groups.length - 1));
      for (var i = 0; i < groups.length - 1; i++) {
        final rule = tester.getRect(dividers.at(i));
        expect(
          rule.left - groups[i].last.right,
          closeTo(touch ? 0 : AppSpacing.s8, 0.01),
          reason: 'before divider $i',
        );
        expect(
          groups[i + 1].first.left - rule.right,
          closeTo(touch ? 0 : AppSpacing.s8, 0.01),
          reason: 'after divider $i',
        );
      }
    });
  }
}
