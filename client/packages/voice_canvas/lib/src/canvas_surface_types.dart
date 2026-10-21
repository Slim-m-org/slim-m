// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_surface.dart';

/// A pen stroke the surface has finished and wants committed.
typedef StrokeCommitted = void Function(List<Offset> worldPoints);

/// A shape tool's placement: the box centre in world coordinates and, for a drag rather than a tap, its world-space size (null for a tap, which keeps the default).
/// [flipX] and [flipY] say which way a dragged line or arrow ran.
typedef ShapePlaced = void Function(
  Offset worldCenter,
  Size? draggedSize, {
  bool flipX,
  bool flipY,
});

/// This pointer moved to a world position, on every hover and drag alike.
/// The caller decides whether and how often to relay it.
typedef PointerMoved = void Function(Offset worldPoint);

/// A point added to the pen stroke under this device's pointer, in world coordinates, fired as it happens so the caller can relay it as an ephemeral preview.
typedef DraftPointAdded = void Function(Offset worldPoint);

/// Which gesture a single pointer draws.
/// Decision 0004 named pen, note and shape as the placement tools; `eraser` and `pan` act on objects already there (erase, move, resize).
enum CanvasTool {
  pan,
  pen,
  note,
  shape,
  eraser;

  /// Whether a press starts a new mark, as opposed to selecting or erasing.
  bool get placesInk => this == pen || this == note || this == shape;
}
