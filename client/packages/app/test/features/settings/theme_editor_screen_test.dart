// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme editor: colours, contrast gate, save, publish, export, delete.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/theme_draft.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_editor_harness.dart';

Finder _key(String key) => find.byKey(Key(key));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(finder);
  await settle(tester);
}

Future<void> _menu(WidgetTester tester, String label) async {
  await _tap(tester, _key('theme-editor-menu'));
  await tester.tap(find.text(label));
  await settle(tester);
}

Future<void> _typeHex(WidgetTester tester, String token, String hex) async {
  await tester.enterText(_key('theme-picker-$token'), hex);
  await tester.pump();
}

void main() {
  testWidgets('lists all 19 tokens in groups with the preview beside them', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.pump(tester);

    for (final token in themeTokenKeys) {
      expect(_key('theme-token-$token'), findsOneWidget, reason: token);
    }
    for (final group in themeTokenGroups) {
      expect(_key('theme-group-${group.title}'), findsOneWidget);
    }
    expect(_key('theme-editor-preview'), findsOneWidget);
    expect(_key('theme-contrast-ok'), findsOneWidget);
    final list = tester.getRect(_key('theme-editor-tokens'));
    final preview = tester.getRect(_key('theme-editor-preview'));
    expect(preview.left, greaterThanOrEqualTo(list.right));
  });

  testWidgets('on a phone the preview sits above the list', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester, size: const Size(390, 844));

    final list = tester.getRect(_key('theme-editor-tokens'));
    final preview = tester.getRect(_key('theme-editor-preview'));
    expect(preview.bottom, lessThanOrEqualTo(list.top));
  });

  testWidgets('a picked colour shows in the preview before it is saved', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.pump(tester);

    await _tap(tester, _key('theme-token-accent'));
    await _typeHex(tester, 'accent', '#FFB000');
    expect(find.text('Link to the build'), findsOneWidget);
    final link = tester.widget<Text>(find.text('Link to the build'));
    expect(link.style!.color, const Color(0xFFFFB000));
    expect(find.text('#FFB000'), findsWidgets);
  });

  testWidgets('cancelling the picker puts the colour back', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester);
    final before = themeBases['dark']!.accent;

    await _tap(tester, _key('theme-token-accent'));
    await _typeHex(tester, 'accent', '#FFB000');
    await _tap(tester, find.text('Cancel'));

    final link = tester.widget<Text>(find.text('Link to the build'));
    expect(link.style!.color, before);
  });

  testWidgets('a failing contrast blocks Save and Fix clears it', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.pump(tester, seed: ThemeEditorSeed(failingDocument()));

    expect(_key('theme-contrast-ok'), findsNothing);
    expect(_key('theme-check-textPrimary-surfaceBase'), findsOneWidget);

    expect(
      tester.widget<AppButton>(_key('theme-editor-save')).disabled,
      isTrue,
    );
    await _menu(tester, 'Save and apply');
    expect(find.text('Fix the failing contrast checks first.'), findsOneWidget);
    expect(rig.container.read(myThemesProvider), isEmpty);

    await _tap(tester, _key('theme-contrast-fix-all'));
    expect(_key('theme-contrast-ok'), findsOneWidget);

    await _tap(tester, _key('theme-editor-save'));
    final mine = rig.container.read(myThemesProvider);
    expect(mine.map((t) => t.document.name), ['Faint']);
    expect(parseThemeJson(mine.single.document.toJson()).problems, isEmpty);
  });

  testWidgets('one Fix repairs its own check', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester, seed: ThemeEditorSeed(failingDocument()));

    await _tap(tester, _key('theme-check-fix-textPrimary-surfaceBase'));
    expect(_key('theme-check-textPrimary-surfaceBase'), findsNothing);
  });

  testWidgets('an empty name cannot be saved', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester);

    await tester.enterText(_key('theme-editor-name'), '   ');
    await tester.pump();
    expect(
      tester.widget<AppButton>(_key('theme-editor-save')).disabled,
      isTrue,
    );
    await _menu(tester, 'Save and apply');
    expect(find.textContaining('Give the theme a name'), findsOneWidget);
    expect(rig.container.read(myThemesProvider), isEmpty);
  });

  testWidgets('saving twice updates the same entry', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester);

    await tester.enterText(_key('theme-editor-name'), 'Dusk');
    await _tap(tester, _key('theme-editor-save'));
    await tester.enterText(_key('theme-editor-name'), 'Dusk two');
    await _tap(tester, _key('theme-editor-save'));

    final mine = rig.container.read(myThemesProvider);
    expect(mine.map((t) => t.document.name), ['Dusk two']);
  });

  testWidgets('opacity tokens take a slider', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester);

    expect(_key('theme-opacity-accentRing'), findsOneWidget);
    expect(_key('theme-opacity-accent'), findsNothing);
  });

  testWidgets('Start from replaces the colours and keeps the name', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.pump(tester);

    await tester.enterText(_key('theme-editor-name'), 'Mine now');
    await tester.tap(find.text('Choose a theme'));
    await settle(tester);
    await tester.tap(find.text('Forest'));
    await settle(tester);
    await _tap(tester, _key('theme-editor-save'));

    final saved = rig.container.read(myThemesProvider).single.document;
    expect(saved.name, 'Mine now');
    expect(saved.base, 'forest');
    expect(saved.colours['accent'], themeBases['forest']!.accent);
  });

  testWidgets('publishing posts the theme file under the member name', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.pump(tester);
    rig.container.listen(meProvider, (_, _) {});
    await rig.container.read(meProvider.future);

    await _menu(tester, 'Publish to Space');

    expect(rig.calls, contains('POST /space/themes'));
    final body = rig.published! as Map<String, dynamic>;
    expect(body['format'], 'slimm-theme');
    expect(body['author'], 'Self');
    expect(_key('theme-editor-notice'), findsOneWidget);
  });

  testWidgets('a full author quota is shown, not swallowed', (tester) async {
    final rig = EditorRig(
      publishStatus: 409,
      publishMessage:
          'you have published 5 themes already - remove one to publish another',
    );
    await rig.pump(tester);

    await _menu(tester, 'Publish to Space');

    expect(_key('theme-editor-error'), findsOneWidget);
    expect(find.textContaining('published 5 themes already'), findsOneWidget);
  });

  testWidgets('a full Space is shown, not swallowed', (tester) async {
    final rig = EditorRig(
      publishStatus: 409,
      publishMessage: 'this Space is at its theme limit',
    );
    await rig.pump(tester);

    await _menu(tester, 'Publish to Space');
    expect(find.textContaining('theme limit'), findsOneWidget);
  });

  testWidgets('a failing theme is not published', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester, seed: ThemeEditorSeed(failingDocument()));

    await _menu(tester, 'Publish to Space');
    expect(rig.calls.where((c) => c.startsWith('POST')), isEmpty);
    expect(_key('theme-editor-error'), findsOneWidget);
  });

  testWidgets('export writes the theme file and it reads back', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester);

    await tester.enterText(_key('theme-editor-name'), 'Dusk Rose');
    await _menu(tester, 'Export to file');

    final (name, bytes) = rig.saved.single;
    expect(name, 'dusk-rose.slimm-theme.json');
    final parsed = parseThemeFile(utf8.decode(bytes));
    expect(parsed.problems, isEmpty);
    expect(parsed.document!.name, 'Dusk Rose');
  });

  testWidgets('delete removes a saved theme after asking', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester);
    await tester.enterText(_key('theme-editor-name'), 'Gone soon');
    await _tap(tester, _key('theme-editor-save'));
    expect(rig.container.read(myThemesProvider), hasLength(1));

    await _menu(tester, 'Delete');
    await _tap(tester, _key('theme-editor-confirm'));

    expect(rig.container.read(myThemesProvider), isEmpty);
    expect(_key('theme-new'), findsOneWidget);
  });

  testWidgets('leaving with unsaved changes asks first', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester);

    await tester.enterText(_key('theme-editor-name'), 'Changed');
    await tester.pump();
    await _tap(tester, find.byTooltip('Back to Themes'));
    expect(_key('theme-editor-confirm'), findsOneWidget);
    expect(_key('theme-new'), findsNothing);

    await _tap(tester, _key('theme-editor-confirm'));
    expect(_key('theme-new'), findsOneWidget);
  });

  testWidgets('leaving a clean editor does not ask', (tester) async {
    final rig = EditorRig();
    await rig.pump(tester);

    await _tap(tester, find.byTooltip('Back to Themes'));
    expect(_key('theme-new'), findsOneWidget);
  });

  testWidgets('on a phone a colour opens a sheet and cancel reverts it', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.pump(tester, size: const Size(390, 844));
    final before = themeBases['dark']!.accent;

    await _tap(tester, _key('theme-token-accent'));
    await tester.enterText(find.byKey(AppColourPicker.hexFieldKey), '#FFB000');
    await tester.pump();
    final link = tester.widget<Text>(find.text('Link to the build'));
    expect(link.style!.color, const Color(0xFFFFB000));

    await _tap(tester, find.text('Cancel'));
    final after = tester.widget<Text>(find.text('Link to the build'));
    expect(after.style!.color, before);
  });
}
