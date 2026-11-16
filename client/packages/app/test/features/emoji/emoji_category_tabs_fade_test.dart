// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker's category tabs fade the edge that has more tabs past it, so
/// tabs scrolled out of a narrow panel still read as there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker_grid.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, {required double width}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: EmojiCategoryTabs(
              categories: pickerTabs(hasCustom: true, hasRecent: true),
              selected: EmojiCategory.custom,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder get _leading => find.byKey(EmojiCategoryTabs.leadingFadeKey);
Finder get _trailing => find.byKey(EmojiCategoryTabs.trailingFadeKey);

void main() {
  testWidgets('tabs past the right edge fade it until scrolled to the end', (
    tester,
  ) async {
    await _pump(tester, width: 300);

    expect(_trailing, findsOneWidget);
    expect(_leading, findsNothing);

    await tester.drag(
      find.byTooltip(EmojiCategory.custom.label),
      const Offset(-600, 0),
    );
    await tester.pump();

    expect(_trailing, findsNothing);
    expect(_leading, findsOneWidget);
  });

  testWidgets('tabs that all fit fade neither edge', (tester) async {
    await _pump(tester, width: 800);

    expect(_trailing, findsNothing);
    expect(_leading, findsNothing);
  });
}
