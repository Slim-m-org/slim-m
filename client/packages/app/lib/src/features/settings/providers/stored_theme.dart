// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A theme document kept on this device: the custom theme in use, and a copy
/// of the Space default so "Space default" resolves before the first request.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart' show preferencesProvider;

const customThemeKey = 'slimm.appearance.custom_theme';
const spaceDefaultThemeKey = 'slimm.appearance.space_default_theme';

class StoredThemeController extends Notifier<ThemeDocument?>
    implements RestorablePreference {
  StoredThemeController(this.storageKey);

  final String storageKey;
  var _disposed = false;

  @override
  ThemeDocument? build() {
    ref.onDispose(() => _disposed = true);
    return null;
  }

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final text = prefs.getString(storageKey);
      if (text != null && !_disposed) state = parseThemeFile(text).document;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not read a saved theme; using none',
        error,
        stack,
      );
    }
  }

  /// Keeps [document] without its picture, which lives in the personal background.
  Future<void> set(ThemeDocument? document) async {
    if (_disposed) return;
    state = document;
    final prefs = await ref.read(preferencesProvider.future);
    if (document == null) {
      await prefs.remove(storageKey);
      return;
    }
    await prefs.setString(
      storageKey,
      document.withoutPictureData().toJsonText(),
    );
  }
}

final customThemeProvider =
    NotifierProvider<StoredThemeController, ThemeDocument?>(
      () => StoredThemeController(customThemeKey),
    );

final spaceDefaultThemeProvider =
    NotifierProvider<StoredThemeController, ThemeDocument?>(
      () => StoredThemeController(spaceDefaultThemeKey),
    );
