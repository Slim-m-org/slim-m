// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A slider that shows its value beside it keeps the label for screen readers and draws no bubble.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, {required bool bubble}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: AppSlider(
              value: 40,
              max: 200,
              autofocus: true,
              semanticLabel: 'Volume',
              valueLabel: (v) => '${v.round()}%',
              valueBubble: bubble,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a focused slider draws its value bubble by default', (
    tester,
  ) async {
    await _pump(tester, bubble: true);
    await tester.pump();
    expect(find.text('40%'), findsOneWidget);
  });

  testWidgets('the bubble is drawn on the tooltip\'s raised plate', (
    tester,
  ) async {
    await _pump(tester, bubble: true);
    await tester.pump();
    const tokens = AppTokens.light;
    final plate = tester.widget<DecoratedBox>(
      find
          .ancestor(
            of: find.text('40%'),
            matching: find.byWidgetPredicate((w) => w is DecoratedBox),
          )
          .first,
    );
    final decoration = plate.decoration as BoxDecoration;
    expect(decoration.color, tokens.surfaceRaised);
    expect(decoration.border, Border.all(color: tokens.borderStrong));
    expect(
        tester.widget<Text>(find.text('40%')).style?.color, tokens.textPrimary);
  });

  testWidgets(
      'valueBubble false draws no bubble but still tells a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, bubble: false);
    await tester.pump();
    expect(find.text('40%'), findsNothing);
    expect(
      tester.getSemantics(find.byType(Slider)).toStringDeep(),
      contains('value: "40%"'),
    );
    semantics.dispose();
  });
}
