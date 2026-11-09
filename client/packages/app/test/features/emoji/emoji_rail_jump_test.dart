// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The category rail's jump lands on the section's own header, measured on a
/// laid-out grid rather than against the formula that computes the offset.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_emoji_browse.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_picker_panel.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_section_navigation.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_sectioned_grid.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(double width) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: ComposerEmojiPicker(onSelect: (_) {}, onClose: () {}),
        ),
      ),
    ),
  ),
);

/// The picker as the app mounts it: inside the card that pads it below its width.
Widget _panelHarness() => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: ComposerPickerPanel(
          initialTab: ComposerPickerTab.emoji,
          showGifTab: false,
          onSelectEmoji: (_) {},
          onPickedGif: (_) {},
          onClose: () {},
        ),
      ),
    ),
  ),
);

Future<void> _jumpAndLand(WidgetTester tester, EmojiCategory category) async {
  await tester.ensureVisible(find.byTooltip(category.label));
  await tester.pump(AppMotion.base);
  await tester.tap(find.byTooltip(category.label));
  await tester.pump();
  await tester.pump(AppMotion.base * 2);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> expectLandsOnHeader(
    WidgetTester tester,
    EmojiCategory category,
  ) async {
    await _jumpAndLand(tester, category);

    final grid = tester.getRect(
      find.byWidgetPredicate((w) => w is EmojiSectionedGrid),
    );
    final header = find.byWidgetPredicate(
      (w) => w is AppMenuLabel && w.text == category.sectionLabel,
    );
    expect(
      header,
      findsOneWidget,
      reason: 'the jump overshot ${category.label}, so its header is unbuilt',
    );
    expect(
      tester.getRect(header).top,
      moreOrLessEquals(grid.top, epsilon: 1.0),
      reason: 'the jump leaves ${category.label} at the viewport top',
    );
  }

  const categories = [
    EmojiCategory.animalsNature,
    EmojiCategory.foodDrink,
    EmojiCategory.objects,
    EmojiCategory.flags,
  ];

  for (final width in [320.0, 380.0]) {
    for (final category in categories) {
      testWidgets('${category.label} lands on its header at $width wide', (
        tester,
      ) async {
        await tester.pumpWidget(_harness(width));
        await expectLandsOnHeader(tester, category);
      });
    }
  }

  for (final category in categories) {
    testWidgets('${category.label} lands on its header inside the card', (
      tester,
    ) async {
      await tester.pumpWidget(_panelHarness());
      expect(find.byWidgetPredicate((w) => w is AppMenu), findsOneWidget);
      await expectLandsOnHeader(tester, category);
    });
  }

  test(
    'the leading section starts at the top and an absent one at the end',
    () {
      final sections = pickerSections(recent: const [], custom: const []);
      final nav = EmojiSectionNavigation(
        sections: sections,
        crossAxisExtent: 268,
      );

      expect(nav.sectionTop(sections.first.category), 0);
      expect(
        nav.sectionTop(EmojiCategory.custom),
        greaterThan(nav.sectionTop(EmojiCategory.flags)),
        reason: 'a category with no section falls off the end, not to zero',
      );
    },
  );
}
