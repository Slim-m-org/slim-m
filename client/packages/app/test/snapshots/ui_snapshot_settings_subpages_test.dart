// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sub pages the settings cleanup moved things onto: Customize's one save
/// bar and visitor preview page, the emoji add page, and the one-sheet "add to
/// the permissions grid" picker.
library;

import 'package:flutter/widgets.dart' show Scrollable;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

Future<void> _openPane(WidgetTester tester, String pane) async {
  final row = find.widgetWithText(AppListRow, pane);
  final nav = find
      .ancestor(
        of: find.widgetWithText(AppListRow, 'Reports'),
        matching: find.byWidgetPredicate((w) => w is Scrollable),
      )
      .evaluate()
      .first;
  await tester.scrollUntilVisible(
    row,
    120,
    scrollable: find.byElementPredicate((e) => e == nav),
  );
  await tester.pump();
  await tester.tap(row);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    // A phone opens Customize as its own route, which the fixture router lacks.
    if (viewport == 'desktop') {
      testWidgets('customize preview page at $viewport', (tester) async {
        await renderSurface(
          tester,
          '/settings/space',
          viewport,
          'dark',
          'subpage-customize-preview-$viewport-dark',
          settleNestedResolve: true,
          afterSettle: (tester) async {
            await _openPane(tester, 'Customize');
            await tester.pump(const Duration(milliseconds: 500));
            await tester.ensureVisible(find.text('Preview as a visitor'));
            await tester.tap(find.text('Preview as a visitor'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
          },
        );
      });
    }

    testWidgets('emoji add page at $viewport', (tester) async {
      await renderSurface(
        tester,
        '/settings/space',
        viewport,
        'dark',
        'subpage-emoji-add-$viewport-dark',
        settleNestedResolve: true,
        afterSettle: (tester) async {
          await _openPane(tester, 'Emoji');
          await tester.tap(find.text('Add').first);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        },
      );
    });
  }
}
