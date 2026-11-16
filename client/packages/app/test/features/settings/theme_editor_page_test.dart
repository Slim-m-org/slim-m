// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme editor's layout and colours at a laptop and a phone: the header
/// over Themes, the pinned preview and footer, main colours and their links,
/// All colours, the picker, Contrast and the footer's reasons.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/theme_draft.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_editor_harness.dart';

Color? _linkColour(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: byKey('theme-editor-preview'),
        matching: find.text('Link to the build'),
      ),
    )
    .style!
    .color;

/// Text the colour of the base surface and an accent as dim as its soft fill.
ThemeDocument _twoFailing() {
  final document = failingDocument();
  return document.copyWith(
    colours: {...document.colours, 'accent': const Color(0xFF1D2B33)},
  );
}

Future<void> _typeHex(WidgetTester tester, String hex) async {
  await tester.enterText(find.byKey(AppColourPicker.hexFieldKey), hex);
  await tester.pump();
}

Finder _linkIcon(String token) => find.descendant(
  of: byKey('theme-token-$token'),
  matching: find.byIcon(AppIcons.linkedColour),
);

void main() {
  testWidgets('at a laptop it opens over Themes beside the nav, on the '
      'heading row every pane uses', (tester) async {
    final rig = EditorRig();
    await rig.open(tester);

    expect(find.text('New theme'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget, reason: 'the nav stays');
    final back = tester.getRect(find.byTooltip('Back to Themes'));
    final close = tester.getRect(find.byTooltip('Close settings'));
    expect(back.center.dy, close.center.dy);

    await tapIn(tester, find.text('Other'));
    expect(find.text('other pane'), findsOneWidget);
    expect(tester.getRect(find.byTooltip('Close settings')), close);
  });

  testWidgets('on a phone the header is the app bar', (tester) async {
    final rig = EditorRig();
    await rig.open(tester, size: phone);

    expect(find.text('New theme'), findsOneWidget);
    expect(find.byTooltip('Close settings'), findsNothing);
    expect(tester.getRect(find.byTooltip('Back to Themes')).top, lessThan(56));
  });

  for (final (name, size) in [('laptop', laptop), ('phone', phone)]) {
    testWidgets('on a $name the preview and footer stay put while the '
        'column scrolls, the preview folded short', (tester) async {
      final rig = EditorRig();
      await rig.open(tester, size: size);
      final preview = tester.getRect(byKey('theme-editor-preview'));
      final footer = tester.getRect(byKey('theme-editor-footer'));
      final column = tester.getRect(byKey('theme-editor-tokens'));
      final details = tester.getRect(byKey('theme-editor-details'));

      await tester.drag(byKey('theme-editor-tokens'), const Offset(0, -200));
      await settle(tester);

      final folded = tester.getRect(byKey('theme-editor-preview'));
      expect(folded.top, preview.top);
      expect(folded.height, lessThan(preview.height - 40));
      expect(tester.getRect(byKey('theme-editor-footer')), footer);
      expect(
        tester.getRect(byKey('theme-editor-details')).top,
        lessThan(details.top - 150),
      );
      expect(preview.top - column.top, inInclusiveRange(12, 16));
      expect(footer.top, column.bottom);
    });
  }

  testWidgets('a short window lets the preview scroll away', (tester) async {
    final rig = EditorRig();
    await rig.open(tester, size: const Size(1280, 560));
    final preview = tester.getRect(byKey('theme-editor-preview'));

    await tester.drag(byKey('theme-editor-tokens'), const Offset(0, -200));
    await settle(tester);

    expect(
      tester.getRect(byKey('theme-editor-preview')).top,
      lessThan(preview.top - 150),
    );
  });

  testWidgets('the preview and the check repaint while the square is '
      'dragged, and Cancel puts them back', (tester) async {
    final rig = EditorRig();
    await rig.open(tester);
    final before = _linkColour(tester);

    await tapIn(tester, byKey('theme-main-accent'));
    expect(find.text('Passes on every surface.'), findsOneWidget);
    expect(
      find.text(
        'Also sets Accent fill, Accent ring and Focus ring until you change '
        'them.',
      ),
      findsOneWidget,
    );
    final square = find.bySemanticsLabel('Saturation and brightness');
    await tester.ensureVisible(square);
    await settle(tester);
    final rect = tester.getRect(square);
    final drag = await tester.startGesture(rect.center);
    await drag.moveTo(rect.bottomLeft + const Offset(8, -8));
    await tester.pump();

    expect(_linkColour(tester), isNot(before));
    expect(find.textContaining('Needs 4.5:1 on'), findsOneWidget);
    await drag.up();
    await tester.pump();

    await tapIn(tester, find.text('Cancel'));
    expect(_linkColour(tester), before);
    expect(byKey('theme-picker-accent'), findsNothing);
  });

  testWidgets('Done keeps a typed colour and closes the picker', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);

    await tapIn(tester, byKey('theme-main-accent'));
    await _typeHex(tester, '#FFB000');
    expect(_linkColour(tester), const Color(0xFFFFB000));
    await tapIn(tester, find.byKey(AppColourPicker.confirmKey));

    expect(byKey('theme-picker-accent'), findsNothing);
    expect(_linkColour(tester), const Color(0xFFFFB000));
    expect(find.text('#FFB000'), findsWidgets);
  });

  for (final (name, size) in [('laptop', laptop), ('phone', phone)]) {
    testWidgets('on a $name the picker opens with no field focused, so no '
        'caret or handle covers the hex', (tester) async {
      final rig = EditorRig();
      await rig.open(tester, size: size);

      await tapIn(tester, byKey('theme-main-accent'));
      expect(find.byKey(AppColourPicker.hexFieldKey), findsOneWidget);
      expect(tester.testTextInput.hasAnyClients, isFalse);
    });
  }

  testWidgets('a see-through colour takes its opacity inside the picker', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);

    await tapIn(tester, byKey('theme-token-accentRing'));
    expect(
      find.descendant(
        of: byKey('theme-picker-accentRing'),
        matching: byKey('theme-picker-opacity-accentRing'),
      ),
      findsOneWidget,
    );
    expect(find.text('Follows Accent until you change it.'), findsOneWidget);
  });

  testWidgets('All colours is two columns of tiles at 556 of content', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);

    expect(tester.getSize(byKey('theme-editor-details')).width, 556);
    for (final token in themeTokenKeys) {
      expect(byKey('theme-token-$token'), findsOneWidget, reason: token);
    }
    final sunken = tester.getRect(byKey('theme-token-surfaceSunken'));
    final base = tester.getRect(byKey('theme-token-surfaceBase'));
    final raised = tester.getRect(byKey('theme-token-surfaceRaised'));
    expect(base.top, sunken.top);
    expect(base.left, greaterThan(sunken.right));
    expect(raised.left, sunken.left);
    expect(raised.top, greaterThan(sunken.bottom));
  });

  testWidgets('on a phone All colours folds into six groups at 358', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester, size: phone);

    expect(tester.getSize(byKey('theme-editor-details')).width, 358);
    for (final group in themeTokenGroups) {
      expect(byKey('theme-group-${group.title}'), findsOneWidget);
    }
    expect(byKey('theme-token-accentFill'), findsNothing);

    await tapIn(tester, byKey('theme-group-Accent'));
    for (final token in themeTokenGroups[2].tokens) {
      expect(byKey('theme-token-$token'), findsOneWidget, reason: token);
    }
  });

  testWidgets('on a phone each opacity slider sits right under its colour', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester, size: phone);
    for (final group in ['Accent', 'Status', 'Other']) {
      await tapIn(tester, byKey('theme-group-$group'));
    }

    expect(byKey('theme-opacity-accent'), findsNothing);
    for (final token in themeAlphaTokens) {
      await tester.ensureVisible(byKey('theme-opacity-$token'));
      await settle(tester);
      final row = tester.getRect(byKey('theme-token-$token'));
      final slider = tester.getRect(byKey('theme-opacity-$token'));
      expect(slider.top, greaterThanOrEqualTo(row.bottom), reason: token);
      expect(slider.top - row.bottom, lessThan(12), reason: token);
      expect(slider.left, greaterThan(row.left + AppSizes.icon24));
    }
  });

  testWidgets('on a phone a colour edited itself stops following Accent', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester, size: phone);
    await tapIn(tester, byKey('theme-group-Accent'));
    expect(find.text('Follows Accent'), findsNWidgets(3));
    expect(find.text('Fill, ring and focus follow it.'), findsOneWidget);

    await tapIn(tester, byKey('theme-token-accentFill'));
    await _typeHex(tester, '#884488');
    await tapIn(tester, find.byKey(AppColourPicker.confirmKey));

    expect(find.text('Follows Accent'), findsNWidgets(2));
    expect(find.text('Ring and focus follow it.'), findsOneWidget);
  });

  testWidgets('at a laptop the link mark leaves a tile edited itself', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);
    expect(_linkIcon('accentFill'), findsOneWidget);
    expect(_linkIcon('accent'), findsNothing);

    await tapIn(tester, byKey('theme-token-accentFill'));
    await _typeHex(tester, '#884488');
    await tapIn(tester, find.byKey(AppColourPicker.confirmKey));

    expect(_linkIcon('accentFill'), findsNothing);
    expect(_linkIcon('focusRing'), findsOneWidget);
  });

  testWidgets('Contrast groups by colour and a Fix clears that colour', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester, seed: ThemeEditorSeed(_twoFailing()));

    expect(find.textContaining('2 colours fail'), findsOneWidget);
    expect(byKey('theme-check-textPrimary'), findsOneWidget);
    expect(byKey('theme-check-accent'), findsOneWidget);

    await tapIn(tester, byKey('theme-check-fix-accent'));
    expect(byKey('theme-check-accent'), findsNothing);
    expect(byKey('theme-check-textPrimary'), findsOneWidget);
    expect(find.textContaining('1 colour fails'), findsOneWidget);
  });

  for (final (name, size) in [('laptop', laptop), ('phone', phone)]) {
    testWidgets('on a $name a failing theme says why in the footer and Fix '
        'all turns Save back on', (tester) async {
      final rig = EditorRig();
      await rig.open(
        tester,
        size: size,
        seed: ThemeEditorSeed(failingDocument()),
      );

      expect(find.text('3 checks fail.'), findsOneWidget);
      expect(find.text('Fix them under Contrast to save.'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);

      await tapIn(tester, byKey('theme-editor-fix-all'));
      expect(find.text('All 21 checks pass.'), findsOneWidget);
      expect(byKey('theme-editor-why'), findsNothing);
      expect(saveEnabled(tester), isTrue);
    });
  }

  testWidgets('the footer reason scrolls Contrast into view', (tester) async {
    final rig = EditorRig();
    await rig.open(tester, seed: ThemeEditorSeed(failingDocument()));
    final column = tester.getRect(byKey('theme-editor-tokens'));
    expect(
      tester.getRect(byKey('theme-contrast-panel')).top,
      greaterThan(column.bottom),
    );

    await tester.tap(byKey('theme-editor-why-link'));
    await settle(tester);

    final pinned = tester.getRect(byKey('theme-editor-preview')).bottom;
    final contrast = tester.getRect(byKey('theme-contrast-panel'));
    expect(contrast.top, greaterThan(pinned));
    expect(contrast.top, lessThan(pinned + 40), reason: 'just under the pin');
  });

  testWidgets('an invalid name says so in the footer', (tester) async {
    final rig = EditorRig();
    await rig.open(tester);

    await tester.enterText(byKey('theme-editor-name'), '   ');
    await tester.pump();

    expect(find.text('Give it a name of 1 to 40 characters.'), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('one Save on screen: the footer holds it, the kebab does not', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);

    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Save and apply'), findsOneWidget);
    final apply = tester.widget<AppButton>(byKey('theme-editor-apply'));
    expect(apply.variant, AppButtonVariant.primary);

    await tapIn(tester, byKey('theme-editor-menu'));
    expect(find.text('Publish to Space'), findsOneWidget);
    expect(find.text('Save and apply'), findsOneWidget);
    expect(find.text('Delete'), findsNothing, reason: 'not saved yet');
  });

  testWidgets('on a phone the kebab sheet is titled with the theme', (
    tester,
  ) async {
    final rig = EditorRig();
    final harbour = ThemeEditorSeed.fromBase(
      'dark',
    ).document.copyWith(name: 'Harbour');
    await rig.open(
      tester,
      size: phone,
      seed: ThemeEditorSeed(harbour, mineId: 'h1'),
    );

    await tapIn(tester, byKey('theme-editor-menu'));
    expect(find.widgetWithText(AppSheetHeader, 'Harbour'), findsOneWidget);
    expect(find.widgetWithText(AppSheetHeader, 'Mine'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('Details: the counter, Mode, and Start from showing its base '
      'and keeping the name', (tester) async {
    final rig = EditorRig();
    await rig.open(tester);
    final startFrom = byKey('theme-editor-start-from');

    expect(find.text('8/40'), findsOneWidget);
    expect(find.text('Choose a theme'), findsNothing);
    expect(
      find.descendant(of: startFrom, matching: find.text('Dark')),
      findsOneWidget,
    );

    await tester.enterText(byKey('theme-editor-name'), 'Mine now');
    // Typing scrolls the caret into view; a tap during that scroll is dropped.
    await settle(tester);
    await tapIn(tester, find.text('Light'));
    await tapIn(tester, startFrom);
    await tester.tap(find.text('Forest'));
    await settle(tester);
    expect(
      find.descendant(of: startFrom, matching: find.text('Forest')),
      findsOneWidget,
    );

    await tapIn(tester, byKey('theme-editor-save'));
    var saved = rig.container.read(myThemesProvider).single.document;
    expect(saved.name, 'Mine now');
    expect(saved.base, 'forest');
    expect(saved.brightness, Brightness.dark, reason: 'Start from sets mode');
    expect(saved.colours['accent'], themeBases['forest']!.accent);

    await tapIn(tester, find.text('Light'));
    await tapIn(tester, byKey('theme-editor-save'));
    saved = rig.container.read(myThemesProvider).single.document;
    expect(saved.brightness, Brightness.light);
  });
}
