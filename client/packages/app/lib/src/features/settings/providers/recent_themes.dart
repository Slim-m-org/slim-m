// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last few themes applied on this device, most recent first, so
/// Appearance can offer them back in one tap.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart';
import 'my_themes.dart';
import 'theme_source.dart';
import 'theme_store.dart';

const recentThemesKey = 'slimm.appearance.recent_themes';
const recentThemesMax = 5;

class RecentTheme {
  const RecentTheme({required this.source, this.theme});

  final ThemeSource source;

  /// A Space theme's file without its picture data, so its tile paints before the store loads.
  final ThemeDocument? theme;
}

class RecentThemesController extends Notifier<List<RecentTheme>>
    implements RestorablePreference {
  var _disposed = false;

  @override
  List<RecentTheme> build() {
    ref.onDispose(() => _disposed = true);
    return const [];
  }

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final text = prefs.getString(recentThemesKey);
      if (text == null || _disposed) return;
      state = _decode(text);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not read the recent themes; showing none',
        error,
        stack,
      );
    }
  }

  /// Puts [source] first; a file, or a choice that is not one theme, is never kept.
  Future<void> record(ThemeSource source, {ThemeDocument? theme}) async {
    if (!_keeps(source) || _disposed) return;
    final entry = RecentTheme(
      source: source,
      theme: source is SpaceThemeSource ? theme?.withoutPictureData() : null,
    );
    final next = [
      entry,
      for (final r in state)
        if (r.source != source) r,
    ].take(recentThemesMax).toList();
    state = next;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setString(recentThemesKey, _encode(next));
  }
}

bool _keeps(ThemeSource source) => switch (source) {
  BuiltInThemeSource(:final choice) =>
    choice != AppThemeChoice.spaceDefault && choice != AppThemeChoice.custom,
  MineThemeSource() => true,
  SpaceThemeSource(:final id) => id.isNotEmpty,
  FileThemeSource() => false,
};

String _encode(List<RecentTheme> recent) => jsonEncode([
  for (final r in recent)
    {'source': r.source.key, if (r.theme case final t?) 'theme': t.toJson()},
]);

List<RecentTheme> _decode(String text) {
  final raw = jsonDecode(text);
  if (raw is! List) return const [];
  final recent = <RecentTheme>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) continue;
    final key = entry['source'];
    final source = key is String ? ThemeSource.parse(key) : null;
    if (source == null || !_keeps(source)) continue;
    final theme = entry['theme'] == null
        ? null
        : parseThemeJson(entry['theme']).document;
    if (source is SpaceThemeSource && theme == null) continue;
    if (recent.any((r) => r.source == source)) continue;
    recent.add(RecentTheme(source: source, theme: theme));
  }
  return recent.take(recentThemesMax).toList();
}

final recentThemesProvider =
    NotifierProvider<RecentThemesController, List<RecentTheme>>(
      RecentThemesController.new,
    );

/// The recents that can still be applied: a deleted Mine theme, or a Space
/// theme a loaded store no longer lists, drops out of view.
final shownRecentThemesProvider = Provider.autoDispose<List<RecentTheme>>((
  ref,
) {
  final mine = ref.watch(myThemesProvider);
  final store = ref.watch(spaceThemesProvider).valueOrNull;
  return [
    for (final r in ref.watch(recentThemesProvider))
      if (switch (r.source) {
        MineThemeSource(:final id) => mine.any((t) => t.id == id),
        SpaceThemeSource(:final id) =>
          store == null || store.themes.any((t) => t.id == id),
        _ => true,
      })
        r,
  ];
});
