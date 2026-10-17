// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SettingsSelectRow] changes its value two ways by width: a dropdown anchored
/// to the row on desktop, the bottom sheet on a phone. Both reach the same
/// [onChanged]; only the presentation differs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: Center(child: child)),
);

SettingsSelectRow<int> _row(void Function(int) onChanged) =>
    SettingsSelectRow<int>(
      label: 'Image cache',
      value: 100,
      sheetTitle: 'Image cache limit',
      sheetFootnote: 'A lower limit saves memory.',
      choices: const [
        SettingsChoice(value: 50, label: '50 MB'),
        SettingsChoice(value: 100, label: '100 MB'),
        SettingsChoice(value: 200, label: '200 MB'),
      ],
      onChanged: onChanged,
    );

void main() {
  testWidgets('desktop drops the choices down from the row and picks one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    int? picked;
    await tester.pumpWidget(_harness(_row((v) => picked = v)));

    // A down-chevron, not a right one, hints the dropdown.
    expect(find.byIcon(AppIcons.chevronDown), findsOneWidget);

    await tester.tap(find.byType(SettingsSelectRow<int>));
    await tester.pumpAndSettle();

    // The other two values, and the footnote, appear in the anchored menu.
    expect(find.text('50 MB'), findsOneWidget);
    expect(find.text('200 MB'), findsOneWidget);
    expect(find.text('A lower limit saves memory.'), findsOneWidget);

    await tester.tap(find.text('200 MB'));
    await tester.pumpAndSettle();
    expect(picked, 200);
  });

  testWidgets('a phone lifts the sheet instead of a dropdown', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    int? picked;
    await tester.pumpWidget(_harness(_row((v) => picked = v)));

    expect(find.byIcon(AppIcons.chevronRight), findsOneWidget);

    await tester.tap(find.byType(SettingsSelectRow<int>));
    await tester.pumpAndSettle();

    // The sheet heads itself with its (capped) title; the dropdown never does.
    expect(find.text('IMAGE CACHE LIMIT'), findsOneWidget);
    await tester.tap(find.text('50 MB'));
    await tester.pumpAndSettle();
    expect(picked, 50);
  });
}
