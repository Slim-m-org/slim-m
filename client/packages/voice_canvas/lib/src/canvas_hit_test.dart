// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which stroke, or box object, a pointer landed on.
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

/// Finds the topmost live stroke within tolerance of [world] that [allowed]
/// accepts, or null.
///
/// Candidates come from a small cull around the pointer, never a full scan.
/// They are tested highest z-index first, so an eraser takes the same
/// stroke a viewer sees on top, and the first one within its own
/// `width / 2 + slop` wins. A candidate [allowed] refuses is skipped rather
/// than stopping the search, so a foreign stroke on top of the caller's own
/// ink does not shield it: the eraser is meant to scope what it can pick up
/// at hit-test time, not merely at the request the server would refuse.
String? hitTestStroke(
  CanvasDocument document,
  Offset world, {
  double slopPx = defaultHitSlopPx,
  CullResult? scratch,
  bool Function(CanvasStroke stroke)? allowed,
}) {
  // The board's clip hides everything past its edge, so nothing there can be hit.
  if (!document.acceptsPlacementAt(world)) return null;
  final out = scratch ?? CullResult();
  final pad = _reach(document) + slopPx / document.camera.zoom;
  document.scene.queryRect(
    world.dx - pad,
    world.dy - pad,
    world.dx + pad,
    world.dy + pad,
    out,
  );

  final candidates = <int>[];
  for (final slot in out.slots) {
    if (document.strokeIfAlive(slot) != null) candidates.add(slot);
  }
  candidates.sort((a, b) => document.comparePaintOrder(b, a));

  for (final slot in candidates) {
    final stroke = document.strokeAt(slot);
    if (allowed != null && !allowed(stroke)) continue;
    final tolerance = stroke.width / 2 + slopPx / document.camera.zoom;
    if (_withinTolerance(stroke.points, world.dx, world.dy, tolerance)) {
      return stroke.id;
    }
  }
  return null;
}

/// Finds the topmost live image, note or shape [world] lands on that [allowed] accepts, or null; a shape is only its outline so presses through its empty inside reach what lies beneath.
String? hitTestBoxAt(
  CanvasDocument document,
  Offset world, {
  double slopPx = 0,
  CullResult? scratch,
  bool Function(CanvasStroke stroke)? allowed,
}) =>
    _topmost(
      document,
      world,
      strokeSlopPx: slopPx,
      boxSlopPx: slopPx,
      scratch: scratch,
      allowed: allowed,
      accepts: (stroke) => stroke.kind != CanvasObjectKind.stroke,
    );

/// The topmost live object of any kind [world] lands on that [allowed] accepts, so select, erase and the context menu agree; [touch] widens the reach and [accepts] narrows the kinds.
String? hitTestTopmost(
  CanvasDocument document,
  Offset world, {
  bool touch = false,
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
      allowed: allowed,
      accepts: accepts,
    );

String? _topmost(
  CanvasDocument document,
  Offset world, {
  required double strokeSlopPx,
  required double boxSlopPx,
  required CullResult? scratch,
  required bool Function(CanvasStroke stroke)? allowed,
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

  final candidates = <int>[];
  for (final slot in out.slots) {
    if (document.strokeIfAlive(slot) != null) candidates.add(slot);
  }
  candidates.sort((a, b) => document.comparePaintOrder(b, a));

  for (final slot in candidates) {
    final stroke = document.strokeAt(slot);
    if (accepts != null && !accepts(stroke)) continue;
    if (allowed != null && !allowed(stroke)) continue;
    if (_hits(stroke, world, strokeSlopPx / zoom, boxSlopPx / zoom)) {
      return stroke.id;
    }
  }
  return null;
}

bool _hits(CanvasStroke stroke, Offset world, double lineSlop, double boxSlop) {
  switch (stroke.kind) {
    case CanvasObjectKind.stroke:
      return _withinTolerance(
        stroke.points,
        world.dx,
        world.dy,
        stroke.width / 2 + lineSlop,
      );
    case CanvasObjectKind.shape:
      return _shapeOutlineDistance(stroke, world) <=
          math.max(stroke.width, 1) / 2 + lineSlop;
    case CanvasObjectKind.image:
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

/// First-order distance to an ellipse of semi-axes [a] and [b]; exact enough
/// for a few pixels of reach.
double _ellipseDistance(Offset local, double a, double b) {
  if (a <= 0 || b <= 0) {
    return math.sqrt(local.dx * local.dx + local.dy * local.dy);
  }
  final x = local.dx - a;
  final y = local.dy - b;
  final g = (x * x) / (a * a) + (y * y) / (b * b) - 1;
  final gx = 2 * x / (a * a);
  final gy = 2 * y / (b * b);
  final slope = math.sqrt(gx * gx + gy * gy);
  if (slope == 0) return math.min(a, b);
  return g.abs() / slope;
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
