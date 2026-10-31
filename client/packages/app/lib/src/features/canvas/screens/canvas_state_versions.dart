// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Orders the canvas state that mutates in place, locks and media-slot tiles:
/// a frame that arrives late, or a read taken before a newer frame, must not
/// undo the newer state. A version of 0 means the server sent none, and then
/// everything applies as it did before versions existed.
library;

import 'dart:math' as math;

class CanvasStateVersions {
  int _floor = 0;
  final Map<String, int> _seen = {};

  /// Whether a frame at [version] for [key] is newer than what is held; records it when it is.
  bool accept(String key, int version) {
    if (version == 0) return true;
    if (version <= math.max(_floor, _seen[key] ?? 0)) return false;
    _seen[key] = version;
    return true;
  }

  /// Whether a read taken at [version] may overwrite [key], that is no newer frame applied meanwhile.
  bool mayReplace(String key, int version) =>
      version == 0 || (_seen[key] ?? 0) <= version;

  /// Keys a frame newer than a read at [version] already settled.
  Set<String> newerThan(int version) => {
    for (final entry in _seen.entries)
      if (entry.value > version) entry.key,
  };

  /// Records a read taken at [version]; frames at or below it are already in it.
  void applySnapshot(int version) {
    if (version > _floor) _floor = version;
    _seen.removeWhere((_, seen) => seen <= version);
  }
}
