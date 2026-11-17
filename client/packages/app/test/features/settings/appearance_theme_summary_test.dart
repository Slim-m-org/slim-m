// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the Theme card says about the theme in use, what its preview paints
/// with, and which themes Recent offers back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/appearance_theme_summary.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/recent_themes.dart';
import 'package:slimm_app/src/features/settings/providers/theme_gallery.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/providers/providers.dart' show AppThemeChoice;
import 'package:slimm_design_system/design_system.dart';

ThemeDocument _doc(String name, {String author = ''}) => ThemeDocument.of(
  AppTokens.forest,
  name: name,
  author: author,
  base: 'forest',
  brightness: Brightness.dark,
);

AppliedTheme _builtIn(AppThemeChoice choice) =>
    AppliedTheme(choice: choice, source: BuiltInThemeSource(choice));

AppliedTheme _custom(
  ThemeDocument document,
  ThemeSource source, {
  String? author,
}) => AppliedTheme(
  choice: AppThemeChoice.custom,
  source: source,
  document: document,
  author: author,
);

ThemeGalleryEntry _entry(
  ThemeSource source,
  ThemeGalleryKind kind,
  String name, {
  bool inUse = false,
  ThemeBroken? broken,
  bool isDefault = false,
}) => ThemeGalleryEntry(
  source: source,
  kind: kind,
  name: name,
  tokens: AppTokens.dark,
  inUse: inUse,
  broken: broken,
  isSpaceDefault: isDefault,
  document: _doc(name),
);

ThemeGallery _gallery({
  AppThemeChoice inUse = AppThemeChoice.dark,
  List<ThemeGalleryEntry> mine = const [],
  List<ThemeGalleryEntry> space = const [],
  ThemeGallerySpaceState state = ThemeGallerySpaceState.loaded,
  ThemeGalleryEntry? unsaved,
}) => ThemeGallery(
  builtIn: [
    for (final c in themeGalleryBuiltIns)
      _entry(
        BuiltInThemeSource(c),
        ThemeGalleryKind.builtIn,
        c.name,
        inUse: unsaved == null && c == inUse,
      ),
  ],
  mine: mine,
  space: space,
  spaceState: state,
  unsaved: unsaved,
);

RecentTheme _recent(ThemeSource source, {ThemeDocument? theme}) =>
    RecentTheme(source: source, theme: theme);

void main() {
  group('the source line and main action', () {
    test('a built-in is in use from Built in and can be customised', () {
      final s = summariseTheme(_builtIn(AppThemeChoice.forest), const []);
      expect(s.name, 'Forest');
      expect(s.source, 'In use · Built in');
      expect(s.action, ThemeMainAction.customise);
    });

    test('System follows the device and has nothing to customise', () {
      final s = summariseTheme(_builtIn(AppThemeChoice.system), const []);
      expect(s.name, 'System');
      expect(s.source, 'In use · Built in, follows your device');
      expect(s.action, isNull);
    });

    test('a Mine theme is edited', () {
      final s = summariseTheme(
        _custom(_doc('Harbour'), const MineThemeSource('m1')),
        const [],
      );
      expect(s.name, 'Harbour');
      expect(s.source, 'In use · Mine');
      expect(s.action, ThemeMainAction.edit);
    });

    test('a Space theme names its author and can be saved to Mine', () {
      final s = summariseTheme(
        _custom(_doc('Pine'), const SpaceThemeSource('p'), author: 'Ada'),
        const [],
      );
      expect(s.source, 'In use · Space, by Ada');
      expect(s.action, ThemeMainAction.saveToMine);
    });

    test('a file theme is Not saved and can be saved to Mine', () {
      final s = summariseTheme(
        _custom(_doc('Lilac'), const FileThemeSource()),
        const [],
      );
      expect(s.unsaved, isTrue);
      expect(s.source, isNull);
      expect(s.action, ThemeMainAction.saveToMine);
    });

    test('a followed default offers Save to Mine until Mine holds a copy', () {
      final pine = _doc('Pine', author: 'Ada');
      final followed = AppliedTheme(
        choice: AppThemeChoice.spaceDefault,
        source: const SpaceThemeSource('p'),
        following: true,
        document: pine,
        author: 'Ada',
      );
      final first = summariseTheme(followed, const []);
      expect(first.source, 'In use · Space default, by Ada');
      expect(first.action, ThemeMainAction.saveToMine);

      final kept = summariseTheme(followed, [
        MyTheme(
          id: 'm',
          document: pine.copyWith(author: 'Ada'),
        ),
      ]);
      expect(kept.action, isNull);

      final other = summariseTheme(followed, [
        MyTheme(id: 'm', document: _doc('Harbour')),
      ]);
      expect(other.action, ThemeMainAction.saveToMine);
    });
  });

  group('what the preview paints with', () {
    test('System shows both halves; a built-in or a file its own', () {
      final system = appliedThemeTokens(_builtIn(AppThemeChoice.system));
      expect(system.tokens, AppTokens.light);
      expect(system.split, AppTokens.dark);

      final soft = appliedThemeTokens(_builtIn(AppThemeChoice.softDark));
      expect(soft.tokens, AppTokens.soft);
      expect(soft.split, isNull);

      final pine = _doc('Pine');
      final custom = appliedThemeTokens(_custom(pine, const FileThemeSource()));
      expect(custom.tokens, pine.tokens);
    });
  });

  group('the Recent tiles', () {
    test('the theme in use comes first, then the recents in order', () {
      final harbour = _entry(
        const MineThemeSource('h'),
        ThemeGalleryKind.mine,
        'Harbour',
      );
      final tiles = recentThemeTiles(_gallery(mine: [harbour]), [
        _recent(const BuiltInThemeSource(AppThemeChoice.light)),
        _recent(const BuiltInThemeSource(AppThemeChoice.dark)),
        _recent(const MineThemeSource('h')),
      ], max: 5);
      expect(tiles.map((t) => t.name), ['dark', 'light', 'Harbour']);
      expect(tiles.first.inUse, isTrue);
    });

    test('stops at max and skips themes that cannot be applied', () {
      final broken = _entry(
        const SpaceThemeSource('x'),
        ThemeGalleryKind.space,
        'Paper',
        broken: ThemeBroken.contrast,
      );
      final tiles = recentThemeTiles(_gallery(space: [broken]), [
        _recent(const SpaceThemeSource('x')),
        _recent(const MineThemeSource('gone')),
        for (final c in [
          AppThemeChoice.light,
          AppThemeChoice.forest,
          AppThemeChoice.halloween,
          AppThemeChoice.catppuccin,
          AppThemeChoice.trueBlack,
        ])
          _recent(BuiltInThemeSource(c)),
      ], max: 4);
      expect(tiles.map((t) => t.name), [
        'dark',
        'light',
        'forest',
        'halloween',
      ]);
    });

    test('a Space recent paints from its copy until the store lists it', () {
      final pine = _doc('Pine at dusk', author: 'Ada');
      final recents = [_recent(const SpaceThemeSource('p'), theme: pine)];

      final loading = recentThemeTiles(
        _gallery(state: ThemeGallerySpaceState.loading),
        recents,
        max: 5,
      );
      expect(loading.last.name, 'Pine at dusk');
      expect(loading.last.author, 'Ada');
      expect(loading.last.tokens, pine.tokens);

      final gone = recentThemeTiles(_gallery(), recents, max: 5);
      expect(gone.map((t) => t.name), ['dark']);
    });

    test('a Space recent with a picture fetches it when applied', () {
      final pine = _doc('Pine at dusk');
      final pictured = ThemeDocument(
        name: pine.name,
        author: pine.author,
        base: pine.base,
        brightness: pine.brightness,
        colours: pine.colours,
        picture: const ThemePicture(dim: 0.4, vignette: true, blur: 0.2),
      );
      final tiles =
          recentThemeTiles(_gallery(state: ThemeGallerySpaceState.failed), [
            _recent(const SpaceThemeSource('p'), theme: pictured),
            _recent(const SpaceThemeSource('q'), theme: pine),
          ], max: 5);
      expect(tiles.map((t) => t.pictureId), [null, 'p', null]);
    });

    test('a Not saved theme in use leads the row', () {
      final lilac = _entry(
        const FileThemeSource(),
        ThemeGalleryKind.unsaved,
        'Lilac',
        inUse: true,
      );
      final tiles = recentThemeTiles(_gallery(unsaved: lilac), [
        _recent(const BuiltInThemeSource(AppThemeChoice.dark)),
      ], max: 5);
      expect(tiles.map((t) => t.name), ['Lilac', 'dark']);
    });
  });

  test('the Space default can be followed only while it applies', () {
    final pine = _entry(
      const SpaceThemeSource('p'),
      ThemeGalleryKind.space,
      'Pine',
      isDefault: true,
    );
    expect(followableSpaceDefault(_gallery(space: [pine])), same(pine));

    final broken = _entry(
      const SpaceThemeSource('p'),
      ThemeGalleryKind.space,
      'Pine',
      isDefault: true,
      broken: ThemeBroken.unreadable,
    );
    expect(followableSpaceDefault(_gallery(space: [broken])), isNull);
    expect(followableSpaceDefault(_gallery()), isNull);
  });
}
