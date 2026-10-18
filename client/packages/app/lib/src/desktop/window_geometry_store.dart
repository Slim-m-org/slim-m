// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Persists [WindowGeometry] as one JSON blob under one key, the same
/// one-value-per-feature shape `display_preferences.dart`'s controllers
/// already use, rather than five separate keys for size, position and state.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'window_geometry.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const windowGeometryPreferenceKey = 'slimm.desktop.window_geometry';

class WindowGeometryStore {
  const WindowGeometryStore(this._prefs);

  final SharedPreferences _prefs;

  /// Null on a fresh install, or if the stored value is corrupt - a broken
  /// blob degrades to "nothing saved yet" rather than a crash on launch. A
  /// value that decodes fine but [looksLikeSplashSize] is healed to
  /// [WindowGeometry.fallback] instead - see [healSplashCorruption] for why
  /// that self-heals every build shipped before the write-time fix landed.
  WindowGeometry? read() {
    final raw = _prefs.getString(windowGeometryPreferenceKey);
    if (raw == null) return null;
    try {
      final decoded = WindowGeometry.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return healSplashCorruption(decoded);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not read the saved window position; using the default',
        error,
        stack,
      );
      return null;
    }
  }

  Future<void> write(WindowGeometry geometry) => _prefs.setString(
    windowGeometryPreferenceKey,
    jsonEncode(geometry.toJson()),
  );
}
