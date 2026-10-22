// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// WCAG 1.4.11: the edge of an input is a UI component boundary and meets 3:1
/// against the surface behind it. A card is a container, not a control, so it
/// keeps the hairline (decision 0004, 2026-10-01 addendum). Computed from the tokens, then
/// read back off the rendered widgets so a swap to the hairline fails here.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

const _themes = {
  'light': (Brightness.light, AppTokens.light),
  'dark': (Brightness.dark, AppTokens.dark),
  'trueBlack': (Brightness.dark, AppTokens.trueBlack),
  'mocha': (Brightness.dark, AppTokens.mocha),
  'soft': (Brightness.dark, AppTokens.soft),
  'forest': (Brightness.dark, AppTokens.forest),
};

Color _edgeOf(WidgetTester tester, Type owner, Color fill) {
  final boxes = tester
      .widgetList<Container>(find.descendant(
          of: find.byType(owner), matching: find.byType(Container)))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.color == fill && d.border != null);
  expect(boxes, isNotEmpty, reason: 'no $owner box painted with $fill');
  return (boxes.first.border! as Border).top.color;
}

void main() {
  _themes.forEach((name, entry) {
    final (brightness, tokens) = entry;
    final surfaces = {
      'sunken': tokens.surfaceSunken,
      'base': tokens.surfaceBase,
      'raised': tokens.surfaceRaised,
    };

    surfaces.forEach((surface, bg) {
      test('$name boundary token is at least 3:1 on $surface', () {
        expect(
          _contrast(tokens.borderStrong, bg),
          greaterThanOrEqualTo(3.0),
          reason: '$name borderStrong on $surface',
        );
      });
    });

    Future<void> pump(WidgetTester tester, Widget child) =>
        tester.pumpWidget(MaterialApp(
          theme: buildTheme(brightness, tokens),
          home:
              Scaffold(body: Center(child: SizedBox(width: 300, child: child))),
        ));

    testWidgets('$name AppInput draws its edge in the boundary token',
        (tester) async {
      await pump(tester, const AppInput(placeholder: 'Email'));
      final edge = _edgeOf(tester, AppInput, tokens.surfaceRaised);
      expect(edge, tokens.borderStrong);
      expect(_contrast(edge, tokens.surfaceBase), greaterThanOrEqualTo(3.0));
    });

    testWidgets('$name AppCard keeps the hairline', (tester) async {
      await pump(tester, const AppCard(child: Text('Body')));
      expect(
          _edgeOf(tester, AppCard, tokens.surfaceRaised), tokens.borderSubtle);
    });

    test('$name theme text fields draw their edge in the boundary token', () {
      final theme = buildTheme(brightness, tokens);
      final enabled =
          theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
      expect(enabled.borderSide.color, tokens.borderStrong);
    });
  });
}
