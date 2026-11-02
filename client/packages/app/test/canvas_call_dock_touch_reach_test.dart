// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock proven by real hit-testing, not by semantics-node existence,
/// with both a call and a canvas present at once - the phone-width case the
/// task that built this dock named directly: five tools, undo, the overflow,
/// close and four call controls do not all fit one row, so this is the
/// combination most likely to hide a clipped control behind a passing
/// semantics-only assertion.
///
/// `canvas_tools_row_touch_reach_test.dart` already proves the tool strip's
/// own scroll-then-tap journey in isolation; this file's job is narrower and
/// different: prove that combining a call section above it did not shrink,
/// clip, or steal the hit area of anything in *either* section.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/canvas_call_dock_fixtures.dart';

void main() {
  testWidgets('every call control is reachable by a bare tap, with no drag, even '
      'while the canvas tool strip below it is mid-scroll', (tester) async {
    final built = await pumpCanvasCallDock(
      tester,
      withCall: true,
      canvas: buildCanvasDockData(),
      width: 320,
      touch: true,
    );

    // Scrolled first, so this checks a control outside the strip while the strip itself is mid-scroll.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-1000, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(RegExp(r'^Mute')));
    await tester.pumpAndSettle();
    expect(
      built.controller!.state.microphoneEnabled,
      isFalse,
      reason: 'Mute must reach the real controller',
    );

    await tester.tap(find.bySemanticsLabel(RegExp(r'^Leave call')));
    await tester.pumpAndSettle();
    expect(
      built.session!.leaveCalls,
      1,
      reason: 'Leave call must reach the real session',
    );
  });

  testWidgets(
    'undo, the overflow and close are reachable by a bare tap with no '
    'drag, regardless of the tool strip beside them',
    (tester) async {
      var closed = 0;
      var undone = 0;
      await pumpCanvasCallDock(
        tester,
        withCall: true,
        canvas: buildCanvasDockData(
          onClose: () => closed++,
          onUndo: () => undone++,
          canUndo: true,
        ),
        width: 320,
        touch: true,
      );

      await tester.tap(find.bySemanticsLabel('Undo'), warnIfMissed: false);
      await tester.pump();
      expect(undone, 1);

      await tester.tap(find.bySemanticsLabel('Close canvas'));
      await tester.pump();
      expect(closed, 1);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      expect(find.text('Enter fullscreen'), findsOneWidget);
    },
  );

  testWidgets(
    'a tool clipped by the strip is unreachable by a bare tap and reachable '
    'once dragged, below any width the stacked tools row can fit',
    (tester) async {
      var placed = 0;
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(onToolChanged: (_) => placed++),
        width: 240,
        touch: true,
      );

      await tester.tap(find.bySemanticsLabel('Eraser'), warnIfMissed: false);
      await tester.pump();
      expect(
        placed,
        0,
        reason: 'a bare tap must not silently land on a clipped tool',
      );

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-1000, 0),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Eraser'));
      await tester.pump();
      expect(placed, 1);
    },
  );
}
