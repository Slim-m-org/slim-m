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

/// The monitors a share may cover, as indexes into [monitors].
///
/// [screenNumber] is the capturer's own 1-based "Screen N", trusted only where
/// the platform lists real monitors in order. Otherwise every monitor whose
/// shape matches the captured size is a candidate, and every monitor is one
/// when the size is unknown: Wayland never says which monitor the portal
/// picked and reports no primary, so guessing one would draw on the wrong screen.
List<int> pickSharedMonitors(
  List<OverlayMonitor> monitors, {
  int? screenNumber,
  Size? capturedSize,
}) {
  if (monitors.isEmpty) return const [0];
  if (screenNumber != null &&
      screenNumber >= 1 &&
      screenNumber <= monitors.length) {
    return [screenNumber - 1];
  }
  final all = [for (var i = 0; i < monitors.length; i++) i];
  if (capturedSize == null || capturedSize.isEmpty) return all;
  final want = capturedSize.width / capturedSize.height;
  final gaps = [for (final m in monitors) (m.aspect - want).abs()];
  final best = gaps.reduce(math.min);
  return [
    for (final i in all)
      if (gaps[i] <= best + 0.01) i,
  ];
}

/// The shape every monitor in [covered] shares, or null when they differ and the shared one is unknown.
double? sharedAspect(List<OverlayMonitor> monitors, List<int> covered) {
  if (covered.isEmpty || monitors.isEmpty) return null;
  final first = monitors[covered.first].aspect;
  final same = covered.every((i) => (monitors[i].aspect - first).abs() <= 0.01);
  return same ? first : null;
}

/// The 1-based number in a capturer label like "Screen 2", or null.
int? screenNumberFromLabel(String label) {
  final match = RegExp(
    r'^\s*Screen\s+(\d+)\s*$',
    caseSensitive: false,
  ).firstMatch(label);
  return match == null ? null : int.tryParse(match.group(1)!);
}
