// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The themes the editor's Start from offers, read once per change to Mine
/// or the Space's store rather than on every colour the editor shows.
library;

import 'package:flutter/foundation.dart' show Brightness;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'my_themes.dart';
import 'theme_store.dart';

class ThemeEditorSource {
  const ThemeEditorSource(this.key, this.label, this.document);

  final String key;
  final String label;
  final ThemeDocument document;
}

/// Every theme the editor can start from: built-in, then Mine, then the Space.
List<ThemeEditorSource> themeEditorSources({
  required List<MyTheme> mine,
  required List<api.SpaceTheme> space,
}) => [
  for (final entry in themeBases.entries)
    ThemeEditorSource(
      'base:${entry.key}',
      themeBaseLabels[entry.key]!,
      ThemeDocument.of(
        entry.value,
        name: themeBaseLabels[entry.key]!,
        author: '',
        base: entry.key,
        brightness: entry.key == 'light' ? Brightness.light : Brightness.dark,
      ),
    ),
  for (final t in mine)
    ThemeEditorSource('mine:${t.id}', '${t.document.name} (mine)', t.document),
  for (final t in space)
    if (parseThemeJson(t.theme).document case final document?)
      ThemeEditorSource('space:${t.id}', '${t.name} (Space)', document),
];

final themeEditorSourcesProvider =
    Provider.autoDispose<List<ThemeEditorSource>>(
      (ref) => themeEditorSources(
        mine: ref.watch(myThemesProvider),
        space: ref.watch(spaceThemesProvider).valueOrNull?.themes ?? const [],
      ),
    );

/// How a built-in preset is named where a person picks one.
const themeBaseLabels = {
  'dark': 'Dark',
  'light': 'Light',
  'trueBlack': 'True black',
  'catppuccin': 'Catppuccin',
  'softDark': 'Soft dark',
  'forest': 'Forest',
  'halloween': 'Halloween',
};
