// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug log's level filter never wraps an option onto a second row, and the search stacks above it below 700dp.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/debug_log_toolbar.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: DebugLogToolbar(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final width in [320.0, 360.0, 390.0, 599.0, 600.0, 699.0]) {
    testWidgets('at $width the levels share one row and sit under the search', (
      tester,
    ) async {
      await _pump(tester, width);
      final tops = {
        for (final e
            in find.byWidgetPredicate((w) => w is AnimatedContainer).evaluate())
          tester.getTopLeft(find.byWidget(e.widget)).dy.round(),
      };
      expect(tops, hasLength(1), reason: 'five levels on one row');
      final search = tester.getRect(
        find.byWidgetPredicate((w) => w is AppInput),
      );
      final levels = tester.getRect(
        find.byWidgetPredicate((w) => w is AppSegmentedControl),
      );
      expect(levels.top, greaterThanOrEqualTo(search.bottom));
      expect(levels.left, closeTo(search.left, 0.5));
      expect(levels.right, closeTo(search.right, 0.5));
    });
  }

  testWidgets('at 900 the search and the levels share a row', (tester) async {
    await _pump(tester, 900);
    final search = tester.getRect(find.byWidgetPredicate((w) => w is AppInput));
    final levels = tester.getRect(
      find.byWidgetPredicate((w) => w is AppSegmentedControl),
    );
    expect(levels.left, greaterThan(search.right));
  });
}
