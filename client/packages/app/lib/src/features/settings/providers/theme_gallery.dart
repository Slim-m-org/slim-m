// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Themes gallery's model: every built-in, Mine and Space theme with what
/// its card shows, the one in use, and the source filter.
library;

import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart' show AppThemeChoice;
import 'my_themes.dart';
import 'resolved_theme.dart';
import 'theme_labels.dart';
import 'theme_source.dart';
import 'theme_store.dart';

/// The built-in themes in the order the gallery shows them.
const themeGalleryBuiltIns = [
  AppThemeChoice.system,
  AppThemeChoice.dark,
  AppThemeChoice.softDark,
  AppThemeChoice.light,
  AppThemeChoice.trueBlack,
  AppThemeChoice.catppuccin,
  AppThemeChoice.forest,
  AppThemeChoice.halloween,
];

enum ThemeGalleryKind { builtIn, mine, space, unsaved }

/// Why a Space theme cannot be applied.
enum ThemeBroken { contrast, unreadable }

enum ThemeGallerySpaceState { loading, failed, loaded }

enum ThemeGalleryFilter { all, builtIn, mine, space }

class ThemeGalleryEntry {
  const ThemeGalleryEntry({
    required this.source,
    required this.kind,
    required this.name,
    this.tokens,
    this.split,
    this.brightness = Brightness.dark,
    this.author,
    this.authorId,
    this.isSpaceDefault = false,
    this.pictureId,
    this.broken,
    this.document,
    this.inUse = false,
    this.lost,
  });

  /// What applying this card records; a Not saved card's is a file.
  final ThemeSource source;
  final ThemeGalleryKind kind;
  final String name;

  /// What the miniature paints with; null for a file that cannot be read.
  final AppTokens? tokens;

  /// System's dark half.
  final AppTokens? split;
  final Brightness brightness;
  final String? author;
  final String? authorId;
  final bool isSpaceDefault;

  /// The store theme whose picture shows in the miniature.
  final String? pictureId;
  final ThemeBroken? broken;

  /// The file, for a Mine, Space or Not saved theme; a theme that fails only
  /// contrast keeps it so Edit a copy can open it.
  final ThemeDocument? document;
  final bool inUse;

  /// A Not saved theme's Mine or Space entry, now gone.
  final ThemeSource? lost;

  AppThemeChoice? get choice => switch (source) {
    BuiltInThemeSource(:final choice) => choice,
    _ => null,
  };

  /// The Mine or Space id, for a key or an action.
  String? get id => switch (source) {
    MineThemeSource(:final id) || SpaceThemeSource(:final id) => id,
    _ => null,
  };
}

class ThemeGallery {
  const ThemeGallery({
    required this.builtIn,
    required this.mine,
    required this.space,
    required this.spaceState,
    this.unsaved,
  });

  final List<ThemeGalleryEntry> builtIn;

  /// The theme in use when nothing on this device or in the Space holds it.
  final ThemeGalleryEntry? unsaved;
  final List<ThemeGalleryEntry> mine;
  final List<ThemeGalleryEntry> space;
  final ThemeGallerySpaceState spaceState;
}

final themeGalleryProvider = Provider.autoDispose<ThemeGallery>((ref) {
  final applied = ref.watch(appliedThemeProvider);
  final store = ref.watch(spaceThemesProvider);
  final list = store.valueOrNull;
  return ThemeGallery(
    builtIn: [for (final choice in themeGalleryBuiltIns) _builtIn(choice)],
    unsaved: _unsaved(applied),
    mine: [
      for (final t in ref.watch(myThemesProvider))
        _document(t.document, MineThemeSource(t.id), ThemeGalleryKind.mine),
    ],
    space: [
      for (final t in list?.themes ?? const <api.SpaceTheme>[])
        _space(t, isDefault: t.id == list?.defaultThemeId),
    ],
    spaceState: store.hasValue
        ? ThemeGallerySpaceState.loaded
        : store.hasError
        ? ThemeGallerySpaceState.failed
        : ThemeGallerySpaceState.loading,
  ).withInUse(applied.unsaved ? null : applied.source);
});

ThemeGalleryEntry _builtIn(AppThemeChoice choice) {
  final system = choice == AppThemeChoice.system;
  return ThemeGalleryEntry(
    source: BuiltInThemeSource(choice),
    kind: ThemeGalleryKind.builtIn,
    name: themeLabel(choice),
    tokens: builtInThemeTokens(choice) ?? AppTokens.light,
    split: system ? AppTokens.dark : null,
    brightness: choice == AppThemeChoice.light || system
        ? Brightness.light
        : Brightness.dark,
  );
}

ThemeGalleryEntry _document(
  ThemeDocument document,
  ThemeSource source,
  ThemeGalleryKind kind, {
  String? author,
  ThemeSource? lost,
}) => ThemeGalleryEntry(
  source: source,
  kind: kind,
  name: document.name,
  tokens: document.tokens,
  brightness: document.brightness,
  author: author,
  document: document,
  lost: lost,
);

ThemeGalleryEntry _space(api.SpaceTheme theme, {required bool isDefault}) {
  final strict = parseThemeJson(theme.theme).document;
  final document =
      strict ?? parseThemeJson(theme.theme, checkContrast: false).document;
  final broken = strict != null
      ? null
      : document == null
      ? ThemeBroken.unreadable
      : ThemeBroken.contrast;
  final author = theme.authorName.trim().isNotEmpty
      ? theme.authorName.trim()
      : document?.author.trim();
  return ThemeGalleryEntry(
    source: SpaceThemeSource(theme.id),
    kind: ThemeGalleryKind.space,
    name: theme.name,
    tokens: document?.tokens,
    brightness: document?.brightness ?? Brightness.dark,
    author: author == null || author.isEmpty ? null : author,
    authorId: theme.authorId,
    isSpaceDefault: isDefault,
    pictureId: theme.hasPicture && broken == null ? theme.id : null,
    broken: broken,
    document: document,
  );
}

ThemeGalleryEntry? _unsaved(AppliedTheme applied) {
  final document = applied.document;
  if (!applied.unsaved || document == null) return null;
  return _document(
    document,
    const FileThemeSource(),
    ThemeGalleryKind.unsaved,
    lost: applied.lost,
  );
}

extension on ThemeGallery {
  /// Marks the card whose source is [inUse]; a Not saved theme is always in use.
  ThemeGallery withInUse(ThemeSource? inUse) {
    List<ThemeGalleryEntry> mark(List<ThemeGalleryEntry> entries) => [
      for (final e in entries) e.source == inUse ? e._inUse() : e,
    ];
    return ThemeGallery(
      builtIn: mark(builtIn),
      unsaved: unsaved?._inUse(),
      mine: mark(mine),
      space: mark(space),
      spaceState: spaceState,
    );
  }
}

extension on ThemeGalleryEntry {
  ThemeGalleryEntry _inUse() => ThemeGalleryEntry(
    source: source,
    kind: kind,
    name: name,
    tokens: tokens,
    split: split,
    brightness: brightness,
    author: author,
    authorId: authorId,
    isSpaceDefault: isSpaceDefault,
    pictureId: pictureId,
    broken: broken,
    document: document,
    inUse: true,
    lost: lost,
  );
}

/// Which sections the gallery shows; it lasts while the page is open.
class ThemeGalleryFilterController
    extends AutoDisposeNotifier<ThemeGalleryFilter> {
  @override
  ThemeGalleryFilter build() => ThemeGalleryFilter.all;

  void select(ThemeGalleryFilter filter) => state = filter;
}

final themeGalleryFilterProvider =
    NotifierProvider.autoDispose<
      ThemeGalleryFilterController,
      ThemeGalleryFilter
    >(ThemeGalleryFilterController.new);

extension ThemeGalleryFilterShows on ThemeGalleryFilter {
  bool shows(ThemeGalleryFilter section) =>
      this == ThemeGalleryFilter.all || this == section;
}
