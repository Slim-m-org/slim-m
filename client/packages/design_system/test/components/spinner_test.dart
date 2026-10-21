// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child, {bool reduced = false}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

CircularProgressIndicator _arc(WidgetTester tester) =>
    tester.widget(find.byType(CircularProgressIndicator));

void main() {
  group('AppSpinner', () {
    testWidgets('sizes come from the token scale', (tester) async {
      for (final size in AppSpinnerSize.values) {
        await _pump(tester, AppSpinner(size: size));
        expect(tester.getSize(find.byType(AppSpinner)),
            Size.square(size.dimension));
      }
    });

    testWidgets('defaults to the accent fill and takes an override',
        (tester) async {
      await _pump(tester, const AppSpinner());
      expect(_arc(tester).color, AppTokens.light.accentFill);
      await _pump(tester, const AppSpinner(color: Colors.red));
      expect(_arc(tester).color, Colors.red);
    });

    testWidgets('spins normally and holds a static arc under reduce-motion',
        (tester) async {
      await _pump(tester, const AppSpinner());
      expect(_arc(tester).value, isNull);
      await _pump(tester, const AppSpinner(), reduced: true);
      expect(_arc(tester).value, isNotNull);
    });

    testWidgets('a reduced spinner never announces a progress bar',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const AppSpinner(), reduced: true);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(AppSpinner)).getSemanticsData().value,
        isEmpty,
      );
      await _pump(tester, const AppSpinner(semanticLabel: 'Loading'),
          reduced: true);
      final data = tester
          .getSemantics(find.bySemanticsLabel('Loading'))
          .getSemanticsData();
      expect(data.value, isEmpty);
      expect(data.role, SemanticsRole.loadingSpinner);
      handle.dispose();
    });

    testWidgets('names itself only when given a label', (tester) async {
      await _pump(tester, const AppSpinner(semanticLabel: 'Loading'));
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    });
  });
}
