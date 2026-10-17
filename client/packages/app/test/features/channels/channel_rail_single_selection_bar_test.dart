// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A selected channel shows one accent bar, not two.
///
/// The rail draws a bar that slides between rows (`SelectionMarkerLayer`,
/// #616), and `AppListRow` draws its own left marker whenever `selected`.
/// Both were true for every rail row from the day the travelling one landed,
/// so a selected channel had two bars side by side. Reported from a phone.
///
/// The existing `channel_rail_selection_marker_test.dart` could not catch it:
/// it builds plain `Container`s inside the layer rather than real rows, so
/// there was never a second marker in its tree to find. This one asserts the
/// count against the real widgets, which is the assertion that fails on the
/// old behaviour.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_selection_marker.dart';
import 'package:slimm_design_system/design_system.dart';

/// The layer's own travelling bar, which is not an [AppListRow] marker.
Finder get _travellingBar => find.descendant(
  of: find.byType(SelectionMarkerLayer),
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).borderRadius ==
            const BorderRadius.horizontal(
              right: Radius.circular(AppRadii.full),
            ),
  ),
);

Finder get _rowMarker => find.byKey(AppListRow.selectionMarkerKey);

Widget _rail({required bool selected, bool inLayer = true}) {
  final rows = Column(
    children: [
      AppListRow(label: 'chat', selected: selected, onTap: () {}),
      AppListRow(label: 'general', selected: false, onTap: () {}),
    ],
  );
  return MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: inLayer
          ? SelectionMarkerLayer(
              child: Column(
                children: [
                  SelectionMarkerTarget(selected: selected, child: rows),
                ],
              ),
            )
          : rows,
    ),
  );
}

void main() {
  testWidgets('a selected row inside the rail draws no marker of its own', (
    tester,
  ) async {
    await tester.pumpWidget(_rail(selected: true));
    await tester.pumpAndSettle();

    expect(
      _rowMarker,
      findsNothing,
      reason:
          'the layer owns the bar here; a row drawing one too is the '
          'second bar that showed up on the phone',
    );
    expect(_travellingBar, findsOneWidget);
  });

  testWidgets('exactly one accent bar is on screen for a selected channel', (
    tester,
  ) async {
    await tester.pumpWidget(_rail(selected: true));
    await tester.pumpAndSettle();

    expect(_rowMarker.evaluate().length + _travellingBar.evaluate().length, 1);
  });

  testWidgets('outside the rail a selected row still draws its own marker', (
    tester,
  ) async {
    await tester.pumpWidget(_rail(selected: true, inLayer: false));
    await tester.pumpAndSettle();

    expect(
      _rowMarker,
      findsOneWidget,
      reason:
          'every other list in the app relies on AppListRow marking its '
          'own selection; the scope must only suppress it where a layer is',
    );
  });

  testWidgets('an unselected rail row draws nothing either way', (
    tester,
  ) async {
    await tester.pumpWidget(_rail(selected: false));
    await tester.pumpAndSettle();

    expect(_rowMarker, findsNothing);
    expect(_travellingBar, findsNothing);
  });
}
