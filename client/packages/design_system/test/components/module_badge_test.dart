// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _module = [
  AppBadgeVariant.module,
  AppBadgeVariant.moduleAccent,
  AppBadgeVariant.moduleMuted,
];

Future<void> _pump(WidgetTester tester, AppBadgeVariant v, AppTokens tokens) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(
          tokens == AppTokens.light ? Brightness.light : Brightness.dark,
          tokens,
        ),
        home: Scaffold(
          body: AppBadge(
            variant: v,
            label: 'Admin',
            markerIcon: AppIcons.dock,
          ),
        ),
      ),
    );

void main() {
  for (final tokens in [AppTokens.light, AppTokens.dark]) {
    final theme = tokens == AppTokens.light ? 'light' : 'dark';
    for (final variant in _module) {
      testWidgets('$variant text reads on every surface, $theme', (
        tester,
      ) async {
        await _pump(tester, variant, tokens);

        final colour = tester.widget<Text>(find.text('Admin')).style!.color!;
        for (final surface in [
          tokens.surfaceSunken,
          tokens.surfaceBase,
          tokens.surfaceRaised,
        ]) {
          expect(contrastRatio(colour, surface), greaterThanOrEqualTo(4.5));
        }
      });

      testWidgets('$variant is outlined, mixed case, led by a marker, $theme', (
        tester,
      ) async {
        await _pump(tester, variant, tokens);

        expect(find.text('Admin'), findsOneWidget);
        expect(find.byIcon(AppIcons.dock), findsOneWidget);
        final box = tester
            .widget<Container>(
              find.descendant(
                of: find.byType(AppBadge),
                matching: find.byType(Container),
              ),
            )
            .decoration! as BoxDecoration;
        expect(box.color, isNull);
      });
    }
  }
}
