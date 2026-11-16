// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Themes gallery's snapshot fixture: Dark applied, Harbour and Sand in
/// Mine, four Space themes (one with a picture, one failing contrast), and
/// Nick signed in as an administrator.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_file_io.dart';
import 'package:slimm_app/src/features/settings/providers/theme_gallery.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

ThemeDocument themeFixture(
  String name,
  String base, {
  Color? accent,
  String author = '',
}) {
  final document = ThemeDocument.of(
    themeBases[base]!,
    name: name,
    author: author,
    base: base,
    brightness: base == 'light' ? Brightness.light : Brightness.dark,
  );
  if (accent == null) return document;
  return document.copyWith(
    colours: {
      ...document.colours,
      'accent': accent,
      'accentFill': accent,
      'focusRing': accent,
      'accentSoft': Color.lerp(document.colours['surfaceBase'], accent, 0.16)!,
    },
  );
}

final harbour = themeFixture(
  'Harbour',
  'dark',
  accent: const Color(0xFF2BB3A3),
);
final sand = themeFixture('Sand', 'light', accent: const Color(0xFF9A6B1F));
final lilac = themeFixture('Lilac', 'catppuccin');
final pumpkin = themeFixture('Pumpkin', 'halloween', author: 'Ren');

Map<String, dynamic> _paper() {
  final document = themeFixture('Paper', 'light', author: 'Grace');
  return document
      .copyWith(
        colours: {
          ...document.colours,
          'textPrimary': document.colours['surfaceBase']!,
        },
      )
      .toJson();
}

Map<String, dynamic> _stored(
  String id,
  String name,
  String author,
  Map<String, dynamic> file, {
  bool picture = false,
}) => {
  'id': id,
  'name': name,
  'author_id': 'user-${author.toLowerCase()}',
  'author_name': author,
  'created_at': 1,
  'has_picture': picture,
  'theme': file,
};

final _store = api.SpaceThemeList.fromJson({
  'default_theme_id': 'pine',
  'themes': [
    _stored(
      'pine',
      'Pine at dusk',
      'Ada',
      themeFixture('Pine at dusk', 'forest', author: 'Ada').toJson(),
      picture: true,
    ),
    _stored(
      'mocha',
      'Mine',
      'Nick',
      themeFixture('Mine', 'catppuccin').toJson(),
    ),
    _stored('pumpkin', 'Pumpkin', 'Ren', pumpkin.toJson()),
    _stored('paper', 'Paper', 'Grace', _paper()),
  ],
});

final Uint8List _picture = File(
  'test/fixtures/background_forest.png',
).readAsBytesSync();

class _Mine extends MyThemesController {
  _Mine(this.seeded);

  final List<MyTheme> seeded;

  @override
  List<MyTheme> build() {
    super.build();
    return seeded;
  }
}

class _Slot extends StoredThemeController {
  _Slot(this.seeded) : super(customThemeKey);

  final ThemeDocument? seeded;

  @override
  ThemeDocument? build() {
    super.build();
    return seeded;
  }
}

class _Source extends CustomThemeSourceController {
  _Source(this.seeded);

  final ThemeSource? seeded;

  @override
  ThemeSource? build() {
    super.build();
    return seeded;
  }
}

class _Filter extends ThemeGalleryFilterController {
  _Filter(this.seeded);

  final ThemeGalleryFilter seeded;

  @override
  ThemeGalleryFilter build() => seeded;
}

/// What a capture changes from the fixture.
List<Override> themesFixture({
  bool mine = true,
  bool store = true,
  bool emptyStore = false,
  ThemeDocument? applied,
  ThemeSource? source,
  ThemeGalleryFilter filter = ThemeGalleryFilter.all,
  ThemeFilePick? pick,
}) => [
  meProvider.overrideWith(
    (ref) async => const api.Me(
      id: 'user-nick',
      username: 'nick',
      displayName: 'Nick',
      createdAt: 0,
      permissions: Perm.manageServer,
    ),
  ),
  themeControllerProvider.overrideWith(
    (ref) => ThemeController(ref)
      ..state = applied == null ? AppThemeChoice.dark : AppThemeChoice.custom,
  ),
  customThemeProvider.overrideWith(() => _Slot(applied)),
  customThemeSourceProvider.overrideWith(() => _Source(source)),
  myThemesProvider.overrideWith(
    () => _Mine([
      if (mine) ...[
        MyTheme(id: 'harbour', document: harbour),
        MyTheme(id: 'sand', document: sand),
      ],
    ]),
  ),
  if (store)
    spaceThemesProvider.overrideWith(
      (ref) async => emptyStore
          ? api.SpaceThemeList.fromJson({'themes': <Object>[]})
          : _store,
    ),
  spaceThemePictureProvider.overrideWith((ref, id) async => _picture),
  themeGalleryFilterProvider.overrideWith(() => _Filter(filter)),
  if (pick != null) themeFilePickerProvider.overrideWithValue(() async => pick),
];

/// A file with more problems than the error lists.
final badFile = ThemeFilePick(
  fileName: 'lilac.json',
  bytes: utf8.encode(
    jsonEncode({
      'format': 'slimm-theme',
      'version': 1,
      'name': 'Lilac',
      'tokens': {'accent': 'purple'},
    }),
  ),
);
