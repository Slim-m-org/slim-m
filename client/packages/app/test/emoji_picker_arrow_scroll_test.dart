// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/emoji_picker_grid.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness() => ProviderScope(
  overrides: [customEmojiProvider.overrideWith((ref) => const <CustomEmoji>[])],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: EmojiPickerPanel(onSelect: (_) {}, onClose: () {}),
      ),
    ),
  ),
);

Finder get _highlightedCell =>
    find.byWidgetPredicate((w) => w is EmojiCell && w.highlighted);

Future<void> _search(WidgetTester tester) async {
  await tester.pumpWidget(_harness());
  await tester.enterText(find.byType(EditableText), 'a');
  await tester.pump();
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ArrowDown moves the highlight one row and keeps the column', (
    tester,
  ) async {
    await _search(tester);
    final before = tester.getTopLeft(_highlightedCell);

    await _press(tester, LogicalKeyboardKey.arrowDown, 1);

    final after = tester.getTopLeft(_highlightedCell);
    expect(after.dy, greaterThan(before.dy));
    expect(after.dx, before.dx);
  });

  testWidgets('the highlighted cell stays inside the grid going down', (
    tester,
  ) async {
    await _search(tester);
    final viewport = tester.getRect(find.byType(GridView));

    await _press(tester, LogicalKeyboardKey.arrowDown, 60);

    expect(_highlightedCell, findsOneWidget);
    final cell = tester.getRect(_highlightedCell);
    expect(viewport.contains(cell.topLeft), isTrue, reason: '$cell $viewport');
    expect(viewport.contains(cell.bottomRight), isTrue, reason: '$cell');
  });

  testWidgets('and comes back into view going up', (tester) async {
    await _search(tester);
    final viewport = tester.getRect(find.byType(GridView));
    await _press(tester, LogicalKeyboardKey.arrowDown, 30);

    await _press(tester, LogicalKeyboardKey.arrowUp, 25);

    expect(_highlightedCell, findsOneWidget);
    final cell = tester.getRect(_highlightedCell);
    expect(viewport.contains(cell.topLeft), isTrue, reason: '$cell $viewport');
    expect(viewport.contains(cell.bottomRight), isTrue, reason: '$cell');
  });

  testWidgets('each single step keeps the cell fully visible', (tester) async {
    await _search(tester);
    final viewport = tester.getRect(find.byType(GridView));

    for (var i = 0; i < 12; i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown, 1);
      final cell = tester.getRect(_highlightedCell);
      expect(
        viewport.top <= cell.top && cell.bottom <= viewport.bottom,
        true,
        reason: 'step $i: $cell outside $viewport',
      );
    }
  });
}
