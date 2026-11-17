// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the Theme card on Appearance says about the theme in use: its name,
/// where it came from, its one main action, what its preview paints with, and
/// which themes the Recent row offers back.
library;

import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart' show AppThemeChoice;
import 'my_themes.dart';
import 'recent_themes.dart';
import 'resolved_theme.dart';
import 'theme_gallery.dart';
import 'theme_labels.dart';
import 'theme_source.dart';

/// The button beside Browse themes.
enum ThemeMainAction {
  /// A copy of a built-in in the editor.
  customise,

  /// The Mine theme in the editor.
  edit,

  /// A copy in Mine of a theme nothing on this device keeps.
  saveToMine,
}

class ThemeSummary {
  const ThemeSummary({required this.name, this.source, this.action});

  final String name;

  /// 'In use · Built in' and the like; null for a theme nothing keeps, which
  /// shows Not saved instead.
  final String? source;

  /// Null when there is nothing to do but browse: System, or a followed
  /// default that Mine already holds.
  final ThemeMainAction? action;

  bool get unsaved => source == null;
}

ThemeSummary summariseTheme(AppliedTheme applied, List<MyTheme> mine) {
  final document = applied.document;
  final name = document?.name ?? themeLabel(applied.choice);
  final by = applied.author == null ? '' : ', by ${applied.author}';
  if (applied.following) {
    final kept =
        document != null &&
        mine.any((t) => themeMatchText(t.document) == themeMatchText(document));
    return ThemeSummary(
      name: name,
      source: 'In use · Space default$by',
      action: kept ? null : ThemeMainAction.saveToMine,
    );
  }
  return switch (applied.source) {
    BuiltInThemeSource(:final choice) when choice == AppThemeChoice.system =>
      ThemeSummary(
        name: name,
        source: 'In use · Built in, follows your device',
      ),
    BuiltInThemeSource() => ThemeSummary(
      name: name,
      source: 'In use · Built in',
      action: ThemeMainAction.customise,
    ),
    MineThemeSource() => ThemeSummary(
      name: name,
      source: 'In use · Mine',
      action: ThemeMainAction.edit,
    ),
    SpaceThemeSource() => ThemeSummary(
      name: name,
      source: 'In use · Space$by',
      action: ThemeMainAction.saveToMine,
    ),
    FileThemeSource() => ThemeSummary(
      name: name,
      action: ThemeMainAction.saveToMine,
    ),
  };
}

/// The palettes the theme in use paints with; System shows both halves.
({AppTokens tokens, AppTokens? split}) appliedThemeTokens(
  AppliedTheme applied,
) {
  if (applied.document case final document?) {
    return (tokens: document.tokens, split: null);
  }
  final tokens = builtInThemeTokens(applied.choice);
  if (tokens == null) return (tokens: AppTokens.light, split: AppTokens.dark);
  return (tokens: tokens, split: null);
}

/// The Recent row: the theme in use first, then the recent themes that can
/// still be applied, at most [max]. A Space theme the store has not listed
/// yet paints from the copy Recent kept.
List<ThemeGalleryEntry> recentThemeTiles(
  ThemeGallery gallery,
  List<RecentTheme> recents, {
  required int max,
}) {
  final all = [?gallery.unsaved, ...gallery.builtIn, ...gallery.mine];
  final current = [...all, ...gallery.space].where((e) => e.inUse).firstOrNull;
  final tiles = [?current];
  for (final recent in recents) {
    if (tiles.length >= max) break;
    if (recent.source == current?.source) continue;
    final entry = _entryFor(recent, gallery);
    if (entry != null && entry.broken == null) tiles.add(entry);
  }
  return tiles;
}

ThemeGalleryEntry? _entryFor(RecentTheme recent, ThemeGallery gallery) {
  final listed = [
    ...gallery.builtIn,
    ...gallery.mine,
    ...gallery.space,
  ].where((e) => e.source == recent.source).firstOrNull;
  if (listed != null) return listed;
  final kept = recent.theme;
  final source = recent.source;
  if (source is! SpaceThemeSource ||
      kept == null ||
      gallery.spaceState == ThemeGallerySpaceState.loaded) {
    return null;
  }
  final author = kept.author.trim();
  return ThemeGalleryEntry(
    source: source,
    kind: ThemeGalleryKind.space,
    name: kept.name,
    tokens: kept.tokens,
    brightness: kept.brightness,
    author: author.isEmpty ? null : author,
    // The store keeps picture settings only beside a picture, so the kept copy says one exists.
    pictureId: kept.picture == null ? null : source.id,
    document: kept,
  );
}

/// The Space default a Follow switch offers, or null when the Space has none
/// that can be applied.
ThemeGalleryEntry? followableSpaceDefault(ThemeGallery gallery) => gallery.space
    .where((e) => e.isSpaceDefault && e.broken == null && e.document != null)
    .firstOrNull;
