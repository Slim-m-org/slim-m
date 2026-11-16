// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which theme the background's dim, vignette and blur came with, so the
/// Background card can say so until someone changes them there.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart';

const backgroundFromThemeKey = 'slimm.appearance.background_from';

/// The theme's name, or null once the background is the person's own.
class BackgroundFromThemeController extends Notifier<String?>
    implements RestorablePreference {
  var _disposed = false;

  @override
  String? build() {
    ref.onDispose(() => _disposed = true);
    return null;
  }

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final name = prefs.getString(backgroundFromThemeKey);
      if (!_disposed) state = name;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not read which theme the background came with',
        error,
        stack,
      );
    }
  }

  Future<void> set(String name) async {
    if (_disposed) return;
    state = name;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setString(backgroundFromThemeKey, name);
  }

  /// A change made on the Background card: the settings are the person's now.
  Future<void> clear() async {
    if (_disposed || state == null) return;
    state = null;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.remove(backgroundFromThemeKey);
  }
}

final backgroundFromThemeProvider =
    NotifierProvider<BackgroundFromThemeController, String?>(
      BackgroundFromThemeController.new,
    );
