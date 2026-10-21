// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_surface.dart';

/// Below this screen-space distance on both axes, a shape placement reads
/// as a tap rather than a drag - see [_CanvasSurfaceGestures._resolveShapeDrag].
const double _shapeDragThreshold = 4.0;

/// How far, in screen pixels, a select gesture may travel and still be a tap.
const double _selectTapSlop = 6.0;

/// The one tool gesture a surface runs at a time. It belongs to the first
/// accepted pointer and the tool and camera that were current when that
/// pointer went down; it ends when that pointer lifts or is cancelled, or
/// sooner when a second pointer turns it into a pinch.
class _Gesture {
  _Gesture(this.pointer, this.tool, this.camera, this.downAt);

  final int pointer;
  final CanvasTool tool;
  final Duration downAt;

  /// The camera this gesture's screen points were sampled under.
  Camera camera;
}

/// Every pointer, scroll and scale handler [_CanvasSurfaceState.build]
/// wires up, plus the coordinate conversion and cursor choice they share.
/// A `part of` file rather than a mixin: the eraser and placement tools
/// read and write [_CanvasSurfaceState]'s own private pointer-tracking
/// fields directly, the same access `canvas_document_selection.dart`'s
/// extension already leans on for `CanvasDocument`'s private slot table.
extension _CanvasSurfaceGestures on _CanvasSurfaceState {
  /// A tool switch or a pan starting/ending are the only cursor changes,
  /// never a per-hover one - this widget deliberately never rebuilds for
  /// anything the pointer does (see the library doc), so `panning` arrives
  /// as an argument from the one [ValueListenableBuilder] that does react
  /// to it, keeping this a pure function. A disabled surface (a timed-out
  /// member) shows the plain arrow regardless of tool - except while
  /// panning, which stays available disabled or not.
  MouseCursor _cursorFor(CanvasTool tool, bool enabled, bool panning) {
    if (panning) return SystemMouseCursors.grabbing;
    if (!enabled) return SystemMouseCursors.basic;
    return switch (tool) {
      CanvasTool.pen ||
      CanvasTool.eraser ||
      CanvasTool.note ||
      CanvasTool.shape =>
        SystemMouseCursors.precise,
      CanvasTool.pan => SystemMouseCursors.grab,
    };
  }

  /// Middle-mouse-button drag was chosen over right-drag for grab-to-pan:
  /// it is the near-universal convention in drawing and design tools, and a
  /// canvas object's own right-click context menu (built elsewhere) would
  /// otherwise have to tell a click from the start of a drag on every
  /// right-press, which middle-drag simply never collides with.
  bool _isPanButton(int buttons) => buttons & kMiddleMouseButton != 0;

  /// Only a primary press drives a tool; a stylus counts by contact alone, since a barrel button or an eraser end can leave the primary bit clear.
  bool _isToolPress(PointerDownEvent event) =>
      _isStylus(event.kind) || event.buttons & kPrimaryButton != 0;

  bool _isStylus(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  /// The pointers taking part in a gesture plus
  /// [CanvasDocument.externalPointers] - a second finger a presence tile
  /// absorbed before this widget's own [Listener] ever saw its down event
  /// still has to count as a real second pointer.
  int get _totalPointers =>
      _downPointers.length + widget.document.externalPointers.count;

  Offset _toWorld(Offset screen, [Camera? under]) {
    final camera = under ?? widget.document.camera;
    return Offset(
      camera.x + screen.dx / camera.zoom,
      camera.y + screen.dy / camera.zoom,
    );
  }

  void _down(PointerDownEvent event) {
    widget.document.lastPointerKind = event.kind;
    widget.onPointerMoved?.call(_toWorld(event.localPosition));
    if (_isPanButton(event.buttons)) {
      _downPointers[event.pointer] = event.kind;
      _downForPan(event);
      return;
    }
    if (!_isToolPress(event)) return;
    final stylus = _isStylus(event.kind);
    if (stylus) {
      _stylusTakesOver();
      _stylusPointers.add(event.pointer);
    } else if (_stylusPointers.isNotEmpty) {
      return;
    }
    final alone = _totalPointers == 0;
    _downPointers[event.pointer] = event.kind;
    if (!alone) {
      _interruptGesture();
      return;
    }
    if (!widget.enabled) return;
    _startGesture(event);
  }

  /// A stylus beats whatever touch was already down: that was a resting palm.
  void _stylusTakesOver() {
    final palms = [
      for (final entry in _downPointers.entries)
        if (entry.value == PointerDeviceKind.touch) entry.key,
    ];
    if (palms.isEmpty) return;
    if (palms.contains(_gesture?.pointer)) _cancelGesture();
    palms.forEach(_downPointers.remove);
  }

  void _downForPan(PointerDownEvent event) {
    // A second pointer's own grab button must not steal an already-owned pan - see _move's identical guard.
    if (_panning.value) return;
    _interruptGesture();
    _beginPan(event.pointer, event.localPosition);
  }

  /// Arms the gesture the active tool needs for a pointer that went down alone at [screen].
  void _startGesture(PointerEvent event) {
    final (pointer, kind, screen) = (
      event.pointer,
      event.kind,
      event.localPosition,
    );
    final tool = kind == PointerDeviceKind.invertedStylus
        ? CanvasTool.eraser
        : widget.tool;
    final world = _toWorld(screen);
    if (tool.placesInk && !widget.document.acceptsPlacementAt(world)) return;
    _gesture = _Gesture(
      pointer,
      tool,
      widget.document.camera,
      event.timeStamp,
    );
    switch (tool) {
      case CanvasTool.eraser:
        _pendingErasePoint = world;
      case CanvasTool.pan:
        _selectDownAt = screen;
        _ownCamera(() => widget.onSelectStart?.call(world));
      case CanvasTool.note:
        _pendingPlacementTool = CanvasTool.note;
        _pendingPlacementWorld = world;
      case CanvasTool.shape:
        _pendingPlacementTool = CanvasTool.shape;
        _pendingPlacementWorld = world;
        _shapeDraft.begin(screen, widget.shapeKind);
      case CanvasTool.pen:
        _draft.begin(screen);
        widget.onDraftPoint?.call(world);
    }
  }

  /// Runs [body], which may move the camera on this gesture's behalf, without that counting as a foreign camera change.
  void _ownCamera(VoidCallback body) {
    _inOwnCallback = true;
    try {
      body();
    } finally {
      _inOwnCallback = false;
      _gesture?.camera = widget.document.camera;
    }
  }

  /// A camera moved by something other than the gesture (a follow, a summon, a wheel) would relocate what it has drawn so far.
  void _onDocumentChanged() {
    final gesture = _gesture;
    if (gesture == null || _inOwnCallback) return;
    if (widget.document.camera != gesture.camera) _finishGesture();
  }

  void _move(PointerMoveEvent event) {
    widget.onPointerMoved?.call(_toWorld(event.localPosition));
    if (_panning.value) {
      // An unrelated pointer moving (a second finger, say) must not steer someone else's grab.
      if (event.pointer != _panPointer) return;
      if (_isPanButton(event.buttons)) {
        _updatePan(event.localPosition);
        return;
      }
      // The grab button itself let go, but this pointer still holds another - resume the tool right here rather than staying stuck panning until the whole pointer lifts.
      _endPan();
      if (_totalPointers == 1 && widget.enabled) {
        _startGesture(event);
      }
      return;
    }
    if (_isPanButton(event.buttons) &&
        _downPointers.containsKey(event.pointer)) {
      _interruptGesture();
      _beginPan(event.pointer, event.localPosition);
      return;
    }
    final gesture = _gesture;
    if (gesture == null || gesture.pointer != event.pointer) return;
    if (_totalPointers != 1 || !widget.enabled) return;
    final screen = event.localPosition;
    final world = _toWorld(screen);
    switch (gesture.tool) {
      case CanvasTool.eraser:
        if (_pendingErasePoint case final pending?) {
          widget.onErase?.call(pending);
          _pendingErasePoint = null;
        }
        widget.onErase?.call(world);
      case CanvasTool.pan:
        if (_selectDownAt case final down? when _movedPastTap(down, event)) {
          _selectDownAt = null;
        }
        _ownCamera(() => widget.onSelectDrag?.call(world));
      case CanvasTool.note:
        break;
      case CanvasTool.shape:
        _shapeDraft.update(screen);
      case CanvasTool.pen:
        _draft.extend(screen);
        widget.onDraftPoint?.call(world);
    }
  }

  bool _movedPastTap(Offset down, PointerEvent event) =>
      (event.localPosition - down).distance > _selectTapSlop;

  /// A touch or pen has no hover, so lifting it is leaving the canvas.
  void _reportLeftIfTouch(PointerEvent event) {
    if (event.kind == PointerDeviceKind.mouse || _totalPointers != 0) return;
    widget.onPointerLeft?.call();
  }

  /// A pointer moving with nothing pressed - drawing or erasing never
  /// happens here, only the position report a mouse (not a touch, which
  /// never hovers) gets for free.
  void _hover(PointerHoverEvent event) {
    widget.onPointerMoved?.call(_toWorld(event.localPosition));
  }

  /// Forgets [event]'s pointer, and says whether it ever took part: a
  /// right-click or a rejected palm never did, so its lift changes nothing.
  bool _release(PointerEvent event) {
    _stylusPointers.remove(event.pointer);
    if (_downPointers.remove(event.pointer) == null) return false;
    _reportLeftIfTouch(event);
    return true;
  }

  void _up(PointerUpEvent event) {
    final wasAlone = _totalPointers <= 1;
    if (!_release(event)) return;
    if (_panning.value) {
      // An unrelated pointer lifting (a second finger, say) must not end someone else's grab.
      if (event.pointer == _panPointer) _endPan();
      return;
    }
    if (_gesture?.pointer != event.pointer) return;
    _finishGesture(lift: event, wasAlone: wasAlone);
  }

  /// The system took the touch (a back gesture, palm rejection): not a lift,
  /// so nothing the gesture did is kept.
  void _cancel(PointerCancelEvent event) {
    if (!_release(event)) return;
    if (_panning.value) {
      if (event.pointer == _panPointer) _endPan();
      return;
    }
    if (_gesture?.pointer == event.pointer) _cancelGesture();
  }

  /// Ends the gesture keeping what it did: a pen stroke is committed, an
  /// erase or a drag is submitted. A [lift] also resolves a tap, a note or a
  /// shape placement; without one (the tool or camera changed under it) the
  /// pointer is simply ignored from here until it lifts.
  void _finishGesture({PointerUpEvent? lift, bool wasAlone = true}) {
    final gesture = _gesture;
    if (gesture == null) return;
    _gesture = null;
    switch (gesture.tool) {
      case CanvasTool.eraser:
        _flushPendingErase();
        widget.onEraseEnd?.call();
      case CanvasTool.pan:
        final tapAt = _selectDownAt;
        _selectDownAt = null;
        _ownCamera(() => widget.onSelectEnd?.call());
        final quick =
            lift != null && lift.timeStamp - gesture.downAt < kLongPressTimeout;
        if (quick && tapAt != null && !_movedPastTap(tapAt, lift)) {
          widget.onSelectTap?.call(_toWorld(lift.localPosition), lift.kind);
        }
      case CanvasTool.note:
      case CanvasTool.shape:
        if (lift == null) {
          _dropPlacement();
        } else {
          _resolvePendingPlacement();
        }
      case CanvasTool.pen:
        _commitDraft(gesture.camera, single: lift != null && wasAlone);
    }
  }

  /// Ends the gesture because a second pointer or the pan button joined it:
  /// what an erase or a drag already did is kept, a draft is not.
  void _interruptGesture() {
    final gesture = _gesture;
    if (gesture == null) return;
    _gesture = null;
    _dropPlacement();
    switch (gesture.tool) {
      case CanvasTool.eraser:
        _pendingErasePoint = null;
        widget.onEraseEnd?.call();
      case CanvasTool.pan:
        _selectDownAt = null;
        _ownCamera(() => widget.onSelectEnd?.call());
      case CanvasTool.pen:
        _dropDraft();
      case CanvasTool.note:
      case CanvasTool.shape:
        break;
    }
  }

  /// Ends the gesture as though it never happened: the owner's own cancel
  /// event is the system saying the touch was not meant.
  void _cancelGesture() {
    final gesture = _gesture;
    if (gesture == null) return;
    _gesture = null;
    _dropPlacement();
    _pendingErasePoint = null;
    switch (gesture.tool) {
      case CanvasTool.eraser:
        widget.onEraseCancel?.call();
      case CanvasTool.pan:
        _selectDownAt = null;
        _ownCamera(() => widget.onSelectCancel?.call());
      case CanvasTool.pen:
        _dropDraft();
      case CanvasTool.note:
      case CanvasTool.shape:
        break;
    }
  }

  void _flushPendingErase() {
    if (_pendingErasePoint case final pending?) {
      widget.onErase?.call(pending);
      _pendingErasePoint = null;
    }
  }

  void _dropPlacement() {
    _pendingPlacementTool = null;
    _pendingPlacementWorld = null;
    _shapeDraft.cancel();
  }

  void _dropDraft() {
    if (_draft.isEmpty) return;
    _draft.cancel();
    widget.onDraftEnded?.call();
  }

  /// Hands the draft to [CanvasSurface.onStroke]. A single point is a dot
  /// only when [single]; a lone point left by a pointer that never drew
  /// alone is a stray touch.
  void _commitDraft(Camera under, {required bool single}) {
    if (_draft.isEmpty) return;
    final screen = _draft.take();
    widget.onDraftEnded?.call();
    if (screen.length < 2 && !single) return;
    widget.onStroke(
      screen
          .map((p) => widget.document.clampToBoard(_toWorld(p, under)))
          .toList(growable: false),
    );
  }

  /// Fires whichever placement [_startGesture] armed, at the point it was
  /// armed with, on the lift of the pointer that armed it. A pointer a
  /// presence tile absorbed still holds the placement back.
  void _resolvePendingPlacement() {
    final tool = _pendingPlacementTool;
    final world = _pendingPlacementWorld;
    if (tool == null || world == null) return;
    if (_totalPointers != 0) {
      _dropPlacement();
      return;
    }
    _pendingPlacementTool = null;
    _pendingPlacementWorld = null;
    switch (tool) {
      case CanvasTool.note:
        widget.onNotePlace?.call(world);
      case CanvasTool.shape:
        final (center, size) = _resolveShapeDrag(world);
        widget.onShapePlace?.call(center, size);
      case CanvasTool.pen:
      case CanvasTool.eraser:
      case CanvasTool.pan:
        break;
    }
  }

  /// [world], unchanged, and a null size for a plain tap (nothing in
  /// [_shapeDraft] worth calling a drag); otherwise the dragged box's own
  /// centre and world-space size, clipped to the board and clamped to the
  /// same [minObjectSize]..`maxObjectExtent` a resize handle already
  /// respects, so a placement drag can never commit a box a resize could not.
  (Offset, Size?) _resolveShapeDrag(Offset world) {
    final screen = _shapeDraft.take();
    if (screen == null ||
        (screen.width < _shapeDragThreshold &&
            screen.height < _shapeDragThreshold)) {
      return (world, null);
    }
    var bounds = Rect.fromPoints(
      _toWorld(screen.topLeft),
      _toWorld(screen.bottomRight),
    );
    final board = widget.document.board;
    if (board != null && bounds.overlaps(board)) {
      bounds = bounds.intersect(board);
    }
    final width = bounds.width.clamp(minObjectSize, maxObjectExtent);
    final height = bounds.height.clamp(minObjectSize, maxObjectExtent);
    return (bounds.center, Size(width, height));
  }

  /// Starts a grab-pan from [screen], the anchor every later [_updatePan]
  /// measures its delta against, owned by [pointer] alone - see
  /// `_panPointer`'s own doc. Called from [_down] when the pan button is
  /// the first (or only) one pressed, and from [_move] when it joins an
  /// already-down button - the two call sites [_isPanButton] itself is
  /// checked from, since a second button joining a mouse pointer already
  /// down is delivered as a move, never a second down.
  void _beginPan(int pointer, Offset screen) {
    _panning.value = true;
    _panPointer = pointer;
    _panFrom = screen;
  }

  /// Clears every field a pan holds, so a stale [_panFrom] cannot be reused
  /// as an anchor by whatever pans next and a stale [_panPointer] cannot
  /// match a future pointer id by coincidence.
  void _endPan() {
    _panning.value = false;
    _panPointer = null;
    _panFrom = null;
  }

  void _updatePan(Offset screen) {
    final from = _panFrom;
    if (from == null) return;
    final delta = screen - from;
    _panFrom = screen;
    final document = widget.document;
    final camera = document.camera;
    document.setCamera(
      camera.copyWith(
        x: camera.x - delta.dx / camera.zoom,
        y: camera.y - delta.dy / camera.zoom,
      ),
    );
  }
}
