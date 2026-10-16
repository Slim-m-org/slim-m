// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared segmented choice block and the save feedback under its card.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/settings_save_feedback.dart';
import 'package:slimm_app/src/widgets/settings_segmented_block.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  testWidgets('tapping a segment reports its index', (tester) async {
    final chosen = <int>[];
    await _pump(
      tester,
      SettingsSegmentedBlock(
        semanticLabel: 'Window',
        labels: const ['Never', '30 days'],
        selectedIndex: 0,
        onSelected: chosen.add,
      ),
    );

    await tester.tap(find.text('30 days'));
    await tester.pump();

    expect(chosen, [1]);
  });

  testWidgets('disabled segments do not report taps', (tester) async {
    final chosen = <int>[];
    await _pump(
      tester,
      SettingsSegmentedBlock(
        semanticLabel: 'Window',
        labels: const ['Never', '30 days'],
        selectedIndex: 0,
        disabled: true,
        onSelected: chosen.add,
      ),
    );

    await tester.tap(find.text('30 days'));
    await tester.pump();

    expect(chosen, isEmpty);
  });

  testWidgets('feedback shows an error and dismisses it, empty it is silent', (
    tester,
  ) async {
    var dismissed = 0;
    await _pump(
      tester,
      SettingsSaveFeedback(
        tick: 0,
        error: 'Could not save.',
        onDismissError: () => dismissed++,
      ),
    );
    expect(find.text('Could not save.'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    expect(dismissed, 1);

    await _pump(
      tester,
      SettingsSaveFeedback(tick: 0, error: null, onDismissError: () {}),
    );
    expect(find.byType(AppErrorState), findsNothing);
  });
}
