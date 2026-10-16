// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared measured-number row: its value reads against a cap, the bar
/// follows the fraction, and a warning turns the value red.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/settings_meter_row.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget row) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: row),
  ),
);

double? _barFraction(WidgetTester tester) => tester
    .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
    .firstOrNull
    ?.widthFactor;

void main() {
  test('meterFraction clamps to the bar and treats an empty cap as empty', () {
    expect(meterFraction(5, 10), 0.5);
    expect(meterFraction(20, 10), 1);
    expect(meterFraction(3, 0), 0);
  });

  testWidgets('shows the value against its cap with a bar at the fraction', (
    tester,
  ) async {
    await _pump(
      tester,
      const SettingsMeterRow(
        label: 'Image cache',
        value: '10.9 MB',
        of: 'of 100.0 MB',
        fraction: 0.25,
      ),
    );

    expect(find.text('Image cache'), findsOneWidget);
    expect(find.text('10.9 MB of 100.0 MB'), findsOneWidget);
    expect(_barFraction(tester), 0.25);
    expect(
      tester.getSize(find.byType(FractionallySizedBox)).height,
      4,
      reason: 'a fill with no height paints nothing',
    );
  });

  testWidgets('draws no bar without a fraction', (tester) async {
    await _pump(tester, const SettingsMeterRow(label: 'Members', value: '42'));

    expect(find.byType(FractionallySizedBox), findsNothing);
  });

  testWidgets('warn draws the value in the danger colour', (tester) async {
    await _pump(
      tester,
      const Column(
        children: [
          SettingsMeterRow(label: 'Full', value: '8', warn: true),
          SettingsMeterRow(label: 'Idle', value: '2'),
        ],
      ),
    );

    Color? colorOf(String value) =>
        (tester.widget<Text>(find.text(value)).textSpan! as TextSpan)
            .style
            ?.color;
    expect(colorOf('8'), AppTokens.light.dangerText);
    expect(colorOf('2'), AppTokens.light.textPrimary);
  });
}
