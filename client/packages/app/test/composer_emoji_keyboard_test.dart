// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Arrow keys in the composer's emoji browser: Up and Down move a row, Left
/// and Right a cell, and the highlighted cell is always scrolled into view.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/widgets/composer_emoji_browse.dart';
import 'package:slimm_app/src/widgets/emoji_catalog.dart';
import 'package:slimm_app/src/widgets/emoji_picker_grid.dart';
import 'package:slimm_app/src/widgets/emoji_section_navigation.dart';
import 'package:slimm_app/src/widgets/emoji_sectioned_grid.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness() => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 320,
          child: ComposerEmojiPicker(onSelect: (_) {}, onClose: () {}),
        ),
      ),
    ),
  ),
);

Finder get _highlightedCell => find.byWidgetPredicate(
  (w) => w is EmojiCell && w.highlighted,
  skipOffstage: false,
);

Future<void> _press(WidgetTester t, LogicalKeyboardKey key, [int n = 1]) async {
  for (var i = 0; i < n; i++) {
    await t.sendKeyEvent(key);
    await t.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('ArrowDown moves the highlight a row, not a cell', (t) async {
    await t.pumpWidget(_harness());
    final start = t.getRect(_highlightedCell);
    await _press(t, LogicalKeyboardKey.arrowDown);
    final next = t.getRect(_highlightedCell);
    expect(next.top, greaterThan(start.top));
    expect(next.left, start.left);
  });

  testWidgets('ArrowRight and ArrowLeft move one cell', (t) async {
    await t.pumpWidget(_harness());
    final start = t.getRect(_highlightedCell);
    await _press(t, LogicalKeyboardKey.arrowRight);
    final right = t.getRect(_highlightedCell);
    expect(right.left, greaterThan(start.left));
    expect(right.top, start.top);
    await _press(t, LogicalKeyboardKey.arrowLeft);
    expect(t.getRect(_highlightedCell), start);
  });

  testWidgets('the highlighted cell stays inside the visible grid', (t) async {
    await t.pumpWidget(_harness());
    final grid = t.getRect(find.byType(EmojiSectionedGrid));
    await _press(t, LogicalKeyboardKey.arrowDown, 80);
    expect(_highlightedCell, findsOneWidget);
    final cell = t.getRect(_highlightedCell);
    expect(grid.contains(cell.topLeft), isTrue);
    expect(grid.contains(cell.bottomRight), isTrue);
    await _press(t, LogicalKeyboardKey.arrowUp, 80);
    final back = t.getRect(_highlightedCell);
    expect(grid.contains(back.topLeft), isTrue);
    expect(grid.contains(back.bottomRight), isTrue);
  });

  testWidgets('a search result grid steps a row on ArrowDown', (t) async {
    await t.pumpWidget(_harness());
    await t.enterText(find.byType(TextField), 'face');
    await t.pump();
    final start = t.getRect(_highlightedCell);
    await _press(t, LogicalKeyboardKey.arrowDown);
    final next = t.getRect(_highlightedCell);
    expect(next.top, greaterThan(start.top));
    expect(next.left, start.left);
  });

  testWidgets('ArrowRight keeps moving the caret once a search has text', (
    t,
  ) async {
    await t.pumpWidget(_harness());
    await t.enterText(find.byType(TextField), 'face');
    await t.pump();
    final start = t.getRect(_highlightedCell);
    await _press(t, LogicalKeyboardKey.arrowRight);
    expect(t.getRect(_highlightedCell), start);
  });

  test('stepRow crosses a section boundary in the same column', () {
    final sections = pickerSections(recent: const [], custom: const []);
    final nav = EmojiSectionNavigation(
      sections: sections,
      crossAxisExtent: 284,
    );
    final first = sections.first.emoji.length;
    final lastRowStart = (first - 1) ~/ nav.columns * nav.columns;
    expect(nav.stepRow(lastRowStart + 1, 1), first + 1);
    expect(nav.stepRow(first + 1, -1), lastRowStart + 1);
    expect(nav.stepRow(0, -1), 0);
    final total = sections.fold<int>(0, (n, s) => n + s.emoji.length);
    expect(nav.stepRow(total - 1, 1), total - 1);
  });
}
