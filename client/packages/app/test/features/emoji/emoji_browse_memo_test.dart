// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hover or a press only repaints the composer's emoji browse view: the
/// sections it shows are derived once, not rebuilt for every pointer move.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_emoji_browse.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker_grid.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_preview_footer.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_sectioned_grid.dart';
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

Finder get _grid => find.byWidgetPredicate((w) => w is EmojiSectionedGrid);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the catalog sections are shared between calls', () {
    final first = pickerSections(recent: const [], custom: const []);
    final second = pickerSections(recent: const [], custom: const []);

    expect(first.length, second.length);
    for (var i = 0; i < first.length; i++) {
      expect(identical(first[i].emoji, second[i].emoji), isTrue);
    }
  });

  testWidgets('hovering a tile keeps the sections the grid was given', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    final before = tester.widget<EmojiSectionedGrid>(_grid);
    final target = before.sections.first.emoji[3];

    before.onHoverChange!(target, true);
    await tester.pump();

    final after = tester.widget<EmojiSectionedGrid>(_grid);
    expect(identical(after.sections, before.sections), isTrue);
    final footer = tester.widget<EmojiPreviewFooter>(
      find.byWidgetPredicate((w) => w is EmojiPreviewFooter),
    );
    expect(footer.emoji?.token, target.token);
  });

  testWidgets('a search re-derives what it shows, so a country name finds '
      'its flag', (tester) async {
    await tester.pumpWidget(_harness());

    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField),
      'germany',
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (w) => w is EmojiCell && w.emoji.label == 'flag: Germany',
      ),
      findsOneWidget,
    );
    expect(_grid, findsNothing);
  });
}
