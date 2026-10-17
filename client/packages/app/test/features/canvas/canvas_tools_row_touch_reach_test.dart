// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tool strip's own scroll behaviour at a phone width: a tool clipped
/// past the visible strip is not reachable by a bare tap, and the edge fade
/// is the only on-screen cue that more sits past the edge it fades toward.
/// Split out of `canvas_tools_row_test.dart` once this pushed it past the
/// 500-line hard limit, the same reason `canvas_bar_touch_reach_test.dart`,
/// this file's predecessor, already was.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tools_row.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_tools_row_fixtures.dart';

void main() {
  /// A tool clipped by the strip's own scroll viewport is not the same as
  /// a broken button: a bare tap misses it, at the exact offset the tool
  /// strip's own layout puts it at, until a real drag reveals it first -
  /// the same journey a thumb on a phone would need.
  testWidgets(
    'a clipped tool is unreachable by a bare tap, and reachable once the '
    'strip is dragged',
    (tester) async {
      CanvasTool? chosen;
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(onToolChanged: (tool) => chosen = tool),
          width: 270,
          touch: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Eraser'), warnIfMissed: false);
      await tester.pump();
      expect(
        chosen,
        isNull,
        reason: 'a bare tap must not silently land on a clipped tool',
      );

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-1000, 0),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Eraser'));
      await tester.pump();
      expect(chosen, CanvasTool.eraser);
    },
  );

  /// The fade is the only on-screen cue that a tool sits past the visible
  /// strip; without it a clipped icon reads as a broken layout rather than
  /// an invitation to scroll.
  testWidgets(
    'the tool strip fades its clipped edge, and only the edge with more to '
    'reveal',
    (tester) async {
      await tester.pumpWidget(
        wrapCanvasToolsRow(buildCanvasToolsRow(), width: 270, touch: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(canvasToolsLeadingFadeKey), findsNothing);
      expect(find.byKey(canvasToolsTrailingFadeKey), findsOneWidget);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-40, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(canvasToolsLeadingFadeKey), findsOneWidget);
      expect(find.byKey(canvasToolsTrailingFadeKey), findsOneWidget);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-1000, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(canvasToolsLeadingFadeKey), findsOneWidget);
      expect(find.byKey(canvasToolsTrailingFadeKey), findsNothing);
    },
  );

  testWidgets('neither edge fades once the strip has room for every tool', (
    tester,
  ) async {
    await tester.pumpWidget(wrapCanvasToolsRow(buildCanvasToolsRow()));
    await tester.pumpAndSettle();

    expect(find.byKey(canvasToolsLeadingFadeKey), findsNothing);
    expect(find.byKey(canvasToolsTrailingFadeKey), findsNothing);
  });
}
