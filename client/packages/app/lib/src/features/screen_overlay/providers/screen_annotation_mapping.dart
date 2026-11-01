// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a point on a viewer's tile lands on the sharer's real screen.
///
/// A mark is stored as 0 to 1 across the shared screen. A tile letterboxes the
/// video (`VideoViewFit.contain`), so the screen occupies only part of the
/// tile when their shapes differ; the mapping goes through that content rect
/// rather than the whole tile, or a mark would drift toward the bars.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show Alignment;

import 'package:slimm_platform/platform.dart' show OverlayMonitor;

/// The part of [box] the screen fills when fitted by `contain` at [aspect] (width over height).
Rect fitContent(Size box, double aspect) {
  if (box.isEmpty || !aspect.isFinite || aspect <= 0) {
    return Offset.zero & box;
  }
  final boxAspect = box.width / box.height;
  final Size fitted = boxAspect > aspect
      ? Size(box.height * aspect, box.height)
      : Size(box.width, box.width / aspect);
  return Alignment.center.inscribe(fitted, Offset.zero & box);
}

/// [local] (in the tile's own coordinates) as 0 to 1 across [content], clamped so a stroke that wanders onto the bars sticks to the screen's edge.
Offset toNormalised(Offset local, Rect content) {
  if (content.isEmpty) return Offset.zero;
  return Offset(
    ((local.dx - content.left) / content.width).clamp(0.0, 1.0),
    ((local.dy - content.top) / content.height).clamp(0.0, 1.0),
  );
}

/// [normalised] back to the tile's coordinates.
Offset fromNormalised(Offset normalised, Rect content) => Offset(
  content.left + normalised.dx * content.width,
  content.top + normalised.dy * content.height,
);

/// The monitor a share most likely covers.
///
/// [screenNumber] is the capturer's own 1-based "Screen N", trusted only where
/// the platform lists real monitors in order. Otherwise the monitor whose
/// shape best matches the captured size wins, and the primary monitor breaks
/// a tie. Returns an index into [monitors].
int pickSharedMonitor(
  List<OverlayMonitor> monitors, {
  int? screenNumber,
  Size? capturedSize,
}) {
  if (monitors.isEmpty) return 0;
  if (screenNumber != null &&
      screenNumber >= 1 &&
      screenNumber <= monitors.length) {
    return screenNumber - 1;
  }
  final primary = math.max(0, monitors.indexWhere((m) => m.primary));
  if (capturedSize == null || capturedSize.isEmpty) return primary;
  final want = capturedSize.width / capturedSize.height;
  var best = primary;
  var bestGap = (monitors[primary].aspect - want).abs();
  for (var i = 0; i < monitors.length; i++) {
    final gap = (monitors[i].aspect - want).abs();
    if (gap < bestGap - 0.01) {
      best = i;
      bestGap = gap;
    }
  }
  return best;
}

/// The 1-based number in a capturer label like "Screen 2", or null.
int? screenNumberFromLabel(String label) {
  final match = RegExp(
    r'^\s*Screen\s+(\d+)\s*$',
    caseSensitive: false,
  ).firstMatch(label);
  return match == null ? null : int.tryParse(match.group(1)!);
}
