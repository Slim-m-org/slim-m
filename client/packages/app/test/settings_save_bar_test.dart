// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared unsaved-changes bar: pluralised count, both actions, and both
/// locked while a save is in flight.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/settings_save_bar.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester, {
  int count = 1,
  bool saving = false,
  VoidCallback? onDiscard,
  VoidCallback? onSave,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: SettingsSaveBar(
        changeCount: count,
        saving: saving,
        onDiscard: onDiscard ?? () {},
        onSave: onSave ?? () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('the count is singular for one and plural for more', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('1 unsaved change'), findsOneWidget);
    await _pump(tester, count: 3);
    expect(find.text('3 unsaved changes'), findsOneWidget);
  });

  testWidgets('Discard and Save changes call back', (tester) async {
    var discarded = 0;
    var saved = 0;
    await _pump(tester, onDiscard: () => discarded++, onSave: () => saved++);
    await tester.tap(find.text('Discard'));
    await tester.tap(find.text('Save changes'));
    expect((discarded, saved), (1, 1));
  });

  testWidgets('both actions are locked while saving', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      saving: true,
      onDiscard: () => calls++,
      onSave: () => calls++,
    );
    await tester.tap(find.text('Discard'), warnIfMissed: false);
    await tester.tap(find.text('Saving...'), warnIfMissed: false);
    expect(calls, 0);
  });
}
