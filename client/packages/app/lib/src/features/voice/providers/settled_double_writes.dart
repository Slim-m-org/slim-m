// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Writes a dragged slider's value once it stops moving.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// How long a value must rest before it is written to disk.
const Duration kSettledWriteDelay = Duration(milliseconds: 400);

/// Keeps the newest value per key and writes it after [delay] of quiet, so a
/// drag costs one write instead of one per frame.
class SettledDoubleWrites {
  SettledDoubleWrites({this.delay = kSettledWriteDelay});

  final Duration delay;
  final Map<String, double> _unsaved = {};
  SharedPreferences? _prefs;
  Timer? _timer;

  void save(SharedPreferences prefs, String key, double value) {
    _prefs = prefs;
    _unsaved[key] = value;
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  /// Writes whatever is waiting now, for an owner about to go away.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final prefs = _prefs;
    if (prefs == null) return;
    final writes = Map.of(_unsaved);
    _unsaved.clear();
    for (final MapEntry(:key, :value) in writes.entries) {
      unawaited(prefs.setDouble(key, value));
    }
  }
}
