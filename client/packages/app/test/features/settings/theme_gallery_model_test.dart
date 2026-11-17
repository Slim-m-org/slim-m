// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gallery's model: which card is in use for every source, System when
/// nothing is followed, the Not saved card, broken Space themes, the Space
/// section's state, the filter, and the import error's shape.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_gallery.dart';
import 'package:slimm_app/src/features/settings/providers/theme_gallery_actions.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'theme_gallery_rig.dart' show failingFile, galleryDoc, stored;

/// Null [themes] never loads the store; [fails] makes it fail.
ProviderContainer _container({
  List<Map<String, dynamic>>? themes = const [],
  String? defaultId,
  bool fails = false,
}) {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      spaceThemesProvider.overrideWith((ref) {
        if (fails) return Future.error(StateError('down'));
        if (themes == null) return Completer<api.SpaceThemeList>().future;
        return Future.value(
          api.SpaceThemeList.fromJson({
            'themes': themes,
            'default_theme_id': defaultId,
          }),
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  container.listen(themeGalleryProvider, (_, _) {});
  return container;
}

Future<ThemeGallery> _gallery(ProviderContainer c) async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return c.read(themeGalleryProvider);
}

Future<void> _apply(
  ProviderContainer c,
  ThemeDocument document,
  ThemeSource source,
) async {
  await c.read(customThemeProvider.notifier).set(document);
  await c.read(customThemeSourceProvider.notifier).set(source);
  await c.read(themeControllerProvider.notifier).select(AppThemeChoice.custom);
}

List<String> _inUse(ThemeGallery g) => [
  for (final e in [...g.builtIn, ?g.unsaved, ...g.mine, ...g.space])
    if (e.inUse) e.name,
];

void main() {
  test(
    'applying a theme reads no Space file again; a changed one is read',
    () async {
      var themes = [stored('t1', 'Pine'), stored('t2', 'Fern')];
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          spaceThemesProvider.overrideWith(
            (ref) async => api.SpaceThemeList.fromJson({
              'themes': themes,
              'default_theme_id': null,
            }),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(themeGalleryProvider, (_, _) {});
      final before = (await _gallery(c)).space;

      await _apply(c, galleryDoc('Lilac'), const FileThemeSource());
      final applied = (await _gallery(c)).space;
      expect(applied.map((e) => e.name), ['Pine', 'Fern']);
      for (final i in [0, 1]) {
        expect(identical(applied[i].document, before[i].document), isTrue);
      }

      themes = [
        stored('t1', 'Pine'),
        stored('t2', 'Fern', file: galleryDoc('Fern', base: 'dark').toJson()),
      ];
      c.invalidate(spaceThemesProvider);
      final refetched = (await _gallery(c)).space;
      expect(identical(refetched[0].document, before[0].document), isTrue);
      expect(refetched[1].document!.base, 'dark');
    },
  );

  test('built-ins come in the gallery order, the chosen one in use', () async {
    final c = _container();
    await c.read(themeControllerProvider.notifier).select(AppThemeChoice.dark);
    final g = await _gallery(c);
    expect(g.builtIn.map((e) => e.name), [
      'System',
      'Dark',
      'Soft dark',
      'Light',
      'True black',
      'Catppuccin',
      'Forest',
      'Halloween',
    ]);
    expect(_inUse(g), ['Dark']);
    expect(g.builtIn.first.split, AppTokens.dark);
  });

  test('System is in use while following a Space with no default', () async {
    final g = await _gallery(_container());
    expect(_inUse(g), ['System']);
  });

  test('the followed default is the one card in use', () async {
    final c = _container(
      themes: [stored('t1', 'Pine'), stored('t2', 'Fir')],
      defaultId: 't1',
    );
    final g = await _gallery(c);
    expect(_inUse(g), ['Pine']);
    expect(g.space.first.isSpaceDefault, isTrue);
    expect(g.space.last.isSpaceDefault, isFalse);
  });

  test('a Mine theme and a Space theme are in use from their source', () async {
    final c = _container(themes: [stored('t1', 'Pine')]);
    final id = await c.read(myThemesProvider.notifier).save(galleryDoc('Fir'));
    await _apply(c, galleryDoc('Fir'), MineThemeSource(id!));
    expect(_inUse(await _gallery(c)), ['Fir']);

    await _apply(c, galleryDoc('Pine'), const SpaceThemeSource('t1'));
    final g = await _gallery(c);
    expect(_inUse(g), ['Pine']);
    expect(g.unsaved, isNull);
  });

  test('a theme from a file is Not saved, and only it is in use', () async {
    final c = _container();
    await _apply(c, galleryDoc('Lilac'), const FileThemeSource());
    final g = await _gallery(c);
    expect(g.unsaved?.name, 'Lilac');
    expect(g.unsaved?.lost, isNull);
    expect(_inUse(g), ['Lilac']);
  });

  test(
    'a Mine or Space entry that is gone leaves its theme Not saved',
    () async {
      final c = _container(themes: [stored('t1', 'Pine')]);
      await _apply(c, galleryDoc('Gone'), const MineThemeSource('m9'));
      var g = await _gallery(c);
      expect(g.unsaved?.lost, const MineThemeSource('m9'));

      await _apply(c, galleryDoc('Left'), const SpaceThemeSource('s9'));
      g = await _gallery(c);
      expect(g.unsaved?.lost, const SpaceThemeSource('s9'));
    },
  );

  test('a Space theme says why it cannot be applied', () async {
    final c = _container(
      themes: [
        stored('p1', 'Paper', file: failingFile('Paper'), picture: true),
        stored('u1', 'Scrap', file: {'format': 'slimm-theme'}),
        stored('ok', 'Fine', picture: true),
      ],
    );
    final g = await _gallery(c);
    final [paper, scrap, fine] = g.space;
    expect(paper.broken, ThemeBroken.contrast);
    expect(paper.document?.name, 'Paper');
    expect(paper.pictureId, isNull);
    expect(scrap.broken, ThemeBroken.unreadable);
    expect(scrap.tokens, isNull);
    expect(fine.broken, isNull);
    expect(fine.pictureId, 'ok');
    expect(fine.author, 'Ren');
  });

  test('the Space section loads, fails, or holds its themes', () async {
    expect(
      (await _gallery(_container(themes: null))).spaceState,
      ThemeGallerySpaceState.loading,
    );
    expect(
      (await _gallery(_container(fails: true))).spaceState,
      ThemeGallerySpaceState.failed,
    );
    expect(
      (await _gallery(_container())).spaceState,
      ThemeGallerySpaceState.loaded,
    );
  });

  test('the filter shows all sections or just one', () {
    for (final section in ThemeGalleryFilter.values.skip(1)) {
      expect(ThemeGalleryFilter.all.shows(section), isTrue);
      for (final other in ThemeGalleryFilter.values.skip(1)) {
        expect(section.shows(other), other == section);
      }
    }
  });

  test('an import error lists three problems and counts the rest', () {
    final five = themeImportError('x.json', ['a', 'b', 'c', 'd', 'e']);
    expect(five.message, 'Could not import x.json.');
    expect(five.detail, 'a\nb\nc\nAnd 2 more.');
    expect(themeImportError('x.json', ['a']).detail, 'a');
  });

  test('Customise and Edit a copy name the copy, and System has none', () {
    expect(customiseSeed(AppThemeChoice.system), isNull);
    expect(customiseSeed(AppThemeChoice.forest)!.document.name, 'Forest copy');
    final entry = ThemeGalleryEntry(
      source: const SpaceThemeSource('t1'),
      kind: ThemeGalleryKind.space,
      name: 'x' * 40,
      document: galleryDoc('x' * 40),
    );
    final copy = editCopySeed(entry)!.document;
    expect(copy.name.runes.length, themeNameMaxChars);
    expect(copy.author, isEmpty);
  });
}
