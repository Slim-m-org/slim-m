// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's desktop-width picker: an anchored panel with Emoji and
/// GIFs tabs, opened by either the smile or the GIF button, reaching native
/// emoji directly rather than only the Space's own - the defect the owner
/// reported ("desktop has old emoji view, should be like discord").
///
/// `composer_emoji_test.dart` covers the same buttons at touch density,
/// where the Space-emoji-only sheet is still the right answer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_picker_panel.dart';
import 'package:slimm_app/src/widgets/emoji_picker_grid.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';
import 'composer_picker_api.dart';

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  testWidgets(
    'the smile button opens an anchored panel with Emoji and GIFs tabs, no Stickers',
    (tester) async {
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          apiBuilder: pickerApi(gifSearchEnabled: true),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(emojiButton);
      await tester.pumpAndSettle();

      expect(find.byType(ComposerPickerPanel), findsOneWidget);
      expect(find.byType(AppSegmentedControl), findsOneWidget);
      expect(find.text('Emoji'), findsOneWidget);
      expect(find.text('GIFs'), findsOneWidget);
      expect(find.text('Stickers'), findsNothing);
      // The core complaint: native emoji reachable, not just the Space's own.
      expect(find.text('Search emoji'), findsOneWidget);
    },
  );

  /// The composer had a second icon that opened this same panel already on
  /// the GIFs tab. It is gone: one button, and the tabs carry the rest. The
  /// owner read the pair as a leftover from before the panel was shared, and
  /// it was.
  ///
  /// What that test actually protected - that the panel can reach trending
  /// gifs - is covered by the tab-switching test below.
  testWidgets('switching tabs moves between emoji and GIF content', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: pickerApi(gifSearchEnabled: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    expect(find.text('Search emoji'), findsOneWidget);

    await tester.tap(find.text('GIFs'));
    await tester.pumpAndSettle();
    expect(find.text('Search emoji'), findsNothing);
    expect(find.text('Search GIFs'), findsOneWidget);

    await tester.tap(find.text('Emoji'));
    await tester.pumpAndSettle();
    expect(find.text('Search emoji'), findsOneWidget);
  });

  testWidgets('the smile button toggles the panel closed again', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: pickerApi(gifSearchEnabled: true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    expect(find.byType(ComposerPickerPanel), findsOneWidget);

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    expect(find.byType(ComposerPickerPanel), findsNothing);
  });

  testWidgets('without a GIF provider the panel has no tab row at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: pickerApi(gifSearchEnabled: false),
      ),
    );
    await tester.pumpAndSettle();

    // No provider, so the one button says only what it can do.
    expect(
      find.byWidgetPredicate(
        (w) => w is AppIconButton && w.semanticLabel == 'Insert emoji or a GIF',
      ),
      findsNothing,
    );

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();

    expect(find.byType(AppSegmentedControl), findsNothing);
    expect(find.text('Search emoji'), findsOneWidget);
  });

  testWidgets('the anchored panel opens onto native emoji, not only the '
      "Space's own", (tester) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: pickerApi(gifSearchEnabled: true),
        customEmoji: const [],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();

    // No custom emoji: rendered as EmojiCell tiles in the browse view's own sectioned grid, not a single EmojiGrid.
    final tokens = tester
        .widgetList<EmojiCell>(find.byType(EmojiCell))
        .map((cell) => cell.emoji.token)
        .toList();
    expect(tokens, isNotEmpty);
    expect(
      tokens.every((token) => !token.startsWith(':')),
      isTrue,
      reason: 'these are native codepoints, not `:shortcode:` custom ones',
    );
  });
}
