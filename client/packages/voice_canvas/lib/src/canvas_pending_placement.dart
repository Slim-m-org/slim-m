// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note, text, shape or stamp placement: armed when its pointer goes down
/// and fired only once every pointer has lifted. Panning and zooming are
/// two-pointer-only, so a pinch always starts as one finger down alone, and
/// this is what lets that first finger still cancel the placement.
library;

import 'dart:ui';

import 'canvas_document.dart';
import 'canvas_painters.dart' show DraftShape;
import 'canvas_resize.dart' show minObjectSize;
import 'canvas_surface.dart';

/// How far, in screen pixels, a press may travel and still be a tap.
const double surfaceTapSlop = 6.0;

/// Below this screen-space distance on both axes, a shape placement reads
/// as a tap rather than a drag - see [CanvasPendingPlacement._shapeDragAt].
const double _shapeDragThreshold = 4.0;

/// The narrowest note drag, in screen pixels, that sizes the note: well past a finger's
/// jitter, and wide enough that the text a note's width sets still paints.
const double _noteDragMinWidth = 48.0;

class CanvasPendingPlacement {
  CanvasPendingPlacement({
    required this.surface,
    required this.toWorld,
    required this.pointers,
  });

  /// The widget whose callbacks a placement fires, read as it is now.
  final CanvasSurface Function() surface;
  final Offset Function(Offset screen) toWorld;

  /// Every pointer down on the surface, a presence tile's included.
  final int Function() pointers;

  /// The box a note or shape drag has sized so far, for its live preview.
  final shapeDraft = DraftShape();

  CanvasTool? _tool;
  Offset? _world;

  /// Where a stamp drag has reached, in world coordinates.
  Offset? _stampReach;

  /// Arms [tool]'s placement at [world], where the pointer went down at [screen].
  void arm(CanvasTool tool, Offset world, Offset screen) {
    _tool = tool;
    _world = world;
    switch (tool) {
      case CanvasTool.note:
        shapeDraft.begin(screen, CanvasShapeKind.rectangle);
      case CanvasTool.shape:
        shapeDraft.begin(screen, surface().shapeKind);
      case CanvasTool.stamp:
        _stampReach = null;
      case CanvasTool.text:
      case CanvasTool.pen:
      case CanvasTool.eraser:
      case CanvasTool.pan:
        break;
    }
  }

  void dragShape(Offset screen) => shapeDraft.update(screen);

  /// A stamp drag past a tap's slop sizes the stamp around where it went down.
  void dragStamp(Offset world) {
    final centre = _world;
    if (centre == null) return;
    final zoom = surface().document.camera.zoom;
    final moved = (world - centre).distance * zoom;
    if (_stampReach == null && moved <= surfaceTapSlop) return;
    _stampReach = world;
    surface().onStampDrag?.call(centre, (world - centre).distance * 2);
  }

  void drop() {
    if (_stampReach != null) surface().onStampDrag?.call(Offset.zero, null);
    _tool = null;
    _world = null;
    _stampReach = null;
    shapeDraft.cancel();
  }

  /// Fires the armed placement at the point it was armed with; a pointer a
  /// presence tile absorbed still holds it back, and drops it.
  void resolve() {
    final tool = _tool;
    final world = _world;
    if (tool == null || world == null) return;
    if (pointers() != 0) {
      drop();
      return;
    }
    _tool = null;
    _world = null;
    final widget = surface();
    switch (tool) {
      case CanvasTool.note:
        final (center, size) = _shapeDragAt(
          world,
          minWidth: _noteDragMinWidth,
        );
        widget.onNotePlace?.call(center, size);
      case CanvasTool.text:
        widget.onTextPlace?.call(world);
      case CanvasTool.shape:
        final (center, size) = _shapeDragAt(world);
        // Read after take(): the draft keeps its direction until the next drag begins.
        final flip = shapeDraft.flip;
        widget.onShapePlace?.call(
          center,
          size,
          flipX: size != null && flip.x,
          flipY: size != null && flip.y,
        );
      case CanvasTool.stamp:
        final reach = _stampReach;
        _stampReach = null;
        if (reach != null) widget.onStampDrag?.call(world, null);
        widget.onStampPlace?.call(
          world,
          reach == null ? null : (reach - world).distance * 2,
        );
      case CanvasTool.pen:
      case CanvasTool.eraser:
      case CanvasTool.pan:
        break;
    }
  }

  /// [world] unchanged and a null size for a plain tap; otherwise the dragged box's centre and size, clipped to the board and clamped to [minObjectSize]..[maxObjectExtent] like a resize handle, so a placement drag can never commit a box a resize could not.
  /// A drag narrower than [minWidth] also counts as a tap.
  (Offset, Size?) _shapeDragAt(Offset world, {double minWidth = 0}) {
    final screen = shapeDraft.take();
    if (screen == null ||
        screen.width < minWidth ||
        (screen.width < _shapeDragThreshold &&
            screen.height < _shapeDragThreshold)) {
      return (world, null);
    }
    var bounds = Rect.fromPoints(
      toWorld(screen.topLeft),
      toWorld(screen.bottomRight),
    );
    final board = surface().document.board;
    if (board != null && bounds.overlaps(board)) {
      bounds = bounds.intersect(board);
    }
    final width = bounds.width.clamp(minObjectSize, maxObjectExtent);
    final height = bounds.height.clamp(minObjectSize, maxObjectExtent);
    return (bounds.center, Size(width, height));
  }

  void dispose() => shapeDraft.dispose();
}
