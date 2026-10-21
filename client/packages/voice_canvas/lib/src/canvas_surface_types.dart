// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_surface.dart';

/// A pen stroke the surface has finished and wants committed.
typedef StrokeCommitted = void Function(List<Offset> worldPoints);

/// A shape tool's placement: the box's own centre in world coordinates,
/// and, when the pointer actually dragged rather than merely tapped, the
/// world-space size that drag sized it to - null for a plain tap, which
/// keeps the caller's own default size.
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

/// A point was added to the pen stroke currently under this device's own
/// pointer, in world coordinates. Fires on the same down/move events
/// [StrokeCommitted] itself is eventually built from, but as they happen
/// rather than once at the end - the caller decides whether, and how often,
/// to relay it onward as an ephemeral preview.
typedef DraftPointAdded = void Function(Offset worldPoint);

/// Which gesture a single pointer draws.
///
/// Decision 0004 named the tool dock as exactly three placement tools - pen,
/// note, shape - each dropping a new object where a pointer taps. `eraser`
/// and `pan` are not placement modes: they act on objects already there
/// (erase, move, resize), added once this canvas grew objects worth acting
/// on, and are additional to the three named tools rather than a fourth and
/// fifth placement choice.
enum CanvasTool {
  pan,
  pen,
  note,
  shape,
  eraser;

  /// Whether a press starts a new mark, as opposed to selecting or erasing.
  bool get placesInk => this == pen || this == note || this == shape;
}
