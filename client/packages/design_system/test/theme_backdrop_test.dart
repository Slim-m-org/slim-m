// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<int> _taps(WidgetTester tester, AppTokens tokens) async {
  var taps = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, tokens),
      home: ThemeBackdrop(
        // Top-right is where the web hangs, so a tap there is the real test.
        child: Align(
          alignment: Alignment.topRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(key: Key('target'), width: 100, height: 100),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('target')));
  return taps;
}

void main() {
  testWidgets('halloween paints the backdrop and it takes no taps', (
    tester,
  ) async {
    final taps = await _taps(tester, AppTokens.halloween);

    expect(find.byKey(const Key('theme_backdrop')), findsOneWidget);
    expect(taps, 1);
    expect(
      find.ancestor(
        of: find.byKey(const Key('theme_backdrop')),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
  });

  for (final entry in {
    'dark': AppTokens.dark,
    'forest': AppTokens.forest,
    'light': AppTokens.light,
  }.entries) {
    testWidgets('${entry.key} has no backdrop', (tester) async {
      await _taps(tester, entry.value);

      expect(find.byKey(const Key('theme_backdrop')), findsNothing);
    });
  }

  test('high contrast keeps the backdrop', () {
    expect(
      applyHighContrast(AppTokens.halloween).backdrop,
      AppBackdrop.halloweenWebs,
    );
  });
}
