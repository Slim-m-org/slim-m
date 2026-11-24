// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which object a pointer landed on.
/// A stroke is nearest-segment-within-tolerance, never its bounding box, so an eraser cannot take a neighbour the line never crossed; images and notes are their whole box and a shape answers only on its outline.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'canvas_document.dart';
import 'spatial_grid.dart';

/// A stroke's bounding box holds only its path extent, not its stroke width,
/// so a thin, straight stroke can have a zero-height box the pointer must
/// still reach through this margin. Generous on purpose: there is no ceiling
/// on pen width small enough to make a tighter pad safe.
const double _cullPad = 64;

/// How far past its box the widest ink on the board still hits, never less than [_cullPad].
double _reach(CanvasDocument document) =>
    math.max(_cullPad, document.maxInkReach);

/// How far from a mark a pointer still hits it, in screen pixels, so the reach
/// is the same at any zoom.
const double defaultHitSlopPx = 4;

/// [defaultHitSlopPx] for a finger.
const double touchHitSlopPx = 12;

/// The topmost live object of any kind [world] lands on, so select, erase and the context menu agree.
/// [touch] widens the reach and [accepts] narrows the kinds. When [allowed] rejects the topmost hit the answer is null, unless [fallThrough] lets the walk carry on to the next one down.
String? hitTestTopmost(
  CanvasDocument document,
  Offset world, {
  bool touch = false,
  bool fallThrough = false,
  CullResult? scratch,
  bool Function(CanvasStroke stroke)? allowed,
  bool Function(CanvasStroke stroke)? accepts,
}) =>
    _topmost(
      document,
      world,
      strokeSlopPx: touch ? touchHitSlopPx : defaultHitSlopPx,
      boxSlopPx: touch ? touchHitSlopPx : 0,
      scratch: scratch,
      allowed: fallThrough ? allowed : null,
      gate: fallThrough ? null : allowed,
      accepts: accepts,
    );

String? _topmost(
  CanvasDocument document,
  Offset world, {
  required double strokeSlopPx,
  required double boxSlopPx,
  required CullResult? scratch,
  required bool Function(CanvasStroke stroke)? allowed,
  required bool Function(CanvasStroke stroke)? gate,
  required bool Function(CanvasStroke stroke)? accepts,
}) {
  if (!document.acceptsPlacementAt(world)) return null;
  final out = scratch ?? CullResult();
  final zoom = document.camera.zoom;
  final pad = _reach(document) + math.max(strokeSlopPx, boxSlopPx) / zoom;
  document.scene.queryRect(
    world.dx - pad,
    world.dy - pad,
    world.dx + pad,
    world.dy + pad,
    out,
  );

  int? best;
  for (final slot in out.slots) {
    final stroke = document.strokeIfAlive(slot);
    if (stroke == null) continue;
    if (best != null && document.comparePaintOrder(slot, best) <= 0) continue;
    if (accepts != null && !accepts(stroke)) continue;
    if (allowed != null && !allowed(stroke)) continue;
    if (_hits(stroke, world, strokeSlopPx / zoom, boxSlopPx / zoom)) {
      best = slot;
    }
  }
  if (best == null) return null;
  final stroke = document.strokeAt(best);
  if (gate != null && !gate(stroke)) return null;
  return stroke.id;
}

bool _hits(CanvasStroke stroke, Offset world, double lineSlop, double boxSlop) {
  switch (stroke.kind) {
    case CanvasObjectKind.stroke:
      final reach = stroke.width / 2 + lineSlop;
      if (world.dx < stroke.x - reach ||
          world.dx > stroke.x + stroke.w + reach ||
          world.dy < stroke.y - reach ||
          world.dy > stroke.y + stroke.h + reach) {
        return false;
      }
      return _withinTolerance(stroke.points, world.dx, world.dy, reach);
    case CanvasObjectKind.shape:
      return _shapeOutlineDistance(stroke, world) <=
          math.max(stroke.width, 1) / 2 + lineSlop;
    case CanvasObjectKind.image:
    case CanvasObjectKind.emoji:
    case CanvasObjectKind.tile:
    case CanvasObjectKind.note:
    case CanvasObjectKind.text:
      return world.dx >= stroke.x - boxSlop &&
          world.dx <= stroke.x + stroke.w + boxSlop &&
          world.dy >= stroke.y - boxSlop &&
          world.dy <= stroke.y + stroke.h + boxSlop;
  }
}

/// How far [world] is from the drawn outline of a shape, in world units.
double _shapeOutlineDistance(CanvasStroke shape, Offset world) {
  final local = world - Offset(shape.x, shape.y);
  final w = shape.w;
  final h = shape.h;
  switch (shape.shapeKind) {
    case CanvasShapeKind.line:
    case CanvasShapeKind.arrow:
      final (tail, head) = shapeSegment(
        w,
        h,
        flipX: shape.flipX,
        flipY: shape.flipY,
      );
      return math.sqrt(
        _distanceSqToSegment(
          local.dx,
          local.dy,
          tail.dx,
          tail.dy,
          head.dx,
          head.dy,
        ),
      );
    case CanvasShapeKind.ellipse:
      return _ellipseDistance(local, w / 2, h / 2);
    case CanvasShapeKind.rectangle:
    case null:
      return _rectBorderDistance(local, w, h);
  }
}

double _rectBorderDistance(Offset p, double w, double h) {
  final overX = math.max(math.max(-p.dx, p.dx - w), 0);
  final overY = math.max(math.max(-p.dy, p.dy - h), 0);
  if (overX > 0 || overY > 0) return math.sqrt(overX * overX + overY * overY);
  return math.min(
    math.min(p.dx, w - p.dx),
    math.min(p.dy, h - p.dy),
  );
}

/// Distance to an ellipse of semi-axes [a] and [b], by bisection on the closest point's root.
double _ellipseDistance(Offset local, double a, double b) {
  if (a <= 0 || b <= 0) {
    return math.sqrt(local.dx * local.dx + local.dy * local.dy);
  }
  final px = (local.dx - a).abs();
  final py = (local.dy - b).abs();
  return a >= b
      ? _quadrantDistance(a, b, px, py)
      : _quadrantDistance(b, a, py, px);
}

/// Distance from (y0, y1) in the first quadrant to the ellipse with semi-axes e0 >= e1 > 0.
double _quadrantDistance(double e0, double e1, double y0, double y1) {
  if (y1 > 0) {
    if (y0 > 0) {
      final z0 = y0 / e0;
      final z1 = y1 / e1;
      final g = z0 * z0 + z1 * z1 - 1;
      if (g == 0) return 0;
      final r0 = (e0 / e1) * (e0 / e1);
      final sbar = _ellipseRoot(r0, z0, z1, g);
      final x0 = r0 * y0 / (sbar + r0);
      final x1 = y1 / (sbar + 1);
      return math.sqrt((x0 - y0) * (x0 - y0) + (x1 - y1) * (x1 - y1));
    }
    return (y1 - e1).abs();
  }
  final numer = e0 * y0;
  final denom = e0 * e0 - e1 * e1;
  if (numer < denom) {
    final xde = numer / denom;
    final x0 = e0 * xde;
    final x1 = e1 * math.sqrt(1 - xde * xde);
    return math.sqrt((x0 - y0) * (x0 - y0) + x1 * x1);
  }
  return (y0 - e0).abs();
}

double _ellipseRoot(double r0, double z0, double z1, double g) {
  final n0 = r0 * z0;
  var s0 = z1 - 1;
  var s1 = g < 0 ? 0.0 : math.sqrt(n0 * n0 + z1 * z1) - 1;
  var s = 0.0;
  for (var i = 0; i < 100; i++) {
    s = (s0 + s1) / 2;
    if (s == s0 || s == s1) break;
    final r = n0 / (s + r0);
    final q = z1 / (s + 1);
    final value = r * r + q * q - 1;
    if (value > 0) {
      s0 = s;
    } else if (value < 0) {
      s1 = s;
    } else {
      break;
    }
  }
  return s;
}

bool _withinTolerance(
  Float32List points,
  double px,
  double py,
  double tolerance,
) {
  final toleranceSq = tolerance * tolerance;
  if (points.length < 4) {
    if (points.length < 2) return false;
    return _distanceSq(px, py, points[0], points[1]) <= toleranceSq;
  }
  for (var i = 0; i + 3 < points.length; i += 2) {
    final d = _distanceSqToSegment(
      px,
      py,
      points[i],
      points[i + 1],
      points[i + 2],
      points[i + 3],
    );
    if (d <= toleranceSq) return true;
  }
  return false;
}

double _distanceSq(double px, double py, double ax, double ay) {
  final dx = px - ax;
  final dy = py - ay;
  return dx * dx + dy * dy;
}

double _distanceSqToSegment(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax;
  final dy = by - ay;
  final lengthSq = dx * dx + dy * dy;
  if (lengthSq == 0) return _distanceSq(px, py, ax, ay);
  final t = (((px - ax) * dx + (py - ay) * dy) / lengthSq).clamp(0.0, 1.0);
  return _distanceSq(px, py, ax + t * dx, ay + t * dy);
}
