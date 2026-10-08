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
      y = fromY;

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
}

/// One resize-handle drag in progress: which object and corner, its bounds
/// when the drag began (for [CanvasOpsController.undo] to restore, and as
/// the anchor [resizeBounds] measures every later point against), and the
/// bounds it currently previews.
class _ResizeState {
  _ResizeState(this.objectId, this.corner, this.fromBounds)
    : current = fromBounds;

  final String objectId;
  final ResizeCorner corner;
  final ({double x, double y, double w, double h}) fromBounds;
  ({double x, double y, double w, double h}) current;
}

/// The Move tool: picking an object up, dragging or resizing it, and
/// committing or undoing the result. Its own extension, the shape
/// `CanvasOpsControllerReorder` already established, since these methods
/// need `CanvasOpsController`'s own private `_drag`/`_resize` fields and
/// undo stack.
extension CanvasOpsControllerSelect on CanvasOpsController {
  /// Grabs a resize handle on the current selection if [world] lands on
  /// one, or otherwise picks up the topmost live box object (image, note or
  /// shape) under [world] the caller may move - their own, or anybody's
  /// with [manageCanvas] - selecting it and remembering its original bounds
  /// so [dragSelect] can preview locally and [undo] can reverse whichever
  /// this turns out to be. Failing that, falls back to a stroke under
  /// [world]: selectable for reorder (see `CanvasOpsControllerReorder`),
  /// never for a drag, since a freehand mark has no box a person expects to
  /// relocate the way a placed box object's is. Deselects, silently, if
  /// nothing is there: the same "scope at hit-test time" choice
  /// [onErasePoint] already makes.
  ///
  /// A handle only exists on a box kind (see `SelectionPainter`'s own doc
  /// for why a stroke never grows one), so the resize branch is skipped for
  /// a stroke without needing its own check here.
  void beginSelect(
    Offset world, {
    required bool manageCanvas,
    required String? selfId,
    bool touch = false,
  }) {
    final selected = document.selectedObjectId.value;
    if (selected != null &&
        document.kindOf(selected) != CanvasObjectKind.stroke) {
      final owns =
          !isLocked(selected) &&
          (manageCanvas || document.authorIdOf(selected) == selfId);
      final bounds = document.objectBounds(selected);
      if (owns && bounds != null && !_isDeepInterior(bounds, world)) {
        final corner = hitTestResizeHandle(
          bounds,
          world,
          document.camera.zoom,
          hitRadius: touch ? touchResizeHandleHitRadius : resizeHandleHitRadius,
        );
        if (corner != null) {
          _resize = _ResizeState(selected, corner, bounds);
          document.elevatedObjectId.value = selected;
          return;
        }
      }
    }
    bool allowed(CanvasStroke stroke) =>
        !isLocked(stroke.id) &&
        (manageCanvas ||
            (stroke.authorId != null && stroke.authorId == selfId));
    final id =
        hitTestBoxAt(document, world, allowed: allowed) ??
        _hitTestSelectableStroke(world, allowed);
    document.selectedObjectId.value = id;
    if (id == null || document.kindOf(id) == CanvasObjectKind.stroke) return;
    final bounds = document.objectBounds(id);
    if (bounds == null) return;
    _drag = _DragState(id, bounds.x, bounds.y, bounds.w, bounds.h, world);
    document.elevatedObjectId.value = id;
  }

  /// Whether [world] lands in the innermost half of [bounds] - the zone a
  /// plain move-drag always wins, regardless of how far
  /// `hitTestResizeHandle`'s own zoom-scaled radius reaches (its own doc:
  /// "never becomes unhittable zoomed out", a deliberate, unbounded growth
  /// as zoom shrinks). Without this, a selected object small enough that
  /// its whole body sits inside that fixed screen-space radius - a
  /// resized-down or naturally small pasted image is the easy way there,
  /// with `minObjectSize` (8) well under it at zoom 1 - could never be
  /// grabbed for a plain move again: every click, including dead centre,
  /// resolved to a resize. The guard only ever narrows where a resize may
  /// start; a click anywhere near an edge or corner, or outside the box
  /// entirely, is untouched.
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

  /// A stroke under [world] the caller may reorder, or null. `hitTestStroke`
  /// tests every kind's own path/tolerance, not only strokes, so a box
  /// object [beginSelect]'s own box test just missed is excluded here
  /// rather than re-admitted through a looser one.
  String? _hitTestSelectableStroke(
    Offset world,
    bool Function(CanvasStroke stroke) allowed,
  ) {
    final id = hitTestStroke(document, world, allowed: allowed);
    if (id == null || document.kindOf(id) != CanvasObjectKind.stroke) {
      return null;
    }
    return id;
  }

  /// Continues whichever gesture [beginSelect] started: reshapes the
  /// selection's box toward [world] if a handle was grabbed ([lockAspect]
  /// true unless a modifier is held), or moves it by the same drag delta
  /// otherwise. Does nothing if neither is under way.
  void dragSelect(Offset world, {required bool lockAspect}) {
    final resize = _resize;
    if (resize != null) {
      resize.current = resizeBounds(
        corner: resize.corner,
        original: resize.fromBounds,
        pointerWorld: world,
        lockAspect: lockAspect,
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
    drag.x = drag.fromX + (world.dx - drag.anchor.dx);
    drag.y = drag.fromY + (world.dy - drag.anchor.dy);
    document.moveObject(drag.objectId, drag.x, drag.y, drag.fromW, drag.fromH);
    document.refresh();
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
    if (drag.x == drag.fromX && drag.y == drag.fromY) return;
    await _commitBounds(
      drag.objectId,
      (x: drag.fromX, y: drag.fromY, w: drag.fromW, h: drag.fromH),
      (x: drag.x, y: drag.y, w: drag.fromW, h: drag.fromH),
      'That could not be moved.',
    );
  }

  Future<void> _commitBounds(
    String objectId,
    ({double x, double y, double w, double h}) from,
    ({double x, double y, double w, double h}) to,
    String errorMessage,
  ) async {
    if (to == from) return;
    try {
      await client.submitCanvasOp(
        channelId,
        id: newCanvasOpId(),
        kind: 'move',
        objectId: objectId,
        x: to.x,
        y: to.y,
        w: to.w,
        h: to.h,
      );
      _pushUndo(_MoveEntry(objectId, from.x, from.y, from.w, from.h));
    } on api.ApiException {
      document.moveObject(objectId, from.x, from.y, from.w, from.h);
      document.refresh();
      onError(errorMessage);
    }
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
      await client.submitCanvasOp(
        channelId,
        id: newCanvasOpId(),
        kind: 'move',
        objectId: objectId,
        x: x,
        y: y,
        w: w,
        h: h,
      );
      return before;
    } on api.ApiException {
      if (before != null) {
        document.moveObject(objectId, before.x, before.y, before.w, before.h);
        document.refresh();
      }
      onError('That could not be $verb.');
      return null;
    }
  }
}
