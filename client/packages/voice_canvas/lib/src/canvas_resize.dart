// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pure geometry behind dragging an image's resize handle: which corner
/// anchors, how the box grows, and the two ceilings a drag must respect - a
/// floor so an object can never shrink to nothing, and a copy of the
/// server's own `MAX_OBJECT_EXTENT` so it can never grow past what a resize
/// commit would be refused for.
///
/// Kept free of [CanvasDocument] on purpose: this is arithmetic over a box
/// and a pointer position, testable without a document, a scene, or a
/// camera at all.
library;

import 'package:flutter/painting.dart';

import 'canvas_stroke.dart' show maxObjectExtent;

/// The four corners a resize handle may anchor to. Dragging one moves it;
/// the opposite corner stays fixed for the whole gesture.
enum ResizeCorner { topLeft, topRight, bottomLeft, bottomRight }

/// The smallest world-space side a resize may leave an object at. Zero would
/// let a drag collapse an image to a sliver nothing could grab again.
const double minObjectSize = 8.0;

/// [maxObjectExtent] (`canvas_stroke.dart`, mirroring the server's own
/// `MAX_OBJECT_EXTENT`) is the longest side one object may claim. A resize
/// drag hits it as a hard wall - the box stops growing exactly here,
/// visibly, the instant the pointer crosses it - rather than growing past
/// it locally and only failing once asked to commit, which would show one
/// thing on screen and send another.
///
/// The on-screen radius, in logical pixels, a pointer must land within a
/// corner to grab its handle. A screen quantity rather than a world one, so
/// the same target is offered at any zoom level: converted to world units
/// by dividing by the camera's zoom at the call site, it does not balloon
/// to cover the object zoomed in, and does not shrink past what a finger or
/// cursor can land on zoomed out.
const double resizeHandleHitRadius = 14.0;

/// [resizeHandleHitRadius]'s touch counterpart: a 28px-diameter hit circle
/// is well under this product's own 44-48dp touch-target floor
/// (`docs/design/design-language.md`), disproportionately hard to land on a
/// specific corner at low zoom where the visual square shrinks toward the
/// hit radius's own size. 22 gives a 44px target, matching the floor
/// exactly; precision is cheap on a mouse or trackpad, so that input class
/// keeps the tighter default.
const double touchResizeHandleHitRadius = 22.0;

/// The square handle's drawn side length, in logical pixels, painted at a
/// fixed screen size regardless of zoom - the same reason
/// [resizeHandleHitRadius] is a screen quantity.
const double resizeHandleVisualSize = 9.0;

/// The drawn handle on touch: big enough to see under a finger, still a
/// screen quantity.
const double touchResizeHandleVisualSize = 18.0;

Offset _cornerOf(
    ({double x, double y, double w, double h}) bounds, ResizeCorner corner) {
  switch (corner) {
    case ResizeCorner.topLeft:
      return Offset(bounds.x, bounds.y);
    case ResizeCorner.topRight:
      return Offset(bounds.x + bounds.w, bounds.y);
    case ResizeCorner.bottomLeft:
      return Offset(bounds.x, bounds.y + bounds.h);
    case ResizeCorner.bottomRight:
      return Offset(bounds.x + bounds.w, bounds.y + bounds.h);
  }
}

ResizeCorner _oppositeOf(ResizeCorner corner) {
  switch (corner) {
    case ResizeCorner.topLeft:
      return ResizeCorner.bottomRight;
    case ResizeCorner.topRight:
      return ResizeCorner.bottomLeft;
    case ResizeCorner.bottomLeft:
      return ResizeCorner.topRight;
    case ResizeCorner.bottomRight:
      return ResizeCorner.topLeft;
  }
}

/// The screen position of each of [bounds]'s four corners, camera-projected
/// by the caller. A thin wrapper over [_cornerOf] so the painter and the
/// hit test share one notion of where a corner sits.
Map<ResizeCorner, Offset> resizeHandleCorners(
  ({double x, double y, double w, double h}) bounds,
) =>
    {
      for (final corner in ResizeCorner.values)
        corner: _cornerOf(bounds, corner)
    };

/// Which corner of [bounds], if any, [world] lands within [hitRadius]
/// screen pixels of, given the camera's current [zoom]. [hitRadius]
/// defaults to [resizeHandleHitRadius]; a caller on a touch surface should
/// pass [touchResizeHandleHitRadius] instead.
ResizeCorner? hitTestResizeHandle(
  ({double x, double y, double w, double h}) bounds,
  Offset world,
  double zoom, {
  double hitRadius = resizeHandleHitRadius,
}) {
  final worldRadius = hitRadius / zoom;
  for (final corner in ResizeCorner.values) {
    if ((world - _cornerOf(bounds, corner)).distance <= worldRadius) {
      return corner;
    }
  }
  return null;
}

/// The new bounds a resize drag produces: [corner] follows [pointerWorld],
/// the opposite corner stays put, and the result is clamped to
/// [minObjectSize]..[maxObjectExtent] on each side.
///
/// [lockAspect] true - the default gesture, no modifier held - scales both
/// sides together from [original]'s own ratio, driven by whichever axis the
/// pointer moved further along (the larger of the two free-form scale
/// factors), so the box grows to match the more extreme drag rather than
/// lagging behind it on one axis.
({double x, double y, double w, double h}) resizeBounds({
  required ResizeCorner corner,
  required ({double x, double y, double w, double h}) original,
  required Offset pointerWorld,
  required bool lockAspect,
}) {
  final anchor = _cornerOf(original, _oppositeOf(corner));

  var w = _clamped((pointerWorld.dx - anchor.dx).abs());
  var h = _clamped((pointerWorld.dy - anchor.dy).abs());

  if (lockAspect && original.w > 0 && original.h > 0) {
    final scale = _lockedScale(w / original.w, h / original.h, original);
    w = original.w * scale;
    h = original.h * scale;
  }

  final left = pointerWorld.dx <= anchor.dx;
  final top = pointerWorld.dy <= anchor.dy;
  return (
    x: left ? anchor.dx - w : anchor.dx,
    y: top ? anchor.dy - h : anchor.dy,
    w: w,
    h: h,
  );
}

double _clamped(double value) {
  if (value < minObjectSize) return minObjectSize;
  if (value > maxObjectExtent) return maxObjectExtent;
  return value;
}

/// The uniform scale [resizeBounds] applies when locking aspect ratio: the
/// larger of the two free-form factors, reclamped so neither side ends up
/// outside [minObjectSize]..[maxObjectExtent] - aspect scaling can push a
/// side back past a ceiling the free calculation already respected on its
/// own axis alone.
double _lockedScale(
  double freeScaleW,
  double freeScaleH,
  ({double x, double y, double w, double h}) original,
) {
  final free = freeScaleW > freeScaleH ? freeScaleW : freeScaleH;
  final maxScale =
      _lesser(maxObjectExtent / original.w, maxObjectExtent / original.h);
  final minScale =
      _greater(minObjectSize / original.w, minObjectSize / original.h);
  if (free < minScale) return minScale;
  if (free > maxScale) return maxScale;
  return free;
}

double _lesser(double a, double b) => a < b ? a : b;
double _greater(double a, double b) => a > b ? a : b;
