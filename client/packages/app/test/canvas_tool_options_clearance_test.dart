// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pen and shape option menus open above the dock with a gap, never over
/// it: the audit measured the menu bottom border 6 px below the dock top.
/// A phone opens these as a bottom sheet, so only anchored widths apply.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_dock_tools.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_call_dock_fixtures.dart';

void main() {
  for (final width in [800.0, 1280.0, 1920.0]) {
    for (final tool in [CanvasTool.pen, CanvasTool.shape]) {
      testWidgets('the ${tool.name} options clear the dock by 8 px at '
          '$width wide', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await pumpCanvasCallDock(
          tester,
          withCall: true,
          width: width,
          canvas: buildCanvasDockData(tool: tool),
        );

        await tester.tap(
          find.descendant(
            of: find.byType(CanvasDockToolsRow),
            matching: find.byIcon(AppIcons.chevronDown),
          ),
        );
        await tester.pumpAndSettle();

        final dockTop = tester.getTopLeft(find.byType(FloatingDockCard)).dy;
        final menuBottom = tester.getBottomLeft(find.byType(AppMenu)).dy;
        expect(
          dockTop - menuBottom,
          greaterThanOrEqualTo(AppSpacing.s8),
          reason: 'menu bottom $menuBottom, dock top $dockTop',
        );
      });
    }
  }
}
