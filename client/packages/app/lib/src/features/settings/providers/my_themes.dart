// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Mine": the themes a person made or imported, kept on this device.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_design_system/design_system.dart';

import '../../../ids.dart';
import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart' show preferencesProvider;

const myThemesKey = 'slimm.appearance.my_themes';

/// The most a device keeps, so a stored list stays small enough to read at startup.
const myThemesMax = 50;

class MyTheme {
  const MyTheme({required this.id, required this.document});

  final String id;
  final ThemeDocument document;
}

class MyThemesController extends Notifier<List<MyTheme>>
    implements RestorablePreference {
  var _disposed = false;

  @override
  List<MyTheme> build() {
    ref.onDispose(() => _disposed = true);
    return const [];
  }

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final text = prefs.getString(myThemesKey);
      if (text == null || _disposed) return;
      state = _decode(text);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not read the saved themes; using none',
        error,
        stack,
      );
    }
  }

  /// Stores [document] under [id], or as a new entry when [id] is null or unknown.
  /// Returns the id, or null when the device already holds [myThemesMax].
  Future<String?> save(ThemeDocument document, {String? id}) async {
    final kept = document.copyWith(dropPicture: true);
    final index = state.indexWhere((t) => t.id == id);
    if (index < 0 && state.length >= myThemesMax) return null;
    final saved = MyTheme(id: index < 0 ? newThemeId() : id!, document: kept);
    final next = [...state];
    if (index < 0) {
      next.add(saved);
    } else {
      next[index] = saved;
    }
    await _write(next);
    return saved.id;
  }

  Future<void> remove(String id) => _write([
    for (final t in state)
      if (t.id != id) t,
  ]);

  Future<void> _write(List<MyTheme> next) async {
    if (_disposed) return;
    state = next;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setString(myThemesKey, _encode(next));
  }
}

String _encode(List<MyTheme> themes) => jsonEncode([
  for (final t in themes) {'id': t.id, 'theme': t.document.toJson()},
]);

List<MyTheme> _decode(String text) {
  final raw = jsonDecode(text);
  if (raw is! List) return const [];
  final themes = <MyTheme>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) continue;
    final id = entry['id'];
    final document = parseThemeJson(entry['theme']).document;
    if (id is String && document != null) {
      themes.add(MyTheme(id: id, document: document));
    }
  }
  return themes;
}

final myThemesProvider = NotifierProvider<MyThemesController, List<MyTheme>>(
  MyThemesController.new,
);
