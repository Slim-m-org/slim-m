// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's own richer Emoji tab: a vertical rail that jumps a
/// continuous scroll rather than filtering it, and a preview footer driven
/// by hover, a held touch, or the keyboard's own highlight - not a
/// pointer-only affordance. `emoji_picker_test.dart` covers the shared,
/// unchanged `EmojiPickerPanel` the reaction picker still uses.
///
/// A hover test here forces `FocusManager.highlightStrategy` to
/// `alwaysTraditional`: `FocusableActionDetector.onShowHoverHighlight`
/// (what `EmojiCell` hover rides) only fires once the framework decides the
/// current input modality is "traditional" (mouse/keyboard) rather than
/// touch, a decision a synthetic `TestGesture` mouse move alone never
/// reaches on its own in a widget test.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_emoji_browse.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker_grid.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_preview_footer.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_sectioned_grid.dart';
import 'package:slimm_design_system/design_system.dart';

const _grinningFace = '\u{1F600}'; // The catalog's first entry.

/// Fixed at the same width `ComposerPickerPanel`'s real `AppMenu` gives this
/// widget, so the sectioned grid's own column count - and so the rail's
/// jump-offset math, which uses the same width - matches production rather
/// than whatever an unconstrained test viewport happens to hand it.
Widget _harness(ValueChanged<String> onSelect) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 320,
          child: ComposerEmojiPicker(onSelect: onSelect, onClose: () {}),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Without this, FocusableActionDetector's hover gate never opens here.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
  });

  testWidgets('the rail offers one entry per non-empty category', (
    tester,
  ) async {
    await tester.pumpWidget(_harness((_) {}));

    expect(find.byType(EmojiCategoryRail), findsOneWidget);
    expect(find.byTooltip('Smileys and emotion'), findsOneWidget);
    expect(find.byTooltip('Flags'), findsOneWidget);
    // Nothing has a history yet, so the recent rail entry is absent too.
    expect(find.byTooltip('Recently used'), findsNothing);
  });

  testWidgets('every rail entry is fully inside the rail, none clipped', (
    tester,
  ) async {
    await tester.pumpWidget(_harness((_) {}));

    final rail = tester.getRect(find.byType(EmojiCategoryRail));
    for (final category in emojiCategoriesInOrder) {
      final entry = tester.getRect(find.byTooltip(category.label));
      expect(
        entry.bottom,
        lessThanOrEqualTo(rail.bottom),
        reason:
            '${category.label} ends ${entry.bottom - rail.bottom} px '
            'below the rail',
      );
    }
  });

  testWidgets('every category is on screen at once, not swapped by a tab', (
    tester,
  ) async {
    await tester.pumpWidget(_harness((_) {}));

    expect(find.byType(EmojiSectionedGrid), findsOneWidget);
    expect(find.byType(EmojiCategoryTabs), findsNothing);
  });

  testWidgets('tapping a rail entry scrolls the browse view', (tester) async {
    await tester.pumpWidget(_harness((_) {}));

    final controller = tester
        .widget<CustomScrollView>(
          find.descendant(
            of: find.byType(EmojiSectionedGrid),
            matching: find.byType(CustomScrollView),
          ),
        )
        .controller!;

    // The rail is its own taller scrollable: reach "Flags" there first.
    await tester.ensureVisible(find.byTooltip('Flags'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Flags'));
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      greaterThan(0),
      reason: 'a rail tap on a late category jumps the scroll position',
    );
  });

  testWidgets(
    'the footer opens on the first tile - the keyboard highlight default, '
    'before anything is hovered or pressed',
    (tester) async {
      await tester.pumpWidget(_harness((_) {}));

      expect(find.text(_grinningFace), findsWidgets);
      expect(find.byType(EmojiPreviewFooter), findsOneWidget);
      expect(
        tester
            .widget<EmojiPreviewFooter>(find.byType(EmojiPreviewFooter))
            .emoji,
        isNotNull,
      );
    },
  );

  testWidgets('hovering a tile drives the footer, not just tapping it', (
    tester,
  ) async {
    await tester.pumpWidget(_harness((_) {}));

    final cell = find.byType(EmojiCell).at(1);
    final target = tester.widget<EmojiCell>(cell).emoji;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(cell));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<EmojiPreviewFooter>(find.byType(EmojiPreviewFooter))
          .emoji
          ?.token,
      target.token,
    );
  });

  testWidgets(
    'a held touch drives the footer too - hover is not the only story',
    (tester) async {
      await tester.pumpWidget(_harness((_) {}));

      final cell = find.byType(EmojiCell).at(2);
      final target = tester.widget<EmojiCell>(cell).emoji;

      final gesture = await tester.startGesture(tester.getCenter(cell));
      // The ancestor Scrollable also wants this pointer; give the arena a beat.
      await tester.pump(kPressTimeout);

      expect(
        tester
            .widget<EmojiPreviewFooter>(find.byType(EmojiPreviewFooter))
            .emoji
            ?.token,
        target.token,
      );

      await gesture.up();
      await tester.pump();
    },
  );

  testWidgets('arrow-down moves the keyboard highlight the footer follows', (
    tester,
  ) async {
    await tester.pumpWidget(_harness((_) {}));

    final before = tester
        .widget<EmojiPreviewFooter>(find.byType(EmojiPreviewFooter))
        .emoji;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final after = tester
        .widget<EmojiPreviewFooter>(find.byType(EmojiPreviewFooter))
        .emoji;
    expect(after?.token, isNot(before?.token));
  });

  testWidgets('a search still shows one flat grid, rail and sections hidden', (
    tester,
  ) async {
    await tester.pumpWidget(_harness((_) {}));

    await tester.enterText(find.byType(TextField), 'rofl');
    await tester.pump();

    expect(find.byType(EmojiCategoryRail), findsNothing);
    expect(find.byType(EmojiSectionedGrid), findsNothing);
    expect(find.byType(EmojiGrid), findsOneWidget);
  });

  testWidgets('picking the default highlight reports the leading emoji', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(_harness((emoji) => picked = emoji));

    await tester.tap(find.byType(EmojiCell).first);
    await tester.pump();

    expect(picked, isNotNull);
  });
}
