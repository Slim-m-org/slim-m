// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The overflow's "hidden tiles" recovery section: a hide must stay
/// reversible without leaving the call, or it is a delete wearing a softer
/// name - see `canvas_call_dock.dart`'s own doc on [CanvasHiddenTile].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tools_row.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/canvas_tools_row_fixtures.dart';

void main() {
  testWidgets('nothing hidden shows no recovery section at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(hiddenTiles: const [])),
    );

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();

    expect(find.byIcon(AppIcons.tileHide), findsNothing);
  });

  testWidgets(
    'every hidden tile gets its own "Show" item, and tapping one calls back '
    'with that tile\'s own key',
    (tester) async {
      final shown = <String>[];
      await tester.pumpWidget(
        wrapCanvasToolsRow(
          buildCanvasToolsRow(
            hiddenTiles: const [
              CanvasHiddenTile(
                key: 'camera:user-avery',
                label: "Avery's camera",
              ),
              CanvasHiddenTile(
                key: 'screen:user-sam',
                label: "Sam's screen share",
              ),
            ],
            onShowTile: shown.add,
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();

      expect(find.text("Show Avery's camera"), findsOneWidget);
      expect(find.text("Show Sam's screen share"), findsOneWidget);

      await tester.tap(find.text("Show Avery's camera"));
      await tester.pump();

      expect(shown, ['camera:user-avery']);
    },
  );
}
