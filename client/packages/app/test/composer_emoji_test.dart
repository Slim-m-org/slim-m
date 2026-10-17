// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the emoji button beside the composer field, at touch density.
///
/// Split out of `composer_affordances_test.dart`, which shares the same
/// harness and had grown past the file budget holding both.
///
/// The defects these pin: the button opened the whole unicode catalog on a
/// phone that has all of it on the keyboard already, and a pick left the
/// caret in the dismissed sheet. `composer_desktop_picker_test.dart` covers
/// the anchored panel this same button opens at desktop width instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker_grid.dart';

import 'composer_harness.dart';

/// The cell, not the image: a RenderImage has no children and does not hit
/// test itself, so the tap target is the detector wrapping it.
Finder get _firstEmojiCell => find
    .ancestor(
      of: find.byType(CustomEmojiImage),
      matching: find.byType(GestureDetector),
    )
    .first;

/// Touch density follows width, not platform (`AppTouchTargets.of`), so
/// every test in this file narrows the window itself rather than relying on
/// [TargetPlatform.iOS] to mean anything about layout.
void _useCompactWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  // The owner's decision: the composer offers the Space's own emoji only.
  // Native ones come from the soft keyboard already under the field.
  testWidgets('offers the Space emoji, and no unicode catalog', (tester) async {
    _useCompactWindow(tester);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        customEmoji: [custom('party_parrot'), custom('shipit')],
      ),
    );

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();

    expect(find.byType(CustomEmojiImage), findsNWidgets(2));
    expect(
      find.byType(EmojiPickerPanel),
      findsNothing,
      reason: 'the full catalog belongs to the reaction picker',
    );
    expect(gridTokens(tester), [':party_parrot:', ':shipit:']);
  });

  testWidgets('the Space list can be searched by name', (tester) async {
    _useCompactWindow(tester);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        customEmoji: [custom('party_parrot'), custom('shipit')],
      ),
    );
    await tester.tap(emojiButton);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'ship');
    await tester.pumpAndSettle();
    expect(gridTokens(tester), [':shipit:']);

    await tester.enterText(find.byType(TextField).last, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No emoji match "zzz".'), findsOneWidget);
  });

  testWidgets('a Space with none says so rather than opening empty', (
    tester,
  ) async {
    _useCompactWindow(tester);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        customEmoji: const [],
      ),
    );

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();

    expect(find.byType(EmojiGrid), findsNothing);
    expect(
      find.textContaining('no custom emoji yet'),
      findsOneWidget,
      reason: 'an empty grid explains nothing',
    );
  });

  testWidgets('a picked Space emoji lands at the caret, not at the end', (
    tester,
  ) async {
    _useCompactWindow(tester);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        customEmoji: [custom('party_parrot')],
      ),
    );

    await tester.enterText(find.byType(TextField), 'hi there');
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    await tester.tap(_firstEmojiCell);
    await tester.pumpAndSettle();

    expect(controller.text, 'hi:party_parrot: there');
    expect(
      controller.selection.baseOffset,
      2 + ':party_parrot:'.length,
      reason:
          'the caret must follow what was inserted, or the next '
          'keystroke lands in front of it',
    );
  });

  /// The sheet exists because the keyboard under the field already carries
  /// every native emoji, which only holds if the field has the caret when the
  /// sheet closes.
  ///
  /// Deliberately without touching the field first. Dismissing a route
  /// restores whatever the scope below it had focused, so a test that focuses
  /// the field on the way in gets its focus back either way and proves
  /// nothing. Reaching the emoji button first is the ordinary way to use this
  /// (open the app, pick an emoji, then type), and it is the case the
  /// framework's own restoration does not cover.
  testWidgets('the caret lands in the field after a pick, even if it was '
      'never there', (tester) async {
    _useCompactWindow(tester);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        customEmoji: [custom('party_parrot')],
      ),
    );

    expect(fieldHasFocus(tester), isFalse);

    await tester.tap(emojiButton);
    await tester.pumpAndSettle();
    await tester.tap(_firstEmojiCell);
    await tester.pumpAndSettle();

    expect(controller.text, ':party_parrot:');
    expect(
      fieldHasFocus(tester),
      isTrue,
      reason:
          'the emoji went into a field with no caret in it, so the '
          'keyboard the sheet exists to defer to never came up',
    );
  });
}
