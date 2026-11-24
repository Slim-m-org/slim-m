// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where an edge runs: the side each end leaves from, the curve between them and its arrowheads.
///
/// Pure geometry over the boxes the ends are drawn at right now, so a drag, a resize or a remote
/// preview re-routes the edge on the next paint with nothing to invalidate.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'canvas_edge_spec.dart';

/// How far an arrowhead reaches back from its tip, in world units.
const double edgeArrowLength = 14;

/// Half the width of an arrowhead's base.
const double edgeArrowHalfWidth = 6;

/// The curve between two anchors, ready to paint and to hit test.
class EdgeRoute {
  EdgeRoute({
    required this.start,
    required this.control1,
    required this.control2,
    required this.end,
    required this.startSide,
    required this.endSide,
  });

  final Offset start;
  final Offset control1;
  final Offset control2;
  final Offset end;

  /// The sides the ends left from, or null for a free end.
  final EdgeSide? startSide;
  final EdgeSide? endSide;

  Offset pointAt(double t) {
    final u = 1 - t;
    return start * (u * u * u) +
        control1 * (3 * u * u * t) +
        control2 * (3 * u * t * t) +
        end * (t * t * t);
  }

  /// Where a label sits.
  Offset get midpoint => pointAt(0.5);

  Path get path => Path()
    ..moveTo(start.dx, start.dy)
    ..cubicTo(
        control1.dx, control1.dy, control2.dx, control2.dy, end.dx, end.dy);

  /// The curve as straight pieces, for hit testing and bounds.
  List<Offset> flatten({int segments = 24}) =>
      [for (var i = 0; i <= segments; i++) pointAt(i / segments)];

  /// The head at the tip of [tip] pointing along [heading]: three corners.
  static List<Offset> arrowhead(Offset tip, Offset heading) {
    final length = heading.distance;
    final dir = length == 0 ? const Offset(1, 0) : heading / length;
    final back = tip - dir * edgeArrowLength;
    final normal = Offset(-dir.dy, dir.dx) * edgeArrowHalfWidth;
    return [tip, back + normal, back - normal];
  }

  /// The head at the end, or null when [arrow] draws none there.
  List<Offset>? endHead(EdgeArrow arrow) => arrow == EdgeArrow.none
      ? null
      : arrowhead(end, end - _towards(control2, end, control1));

  /// The head at the start, or null.
  List<Offset>? startHead(EdgeArrow arrow) => arrow == EdgeArrow.both
      ? arrowhead(start, start - _towards(control1, start, control2))
      : null;

  static Offset _towards(Offset control, Offset tip, Offset fallback) =>
      (control - tip).distance > 1e-6 ? control : fallback;
}

Offset _sideNormal(EdgeSide side) => switch (side) {
      EdgeSide.top => const Offset(0, -1),
      EdgeSide.bottom => const Offset(0, 1),
      EdgeSide.left => const Offset(-1, 0),
      EdgeSide.right => const Offset(1, 0),
      EdgeSide.auto => Offset.zero,
    };

/// The middle of [side] of [box].
Offset sideAnchor(Rect box, EdgeSide side) => switch (side) {
      EdgeSide.top => box.topCenter,
      EdgeSide.bottom => box.bottomCenter,
      EdgeSide.left => box.centerLeft,
      EdgeSide.right => box.centerRight,
      EdgeSide.auto => box.center,
    };

/// The side of [box] that faces [toward], by whichever axis the two are further apart on.
EdgeSide facingSide(Rect box, Offset toward) {
  final delta = toward - box.center;
  if (delta.dx.abs() >= delta.dy.abs()) {
    return delta.dx >= 0 ? EdgeSide.right : EdgeSide.left;
  }
  return delta.dy >= 0 ? EdgeSide.bottom : EdgeSide.top;
}

/// Where an end sits given the box of the object it is attached to, or the point it is left at.
({Offset point, EdgeSide? side, Offset normal}) _resolveEnd(
  EdgeEndSpec spec,
  Rect? box,
  Offset toward,
) {
  switch (spec) {
    case FreeEnd(:final point):
      return (point: point, side: null, normal: Offset.zero);
    case AttachedEnd(:final side):
      final rect = box!;
      final resolved = side == EdgeSide.auto ? facingSide(rect, toward) : side;
      return (
        point: sideAnchor(rect, resolved),
        side: resolved,
        normal: _sideNormal(resolved),
      );
  }
}

/// The route of [spec] over the boxes its ends are drawn at, or null while an attached end has no box yet.
EdgeRoute? routeEdge(CanvasEdgeSpec spec, Rect? fromBox, Rect? toBox) {
  if ((spec.from is AttachedEnd && fromBox == null) ||
      (spec.to is AttachedEnd && toBox == null)) {
    return null;
  }
  final fromCentre = switch (spec.from) {
    FreeEnd(:final point) => point,
    AttachedEnd() => fromBox!.center,
  };
  final toCentre = switch (spec.to) {
    FreeEnd(:final point) => point,
    AttachedEnd() => toBox!.center,
  };
  final a = _resolveEnd(spec.from, fromBox, toCentre);
  final b = _resolveEnd(spec.to, toBox, fromCentre);
  final reach = (b.point - a.point).distance;
  final pull = (reach / 2).clamp(40.0, 200.0);
  Offset normalOf(
      ({Offset point, EdgeSide? side, Offset normal}) end, Offset other) {
    if (end.side != null) return end.normal;
    final away = other - end.point;
    return away.distance == 0 ? Offset.zero : away / away.distance;
  }

  final na = normalOf(a, b.point);
  final nb = normalOf(b, a.point);
  final straight = reach < 1e-6;
  return EdgeRoute(
    start: a.point,
    control1: straight ? a.point : a.point + na * math.min(pull, reach * 2),
    control2: straight ? b.point : b.point + nb * math.min(pull, reach * 2),
    end: b.point,
    startSide: a.side,
    endSide: b.side,
  );
}

/// The box an edge occupies for a region read: its two ends and the curve between.
Rect edgeBounds(EdgeRoute route) {
  var bounds = Rect.fromPoints(route.start, route.end);
  for (final p in route.flatten(segments: 12)) {
    bounds = bounds.expandToInclude(Rect.fromLTWH(p.dx, p.dy, 0, 0));
  }
  return bounds;
}

/// The distance from [world] to the curve of [route], in world units.
double distanceToEdge(EdgeRoute route, Offset world) {
  final points = route.flatten();
  var best = double.infinity;
  for (var i = 0; i + 1 < points.length; i++) {
    final a = points[i];
    final b = points[i + 1];
    final ab = b - a;
    final lengthSq = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = lengthSq == 0
        ? 0.0
        : (((world - a).dx * ab.dx + (world - a).dy * ab.dy) / lengthSq)
            .clamp(0.0, 1.0);
    final d = (world - (a + ab * t)).distance;
    if (d < best) best = d;
  }
  return best;
}
