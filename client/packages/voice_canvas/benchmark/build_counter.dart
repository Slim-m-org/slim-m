// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Counts widget rebuilds and render-object repaints by type, so a benchmark says what a pointer move touched; debug-only hooks, empty in profile and release.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class BuildCounter {
  final Map<String, int> builds = <String, int>{};
  final Map<String, int> paints = <String, int>{};

  int get totalBuilds => builds.values.fold(0, (a, b) => a + b);
  int get totalPaints => paints.values.fold(0, (a, b) => a + b);

  void start() {
    reset();
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final type = element.widget.runtimeType.toString();
      builds[type] = (builds[type] ?? 0) + 1;
    };
    debugProfilePaintsEnabled = true;
    debugOnProfilePaint = (object) {
      final label = object is RenderCustomPaint
          ? 'CustomPaint(${object.painter.runtimeType})'
          : object.runtimeType.toString();
      paints[label] = (paints[label] ?? 0) + 1;
    };
  }

  void stop() {
    debugOnRebuildDirtyWidget = null;
    debugProfilePaintsEnabled = false;
    debugOnProfilePaint = null;
  }

  void reset() {
    builds.clear();
    paints.clear();
  }

  /// The [n] most frequent entries, formatted as `Type x count`.
  static String top(Map<String, int> counts, {int n = 6, int per = 1}) {
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(n)
        .map((e) =>
            '${e.key} x${(e.value / per).toStringAsFixed(per == 1 ? 0 : 1)}')
        .join(', ');
  }
}
