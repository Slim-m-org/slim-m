// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_ops_controller.dart';

/// One `move` change in progress via the select tool, and the undo that
/// reverses it - the drag/resize half's own entry, alongside `_DrawEntry`
/// and `_EraseEntry` in the main file and `_ReorderEntry` in the reorder
/// part.
class _MoveEntry extends _UndoEntry {
  _MoveEntry(this.objectId, this.fromX, this.fromY, this.fromW, this.fromH);

  final String objectId;
  final double fromX;
  final double fromY;
  final double fromW;
  final double fromH;
}

/// The box an undone move left, which a redo moves the object back to.
class _RedoMove extends _RedoEntry {
  _RedoMove(this.objectId, this.toX, this.toY, this.toW, this.toH);

  final String objectId;
  final double toX;
  final double toY;
  final double toW;
  final double toH;
}

/// One select-drag in progress: the object picked up, its bounds when the
/// drag began (for [CanvasOpsController.undo] to restore), and the bounds it
/// currently occupies (updated on every [CanvasOpsController.dragSelect]).
class _DragState {
  _DragState(
    this.objectId,
    this.fromX,
    this.fromY,
    this.fromW,
    this.fromH,
    this.anchor,
  ) : x = fromX,
      y = fromY,
      w = fromW,
      h = fromH;

  final String objectId;
  final double fromX;
  final double fromY;
  final double fromW;
  final double fromH;

  /// The world point the drag started at, so every later point becomes a
  /// delta from the object's own original position rather than its own.
  final Offset anchor;

  double x;
  double y;

  /// The size the board allows, which differs from the original for an object larger than it.
  double w;
  double h;
}

/// One resize-handle drag in progress: which object and corner, its bounds
/// when the drag began (for [CanvasOpsController.undo] to restore, and as
/// the anchor [resizeBounds] measures every later point against), and the
/// bounds it currently previews.
class _ResizeState {
  _ResizeState(this.objectId, this.corner, this.fromBounds, this.grab)
    : current = fromBounds;

  final String objectId;
  final ResizeCorner corner;

  /// From the press to the handle's centre, so the corner does not jump to the pointer.
  final Offset grab;
  final ({double x, double y, double w, double h}) fromBounds;
  ({double x, double y, double w, double h}) current;
}

/// The Move tool: picking an object up, dragging or resizing it, and
/// committing or undoing the result. Its own extension, the shape
/// `CanvasOpsControllerReorder` already established, since these methods
/// need `CanvasOpsController`'s own private `_drag`/`_resize` fields and
/// undo stack.
extension CanvasOpsControllerSelect on CanvasOpsController {
  /// Grabs a resize handle on the selection if [world] lands on one, else picks up the topmost live object
  /// the caller may move, remembering its bounds for [dragSelect] and [undo]; deselects if nothing is there.
  /// A stroke is selectable for reorder but never dragged, and only box kinds have a resize handle.
  void beginSelect(
    Offset world, {
    required bool manageCanvas,
    required String? selfId,
    bool touch = false,
  }) {
    if (_beginResize(world, manageCanvas, selfId, touch)) return;
    // Hidden by the board's clip, so a press on the letterbox selects nothing.
    if (!document.acceptsPlacementAt(world)) {
      document.selectedObjectId.value = null;
      return;
    }
    bool allowed(CanvasStroke stroke) =>
        !isLocked(stroke.id) &&
        (manageCanvas ||
            (stroke.authorId != null && stroke.authorId == selfId));
    final id = hitTestTopmost(document, world, touch: touch, allowed: allowed);
    document.selectedObjectId.value = id;
    if (id == null || document.kindOf(id) == CanvasObjectKind.stroke) return;
    final bounds = document.objectBounds(id);
    if (bounds == null) return;
    _drag = _DragState(id, bounds.x, bounds.y, bounds.w, bounds.h, world);
    document.elevatedObjectId.value = id;
  }

  bool _beginResize(
    Offset world,
    bool manageCanvas,
    String? selfId,
    bool touch,
  ) {
    final selected = document.selectedObjectId.value;
    if (selected == null ||
        document.kindOf(selected) == CanvasObjectKind.stroke) {
      return false;
    }
    final owns =
        !isLocked(selected) &&
        (manageCanvas || document.authorIdOf(selected) == selfId);
    final bounds = document.objectBounds(selected);
    if (!owns || bounds == null || _isDeepInterior(bounds, world)) return false;
    final corner = hitTestResizeHandle(
      bounds,
      world,
      document.camera.zoom,
      hitRadius: touch ? touchResizeHandleHitRadius : resizeHandleHitRadius,
    );
    if (corner == null) return false;
    final grab = resizeHandleCorners(bounds)[corner]! - world;
    _resize = _ResizeState(selected, corner, bounds, grab);
    document.elevatedObjectId.value = selected;
    return true;
  }

  /// Whether [world] lands in the innermost half of [bounds], where a plain move-drag always wins.
  /// Without it a small selected object sits wholly inside the zoom-scaled resize radius and every click, even dead centre, resolves to a resize.
  bool _isDeepInterior(
    ({double x, double y, double w, double h}) bounds,
    Offset world,
  ) {
    final marginX = bounds.w / 4;
    final marginY = bounds.h / 4;
    return world.dx >= bounds.x + marginX &&
        world.dx <= bounds.x + bounds.w - marginX &&
        world.dy >= bounds.y + marginY &&
        world.dy <= bounds.y + bounds.h - marginY;
  }

  /// Continues whichever gesture [beginSelect] started: reshapes the
  /// selection's box toward [world] if a handle was grabbed ([lockAspect]
  /// true unless a modifier is held), or moves it by the same drag delta
  /// otherwise. Does nothing if neither is under way.
  ///
  /// With [snap], the moved box (or the dragged corner) pulls onto other
  /// visible boxes' edges and centres; the pointer-to-box anchor is untouched,
  /// so releasing [snap] mid-drag releases the box immediately.
  void dragSelect(Offset world, {required bool lockAspect, bool snap = false}) {
    final resize = _resize;
    if (resize != null) {
      final point = snap
          ? _snapped(resize.objectId, Rect.fromLTWH(world.dx, world.dy, 0, 0))
          : _unsnapped();
      final raw = resizeBounds(
        corner: resize.corner,
        original: resize.fromBounds,
        pointerWorld: document.clampToBoard(world + resize.grab + point),
        lockAspect: lockAspect,
        within: document.board,
      );
      resize.current = document.boxOnBoard(
        resize.objectId,
        raw.x,
        raw.y,
        raw.w,
        raw.h,
      );
      document.moveObject(
        resize.objectId,
        resize.current.x,
        resize.current.y,
        resize.current.w,
        resize.current.h,
      );
      document.refresh();
      return;
    }
    final drag = _drag;
    if (drag == null) return;
    final x = drag.fromX + (world.dx - drag.anchor.dx);
    final y = drag.fromY + (world.dy - drag.anchor.dy);
    final shift = snap
        ? _snapped(drag.objectId, Rect.fromLTWH(x, y, drag.fromW, drag.fromH))
        : _unsnapped();
    final box = document.boxOnBoard(
      drag.objectId,
      x + shift.dx,
      y + shift.dy,
      drag.fromW,
      drag.fromH,
    );
    drag.x = box.x;
    drag.y = box.y;
    drag.w = box.w;
    drag.h = box.h;
    document.moveObject(drag.objectId, drag.x, drag.y, drag.w, drag.h);
    document.refresh();
  }

  /// The object this device is dragging or resizing and the box it now
  /// shows, or null between gestures.
  ({String id, ObjectBox box})? get activeMove {
    final resize = _resize;
    if (resize != null) return (id: resize.objectId, box: resize.current);
    final drag = _drag;
    if (drag == null) return null;
    return (
      id: drag.objectId,
      box: (x: drag.x, y: drag.y, w: drag.w, h: drag.h),
    );
  }

  Offset _unsnapped() {
    document.snapGuides.value = const [];
    return Offset.zero;
  }

  /// The shift that aligns [moving] with the other visible boxes, publishing
  /// the guides it earned. Strokes are skipped: their bounds are not edges a
  /// person lines anything up with.
  Offset _snapped(String movingId, Rect moving) {
    final targets = [
      for (final id in document.visibleIds)
        if (id != movingId && document.kindOf(id) != CanvasObjectKind.stroke)
          if (document.objectBounds(id) case final b?)
            Rect.fromLTWH(b.x, b.y, b.w, b.h),
    ];
    final result = snapRect(
      moving,
      targets,
      threshold: snapScreenThreshold / document.camera.zoom,
    );
    document.snapGuides.value = result.guides;
    if (!document.snapToGrid.value) return result.offset;
    // Lining up with a neighbour wins on its axis; the grid takes the rest.
    final grid = gridShift(
      moving.shift(result.offset),
      gridSpacingFor(document.camera.zoom),
    );
    final alignedX = result.guides.any((g) => g.vertical);
    final alignedY = result.guides.any((g) => !g.vertical);
    return Offset(
      result.offset.dx + (alignedX ? 0 : grid.dx),
      result.offset.dy + (alignedY ? 0 : grid.dy),
    );
  }

  /// Commits whichever gesture [beginSelect] started as one `move` op, or
  /// does nothing if nothing was under way or the box never actually
  /// changed - picking an object up and putting it back down costs no
  /// request and pushes no undo entry. The result is already showing
  /// locally from [dragSelect]'s own optimistic updates; a failure here is
  /// what puts it back, the same "revert what was already shown" shape a
  /// failed placement or restore already uses elsewhere in this file.
  ///
  /// A resize is a `move` request with a different box, never a distinct
  /// wire kind - see `canvas_ops_write.rs`'s own doc for why the server has
  /// no separate notion of the two.
  ///
  /// Clears `document.elevatedObjectId` immediately, before the request even
  /// lands: the object is optimistically back in place the instant the
  /// pointer lifts, and a failed commit reverting it moments later must not
  /// resurrect the shadow along with the position.
  Future<void> endSelect() async {
    document.elevatedObjectId.value = null;
    document.snapGuides.value = const [];
    final resize = _resize;
    _resize = null;
    if (resize != null) {
      await _commitBounds(
        resize.objectId,
        resize.fromBounds,
        resize.current,
        'That could not be resized.',
      );
      return;
    }
    final drag = _drag;
    _drag = null;
    if (drag == null) return;
    if (drag.x == drag.fromX &&
        drag.y == drag.fromY &&
        drag.w == drag.fromW &&
        drag.h == drag.fromH) {
      return;
    }
    await _commitBounds(
      drag.objectId,
      (x: drag.fromX, y: drag.fromY, w: drag.fromW, h: drag.fromH),
      (x: drag.x, y: drag.y, w: drag.w, h: drag.h),
      'That could not be moved.',
    );
  }

  /// Puts a cancelled drag or resize back where it began, and returns what
  /// moved so a relayed preview can be ended on the original box.
  ({String id, ObjectBox box})? cancelSelect() {
    document.elevatedObjectId.value = null;
    document.snapGuides.value = const [];
    final resize = _resize;
    final drag = _drag;
    _resize = null;
    _drag = null;
    ({String id, ({double x, double y, double w, double h}) box})? restored;
    if (resize != null) {
      restored = (id: resize.objectId, box: resize.fromBounds);
    } else if (drag != null) {
      restored = (
        id: drag.objectId,
        box: (x: drag.fromX, y: drag.fromY, w: drag.fromW, h: drag.fromH),
      );
    }
    if (restored == null) return null;
    final box = restored.box;
    document.moveObject(restored.id, box.x, box.y, box.w, box.h);
    document.refresh();
    return restored;
  }

  Future<bool> _commitBounds(
    String objectId,
    ({double x, double y, double w, double h}) from,
    ({double x, double y, double w, double h}) to,
    String errorMessage, {
    bool record = true,
  }) async {
    if (to == from) return true;
    try {
      await _sendOp(
        (id) => client.submitCanvasOp(
          channelId,
          id: id,
          kind: 'move',
          objectId: objectId,
          x: to.x,
          y: to.y,
          w: to.w,
          h: to.h,
        ),
      );
      if (record) {
        _pushUndo(_MoveEntry(objectId, from.x, from.y, from.w, from.h));
      }
      return true;
    } on api.ApiException {
      _rollBackBounds(objectId, from, to);
      onError(errorMessage);
      return false;
    }
  }

  /// Puts the old box back only while the optimistic one is still showing, so
  /// a remote change that landed meanwhile is not overwritten.
  void _rollBackBounds(
    String objectId,
    ({double x, double y, double w, double h}) from,
    ({double x, double y, double w, double h}) to,
  ) {
    if (document.objectBounds(objectId) != to) return;
    document.moveObject(objectId, from.x, from.y, from.w, from.h);
    document.refresh();
  }

  Future<_RedoEntry?> _undoMove(
    String objectId,
    double x,
    double y,
    double w,
    double h,
  ) async {
    final before = await _moveTo(objectId, x, y, w, h, 'undone');
    if (before == null) return null;
    return _RedoMove(objectId, before.x, before.y, before.w, before.h);
  }

  Future<_UndoEntry?> _redoMove(_RedoMove move) async {
    final before = await _moveTo(
      move.objectId,
      move.toX,
      move.toY,
      move.toW,
      move.toH,
      'redone',
    );
    if (before == null) return null;
    return _MoveEntry(move.objectId, before.x, before.y, before.w, before.h);
  }

  /// Moves an object to a box a history step names, locally first for the
  /// same immediate feedback a drag gives, and returns the box it left so
  /// the opposite history step can put it back. Null when the request failed
  /// or the object is gone from this client.
  Future<({double x, double y, double w, double h})?> _moveTo(
    String objectId,
    double x,
    double y,
    double w,
    double h,
    String verb,
  ) async {
    final before = document.objectBounds(objectId);
    document.moveObject(objectId, x, y, w, h);
    document.refresh();
    try {
      await _sendOp(
        (id) => client.submitCanvasOp(
          channelId,
          id: id,
          kind: 'move',
          objectId: objectId,
          x: x,
          y: y,
          w: w,
          h: h,
        ),
      );
      return before;
    } on api.ApiException {
      if (before != null) {
        _rollBackBounds(objectId, before, (x: x, y: y, w: w, h: h));
      }
      onError('That could not be $verb.');
      return null;
    }
  }
}
