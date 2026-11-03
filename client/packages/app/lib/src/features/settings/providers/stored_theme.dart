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

class StoredThemeController extends StateNotifier<ThemeDocument?>
    implements RestorablePreference {
  StoredThemeController(this.ref, this.storageKey) : super(null);

  final Ref ref;
  final String storageKey;

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final text = prefs.getString(storageKey);
      if (text != null) state = parseThemeFile(text).document;
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
    if (!mounted) return;
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
    StateNotifierProvider<StoredThemeController, ThemeDocument?>(
      (ref) => StoredThemeController(ref, customThemeKey),
    );

final spaceDefaultThemeProvider =
    StateNotifierProvider<StoredThemeController, ThemeDocument?>(
      (ref) => StoredThemeController(ref, spaceDefaultThemeKey),
    );
