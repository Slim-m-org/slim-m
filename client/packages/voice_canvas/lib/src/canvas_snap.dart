// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure snapping arithmetic for dragging and resizing a canvas object: given
/// the box being moved and the boxes it could align to, the offset that lines
/// an edge or centre up with a target, and the guide lines to draw for it.
///
/// Kept free of [CanvasDocument] and the camera so it is testable with plain
/// rects; the caller converts its screen-pixel reach to world units.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// The screen distance, in logical pixels, inside which an edge or centre
/// pulls onto a neighbour. A screen quantity so the pull feels the same at
/// any zoom; divide by the camera zoom to get world units.
const double snapScreenThreshold = 6.0;

/// One alignment line to draw while a snap is active: a vertical line at
/// x == [position] when [vertical], else a horizontal one at y == [position],
/// spanning [start] to [end] along the other axis. All in world units.
class SnapGuide {
  const SnapGuide({
    required this.vertical,
    required this.position,
    required this.start,
    required this.end,
  });

  final bool vertical;
  final double position;
  final double start;
  final double end;

  @override
  bool operator ==(Object other) =>
      other is SnapGuide &&
      other.vertical == vertical &&
      other.position == position &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(vertical, position, start, end);

  @override
  String toString() =>
      'SnapGuide(${vertical ? 'x' : 'y'}=$position, $start..$end)';
}

/// The shift to add to the moving box, and the guides it produces.
class SnapResult {
  const SnapResult(this.offset, this.guides);

  final Offset offset;
  final List<SnapGuide> guides;

  static const none = SnapResult(Offset.zero, []);
}

/// Snaps [moving]'s left/centre/right and top/centre/bottom lines onto the
/// same lines of [targets], each axis independently, to the closest line
/// within [threshold] world units. A zero-size [moving] snaps a single point,
/// which is how a resize corner uses it.
SnapResult snapRect(
  Rect moving,
  Iterable<Rect> targets, {
  required double threshold,
}) {
  final list = targets.toList(growable: false);
  final dx = _closestShift(
    [moving.left, moving.center.dx, moving.right],
    [
      for (final t in list) ...[t.left, t.center.dx, t.right]
    ],
    threshold,
  );
  final dy = _closestShift(
    [moving.top, moving.center.dy, moving.bottom],
    [
      for (final t in list) ...[t.top, t.center.dy, t.bottom]
    ],
    threshold,
  );
  final snapped = moving.shift(Offset(dx ?? 0, dy ?? 0));
  final guides = <SnapGuide>[
    if (dx != null) ..._guidesFor(snapped, list, vertical: true),
    if (dy != null) ..._guidesFor(snapped, list, vertical: false),
  ];
  return SnapResult(Offset(dx ?? 0, dy ?? 0), guides);
}

double? _closestShift(
  List<double> mine,
  List<double> theirs,
  double threshold,
) {
  double? best;
  for (final a in mine) {
    for (final b in theirs) {
      final shift = b - a;
      if (shift.abs() > threshold) continue;
      if (best == null || shift.abs() < best.abs()) best = shift;
    }
  }
  return best;
}

List<SnapGuide> _guidesFor(
  Rect snapped,
  List<Rect> targets, {
  required bool vertical,
}) {
  return [
    for (final line in _lines(snapped, vertical))
      if (_guideAt(line, snapped, targets, vertical: vertical)
          case final guide?)
        guide,
  ];
}

List<double> _lines(Rect r, bool vertical) =>
    vertical ? [r.left, r.center.dx, r.right] : [r.top, r.center.dy, r.bottom];

(double, double) _span(Rect r, bool vertical) =>
    vertical ? (r.top, r.bottom) : (r.left, r.right);

/// The guide through [line], spanning every target it lines up with, or null.
SnapGuide? _guideAt(
  double line,
  Rect snapped,
  List<Rect> targets, {
  required bool vertical,
}) {
  const epsilon = 1e-6;
  var (start, end) = _span(snapped, vertical);
  var matched = false;
  for (final t in targets) {
    if (!_lines(t, vertical).any((l) => (l - line).abs() < epsilon)) continue;
    final (s, e) = _span(t, vertical);
    start = start < s ? start : s;
    end = end > e ? end : e;
    matched = true;
  }
  if (!matched) return null;
  return SnapGuide(vertical: vertical, position: line, start: start, end: end);
}

/// The world spacing between grid lines at [zoom]: a power of two near 64
/// screen pixels, so the lattice keeps its density at any scale. Snap to grid
/// lands on the same lines the grid draws.
double gridSpacingFor(double zoom) {
  final exponent = (math.log(64 / zoom) / math.ln2).round();
  return math.pow(2, exponent).toDouble();
}

/// The shift that lands [moving]'s top-left on the nearest grid crossing at
/// [spacing] world units. World units, so the snapped position is the same
/// on every screen whatever its size or scale.
Offset gridShift(Rect moving, double spacing) {
  double toLine(double v) => (v / spacing).roundToDouble() * spacing - v;
  return Offset(toLine(moving.left), toLine(moving.top));
}
