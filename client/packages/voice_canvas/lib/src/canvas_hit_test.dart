// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which stroke, or which box object, a pointer landed on.
///
/// A stroke is nearest-segment-within-tolerance against its own points,
/// never its bounding box: a long diagonal stroke's box covers area its ink
/// never touches, so testing the box would let an eraser take out a
/// neighbour the drawn line never crossed. An image, a note and a shape all
/// have nothing thinner inside their own box to miss - a note's text and a
/// shape's outline both live inside the box they were placed with, never
/// outside it - so [hitTestBoxAt] tests the box directly for all three.
library;

import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'canvas_document.dart';
import 'spatial_grid.dart';

/// A stroke's bounding box holds only its path extent, not its stroke width,
/// so a thin, straight stroke can have a zero-height box the pointer must
/// still reach through this margin. Generous on purpose: there is no ceiling
/// on pen width small enough to make a tighter pad safe.
const double _cullPad = 64;

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
  final out = scratch ?? CullResult();
  final pad = _cullPad + slopPx / document.camera.zoom;
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

/// Finds the topmost live image, note or shape object whose box contains
/// [world] and that [allowed] accepts, or null.
///
/// Unlike [hitTestStroke], the box itself is the hit target: none of the
/// three kinds has a thinner shape inside it to miss, so there is no
/// tolerance to add and no reason to cull wider than the point itself.
String? hitTestBoxAt(
  CanvasDocument document,
  Offset world, {
  double slopPx = 0,
  CullResult? scratch,
  bool Function(CanvasStroke stroke)? allowed,
}) {
  final out = scratch ?? CullResult();
  final slop = slopPx / document.camera.zoom;
  document.scene.queryRect(
    world.dx - slop,
    world.dy - slop,
    world.dx + slop,
    world.dy + slop,
    out,
  );

  final candidates = <int>[];
  for (final slot in out.slots) {
    final stroke = document.strokeIfAlive(slot);
    if (stroke != null && stroke.kind != CanvasObjectKind.stroke) {
      candidates.add(slot);
    }
  }
  candidates.sort((a, b) => document.comparePaintOrder(b, a));

  for (final slot in candidates) {
    final stroke = document.strokeAt(slot);
    if (allowed != null && !allowed(stroke)) continue;
    if (world.dx >= stroke.x - slop &&
        world.dx <= stroke.x + stroke.w + slop &&
        world.dy >= stroke.y - slop &&
        world.dy <= stroke.y + stroke.h + slop) {
      return stroke.id;
    }
  }
  return null;
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
