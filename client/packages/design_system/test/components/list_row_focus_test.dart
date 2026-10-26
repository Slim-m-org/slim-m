// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row that does nothing is not a keyboard stop, so Tab skips it and no ring is drawn on it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, List<Widget> rows) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: Column(children: rows)),
      ),
    );

/// The label of the row holding focus, or null when focus is on no row.
String? _focusedRow() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<AppListRow>()
    ?.label;

void main() {
  testWidgets('Tab skips a row with no tap and lands on the next live row', (
    tester,
  ) async {
    await _pump(tester, [
      const AppListRow(label: 'Static row'),
      AppListRow(label: 'Live row', onTap: () {}),
    ]);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(_focusedRow(), 'Live row');
  });

  testWidgets('a row with no tap alone takes no focus at all', (tester) async {
    await _pump(tester, [const AppListRow(label: 'Static row')]);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(_focusedRow(), isNull);
  });

  testWidgets('a button inside a static row stays its own control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, [
      AppListRow(
        label: 'kiki',
        trailing: AppButton(
          label: 'Remove',
          semanticLabel: 'Remove kiki',
          onPressed: () {},
        ),
      ),
    ]);

    expect(find.bySemanticsLabel('Remove kiki'), findsOneWidget);
    // The first Tab may only enter the route's scope; the button is reached within two.
    for (var i = 0; i < 2 && _focusedRow() == null; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(_focusedRow(), 'kiki', reason: 'the button inside is still a stop');
    semantics.dispose();
  });
}
