// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the theme in use came from: a built-in, Mine, the Space store or a
/// file, so the gallery can mark the one card that is in use.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart';
import 'my_themes.dart';
import 'stored_theme.dart';
import 'theme_store.dart';

const customThemeSourceKey = 'slimm.appearance.custom_theme_source';

sealed class ThemeSource {
  const ThemeSource();

  /// How the source is stored: `builtin:<name>`, `mine:<id>`, `space:<id>` or `file`.
  String get key;

  /// Null for a key this version does not know.
  static ThemeSource? parse(String key) {
    if (key == FileThemeSource._key) return const FileThemeSource();
    final colon = key.indexOf(':');
    if (colon < 0) return null;
    final rest = key.substring(colon + 1);
    if (rest.isEmpty) return null;
    return switch (key.substring(0, colon)) {
      'builtin' => switch (AppThemeChoice.values.asNameMap()[rest]) {
        final choice? => BuiltInThemeSource(choice),
        null => null,
      },
      'mine' => MineThemeSource(rest),
      'space' => SpaceThemeSource(rest),
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) => other is ThemeSource && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

final class BuiltInThemeSource extends ThemeSource {
  const BuiltInThemeSource(this.choice);

  final AppThemeChoice choice;

  @override
  String get key => 'builtin:${choice.name}';
}

final class MineThemeSource extends ThemeSource {
  const MineThemeSource(this.id);

  final String id;

  @override
  String get key => 'mine:$id';
}

final class SpaceThemeSource extends ThemeSource {
  const SpaceThemeSource(this.id);

  final String id;

  @override
  String get key => 'space:$id';
}

final class FileThemeSource extends ThemeSource {
  const FileThemeSource();

  static const _key = 'file';

  @override
  String get key => _key;
}

/// The source recorded with the custom slot when it was applied.
class CustomThemeSourceController extends Notifier<ThemeSource?>
    implements RestorablePreference {
  var _disposed = false;

  @override
  ThemeSource? build() {
    ref.onDispose(() => _disposed = true);
    return null;
  }

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final text = prefs.getString(customThemeSourceKey);
      if (text != null && !_disposed) state = ThemeSource.parse(text);
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.data,
        'Could not read where the custom theme came from; inferring it',
        error,
        stack,
      );
    }
  }

  Future<void> set(ThemeSource source) async {
    if (_disposed) return;
    state = source;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setString(customThemeSourceKey, source.key);
  }
}

final customThemeSourceProvider =
    NotifierProvider<CustomThemeSourceController, ThemeSource?>(
      CustomThemeSourceController.new,
    );

/// The theme in use, where it came from, and whether it follows the Space.
class AppliedTheme {
  const AppliedTheme({
    required this.choice,
    required this.source,
    this.following = false,
    this.document,
    this.author,
    this.lost,
  });

  final AppThemeChoice choice;
  final ThemeSource source;

  /// True while the Space default is followed and the Space has one.
  final bool following;

  /// The file in use for a custom or followed theme.
  final ThemeDocument? document;
  final String? author;

  /// The Mine or Space entry this came from, when that entry is gone.
  final ThemeSource? lost;

  /// Applied from a file, or from an entry that is gone.
  bool get unsaved => source is FileThemeSource;
}

/// The text two theme files are compared by: no picture, which Mine never keeps.
String themeMatchText(ThemeDocument document) =>
    document.copyWith(dropPicture: true).toJsonText();

const _system = AppliedTheme(
  choice: AppThemeChoice.system,
  source: BuiltInThemeSource(AppThemeChoice.system),
);

final appliedThemeProvider = Provider.autoDispose<AppliedTheme>((ref) {
  final choice = ref.watch(themeControllerProvider);
  final store = ref.watch(spaceThemesProvider).valueOrNull;
  switch (choice) {
    case AppThemeChoice.spaceDefault:
      return _followed(store, ref.watch(spaceDefaultThemeProvider));
    case AppThemeChoice.custom:
      final document = ref.watch(customThemeProvider);
      if (document == null) return _system;
      return _custom(
        document,
        ref.watch(customThemeSourceProvider),
        ref.watch(myThemesProvider),
        store,
      );
    default:
      return AppliedTheme(choice: choice, source: BuiltInThemeSource(choice));
  }
});

/// The store answers once it has loaded; until then the local copy does.
AppliedTheme _followed(api.SpaceThemeList? store, ThemeDocument? local) {
  final id = store?.defaultThemeId;
  final listed = store?.themes.where((t) => t.id == id).firstOrNull;
  final document = listed == null
      ? (store == null ? local : null)
      : parseThemeJson(listed.theme).document;
  if (document == null) return _system;
  return AppliedTheme(
    choice: AppThemeChoice.spaceDefault,
    source: SpaceThemeSource(listed?.id ?? ''),
    following: true,
    document: document,
    author: _authorOf(document, listed),
  );
}

AppliedTheme _custom(
  ThemeDocument document,
  ThemeSource? stored,
  List<MyTheme> mine,
  api.SpaceThemeList? store,
) {
  AppliedTheme applied(ThemeSource source, {ThemeSource? lost}) {
    final listed = source is SpaceThemeSource
        ? store?.themes.where((t) => t.id == source.id).firstOrNull
        : null;
    return AppliedTheme(
      choice: AppThemeChoice.custom,
      source: source,
      document: document,
      author: source is SpaceThemeSource ? _authorOf(document, listed) : null,
      lost: lost,
    );
  }

  switch (stored) {
    case MineThemeSource(:final id):
      return mine.any((t) => t.id == id)
          ? applied(stored)
          : applied(const FileThemeSource(), lost: stored);
    case SpaceThemeSource(:final id):
      final gone = store != null && !store.themes.any((t) => t.id == id);
      return gone
          ? applied(const FileThemeSource(), lost: stored)
          : applied(stored);
    case FileThemeSource():
      return applied(stored);
    case BuiltInThemeSource() || null:
      return applied(_inferred(document, mine, store));
  }
}

ThemeSource _inferred(
  ThemeDocument document,
  List<MyTheme> mine,
  api.SpaceThemeList? store,
) {
  final text = themeMatchText(document);
  for (final t in mine) {
    if (themeMatchText(t.document) == text) return MineThemeSource(t.id);
  }
  for (final t in store?.themes ?? const <api.SpaceTheme>[]) {
    final listed = parseThemeJson(t.theme).document;
    if (listed != null && themeMatchText(listed) == text) {
      return SpaceThemeSource(t.id);
    }
  }
  return const FileThemeSource();
}

String? _authorOf(ThemeDocument document, api.SpaceTheme? listed) {
  final author = listed?.authorName ?? document.author;
  return author.trim().isEmpty ? null : author.trim();
}
