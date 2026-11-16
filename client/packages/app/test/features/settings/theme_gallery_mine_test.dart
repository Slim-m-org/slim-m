// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gallery's Mine section: new, import, card menu actions, the Not saved
/// card, and the ways into the editor from a built-in or a Space theme.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_file_io.dart';
import 'package:slimm_app/src/features/settings/providers/theme_labels.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_gallery_menu.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_editor_harness.dart';
import 'theme_gallery_rig.dart' show revealInGallery;

Finder _key(String key) => find.byKey(Key(key));

ThemeDocument _doc(String name) => ThemeDocument.of(
  AppTokens.forest,
  name: name,
  author: '',
  base: 'forest',
  brightness: Brightness.dark,
);

ThemeFilePick _file(String text) =>
    ThemeFilePick(fileName: 'x.json', bytes: utf8.encode(text));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await revealInGallery(tester, finder);
  await tester.tap(finder);
  await settle(tester);
}

/// Applies [document] from a file, the way an older install held it.
Future<void> _applyUnsaved(EditorRig rig, ThemeDocument document) async {
  final c = rig.container;
  await c.read(customThemeProvider.notifier).set(document);
  await c.read(customThemeSourceProvider.notifier).set(const FileThemeSource());
  await c.read(themeControllerProvider.notifier).select(AppThemeChoice.custom);
}

Future<EditorRig> _page(WidgetTester tester, {EditorRig? rig}) async {
  final r = rig ?? EditorRig();
  await r.pump(tester, editor: false);
  return r;
}

void main() {
  testWidgets('with nothing saved the card says so and offers New', (
    tester,
  ) async {
    await _page(tester);
    expect(_key('theme-mine-empty'), findsOneWidget);
    expect(_key('theme-new'), findsOneWidget);
    expect(_key('theme-import'), findsOneWidget);
  });

  testWidgets('New opens the editor on a fresh theme', (tester) async {
    await _page(tester);
    await _tap(tester, _key('theme-new'));
    expect(_key('theme-editor-name'), findsOneWidget);
    expect(find.text('New theme'), findsOneWidget);
  });

  testWidgets('a saved theme is listed and Edit opens it', (tester) async {
    final rig = EditorRig();
    await _page(tester, rig: rig);
    final id = await rig.container
        .read(myThemesProvider.notifier)
        .save(_doc('Pine'));
    await tester.pump();

    expect(_key('theme-mine-$id'), findsOneWidget);
    await _tap(tester, _key('theme-mine-$id-menu'));
    await _tap(tester, find.text('Edit'));
    expect(find.text('Edit theme'), findsOneWidget);
    final name = tester.widget<EditableText>(
      find.descendant(
        of: _key('theme-editor-name'),
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
    );
    expect(name.controller.text, 'Pine');
  });

  testWidgets('tapping a saved theme applies it', (tester) async {
    final rig = EditorRig();
    await _page(tester, rig: rig);
    final id = await rig.container
        .read(myThemesProvider.notifier)
        .save(_doc('Pine'));
    await tester.pump();

    await _tap(tester, _key('theme-mine-$id'));
    expect(rig.container.read(themeControllerProvider), AppThemeChoice.custom);
    expect(rig.container.read(customThemeProvider)!.name, 'Pine');
  });

  testWidgets('importing a good file adds it to Mine', (tester) async {
    final rig = EditorRig()..pick = _file(_doc('Pine').toJsonText());
    await _page(tester, rig: rig);

    await _tap(tester, _key('theme-import'));
    expect(rig.container.read(myThemesProvider).map((t) => t.document.name), [
      'Pine',
    ]);
  });

  testWidgets('importing a bad file lists the problems and adds nothing', (
    tester,
  ) async {
    final rig = EditorRig()..pick = _file('{"format":"slimm-theme"}');
    await _page(tester, rig: rig);

    await _tap(tester, _key('theme-import'));
    expect(find.textContaining('Could not import x.json'), findsOneWidget);
    expect(rig.container.read(myThemesProvider), isEmpty);
  });

  testWidgets('a cancelled import does nothing', (tester) async {
    final rig = EditorRig();
    await _page(tester, rig: rig);

    await _tap(tester, _key('theme-import'));
    expect(rig.container.read(myThemesProvider), isEmpty);
    expect(find.textContaining('Could not import'), findsNothing);
  });

  testWidgets('a file that is not text is refused', (tester) async {
    final rig = EditorRig()
      ..pick = const ThemeFilePick(
        fileName: 'b.json',
        bytes: [0xff, 0xfe, 0xfd],
      );
    await _page(tester, rig: rig);

    await _tap(tester, _key('theme-import'));
    expect(find.textContaining('Could not import b.json'), findsOneWidget);
    expect(find.text('The file is not text.'), findsOneWidget);
  });

  testWidgets('export from a card saves the file', (tester) async {
    final rig = EditorRig();
    await _page(tester, rig: rig);
    final id = await rig.container
        .read(myThemesProvider.notifier)
        .save(_doc('Pine Fir'));
    await tester.pump();

    await _tap(tester, _key('theme-mine-$id-menu'));
    await _tap(tester, find.text('Export to file'));
    expect(rig.saved.single.$1, 'pine-fir.slimm-theme.json');
  });

  testWidgets('publish from a card posts and shows a cap error', (
    tester,
  ) async {
    final rig = EditorRig(
      publishStatus: 409,
      publishMessage: 'this Space is at its theme limit',
    );
    await _page(tester, rig: rig);
    final id = await rig.container
        .read(myThemesProvider.notifier)
        .save(_doc('Pine'));
    await tester.pump();

    await _tap(tester, _key('theme-mine-$id-menu'));
    await _tap(tester, find.text('Publish to Space'));
    expect(rig.calls, contains('POST /space/themes'));
    expect(find.textContaining('theme limit'), findsOneWidget);
  });

  testWidgets('delete from a card removes it once confirmed', (tester) async {
    final rig = EditorRig();
    await _page(tester, rig: rig);
    final id = await rig.container
        .read(myThemesProvider.notifier)
        .save(_doc('Pine'));
    await tester.pump();

    await _tap(tester, _key('theme-mine-$id-menu'));
    await _tap(tester, find.text('Delete'));
    expect(rig.container.read(myThemesProvider), hasLength(1));
    await _tap(tester, find.byKey(ThemeGalleryMenu.confirmKey));
    expect(rig.container.read(myThemesProvider), isEmpty);
  });

  testWidgets('an applied theme that is not in Mine can be saved there', (
    tester,
  ) async {
    final rig = EditorRig();
    await _page(tester, rig: rig);
    await _applyUnsaved(rig, _doc('Borrowed'));
    await tester.pump();

    expect(_key('theme-mine'), findsOneWidget);
    expect(find.text('Applied from a file. Save it to keep it.'), findsOne);
    await _tap(tester, _key('theme-mine-save'));
    final mine = rig.container.read(myThemesProvider);
    expect(mine.map((t) => t.document.name), ['Borrowed']);
    expect(
      rig.container.read(customThemeSourceProvider),
      MineThemeSource(mine.single.id),
    );
    expect(_key('theme-mine'), findsNothing);
  });

  testWidgets('the Not saved menu saves, publishes and exports', (
    tester,
  ) async {
    final rig = EditorRig();
    await _page(tester, rig: rig);
    await _applyUnsaved(rig, _doc('Borrowed'));
    await tester.pump();

    await _tap(tester, _key('theme-mine-menu'));
    expect(find.text('Save to Mine'), findsNWidgets(2));
    expect(find.text('Publish to Space'), findsOneWidget);
    await _tap(tester, find.text('Export to file'));
    expect(rig.saved.single.$1, 'borrowed.slimm-theme.json');
  });

  testWidgets('a Space theme applied and then removed reads as Not saved', (
    tester,
  ) async {
    final rig = EditorRig();
    await _page(tester, rig: rig);
    final c = rig.container;
    await c.read(customThemeProvider.notifier).set(_doc('Gone'));
    await c
        .read(customThemeSourceProvider.notifier)
        .set(const SpaceThemeSource('s9'));
    await c
        .read(themeControllerProvider.notifier)
        .select(AppThemeChoice.custom);
    await settle(tester);

    expect(find.text('It is no longer in the Space.'), findsOneWidget);
  });

  testWidgets('import keeps three problems and counts the rest', (
    tester,
  ) async {
    final rig = EditorRig()..pick = _file('{"format":"slimm-theme"}');
    await _page(tester, rig: rig);

    await _tap(tester, _key('theme-import'));
    expect(find.text('Could not import x.json.'), findsOneWidget);
    expect(find.textContaining(RegExp(r'And \d+ more\.')), findsOneWidget);
  });

  testWidgets('import past the limit says to delete one first', (tester) async {
    final rig = EditorRig()..pick = _file(_doc('Extra').toJsonText());
    await _page(tester, rig: rig);
    final mine = rig.container.read(myThemesProvider.notifier);
    for (var i = 0; i < myThemesMax; i++) {
      await mine.save(_doc('Theme $i'));
    }
    await tester.pump();

    await _tap(tester, _key('theme-import'));
    expect(
      find.text('This device holds $myThemesMax themes. Delete one first.'),
      findsOneWidget,
    );
    expect(rig.container.read(myThemesProvider), hasLength(myThemesMax));
  });

  testWidgets('Customise on a built-in opens a copy of it', (tester) async {
    await _page(tester);

    await _tap(tester, _key('theme-customise-forest'));
    expect(find.text('New theme'), findsOneWidget);
    final name = tester.widget<EditableText>(
      find.descendant(
        of: _key('theme-editor-name'),
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
    );
    expect(name.controller.text, 'Forest copy');
  });

  testWidgets('System and Space default have nothing to customise', (
    tester,
  ) async {
    await _page(tester);
    expect(_key('theme-customise-system'), findsNothing);
    expect(_key('theme-builtin-spaceDefault'), findsNothing);
  });

  testWidgets('Edit a copy on a Space theme opens it under a new name', (
    tester,
  ) async {
    final rig = EditorRig(
      storeThemes: [
        {
          'id': 's1',
          'name': 'Pine at dusk',
          'author_id': 'ren',
          'author_name': 'Ren',
          'created_at': 1,
          'has_picture': false,
          'theme': _doc('Pine at dusk').toJson(),
        },
      ],
    );
    await _page(tester, rig: rig);

    await _tap(tester, _key('theme-menu-s1'));
    await _tap(tester, find.text('Edit a copy'));
    final name = tester.widget<EditableText>(
      find.descendant(
        of: _key('theme-editor-name'),
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
    );
    expect(name.controller.text, 'Pine at dusk copy');
    expect(rig.container.read(myThemesProvider), isEmpty);
  });

  test('a copy name stays inside the name limit', () {
    expect(themeCopyName('Forest'), 'Forest copy');
    expect(themeCopyName('x' * 40).runes.length, themeNameMaxChars);
    expect(themeCopyName('x' * 40), endsWith(' copy'));
    expect(themeBaseOf(AppThemeChoice.forest), 'forest');
    expect(themeBaseOf(AppThemeChoice.system), isNull);
  });
}
