// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_surface.dart';

/// Below this screen-space distance on both axes, a shape placement reads
/// as a tap rather than a drag - see [_CanvasSurfaceGestures._resolveShapeDrag].
const double _shapeDragThreshold = 4.0;

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

  /// This surface's own pointer count plus [CanvasDocument.externalPointers]
  /// - a second finger a presence tile absorbed before this widget's own
  /// [Listener] ever saw its down event still has to count as a real second
  /// pointer for the pinch-cancellation and grab-pan logic below.
  int get _totalPointers => _pointers + widget.document.externalPointers.count;

  Offset _toWorld(Offset screen) {
    final camera = widget.document.camera;
    return Offset(
      camera.x + screen.dx / camera.zoom,
      camera.y + screen.dy / camera.zoom,
    );
  }

  void _down(PointerDownEvent event) {
    widget.onPointerMoved?.call(_toWorld(event.localPosition));
    _pointers++;
    if (_isPanButton(event.buttons)) {
      // A second pointer's own grab button must not steal an already-owned pan - see _move's identical guard.
      if (_panning.value) return;
      // Nothing has begun for this pointer yet, so there is only a stray draft to drop, not flush.
      final hadDraft = !_draft.isEmpty;
      _draft.cancel();
      if (hadDraft) widget.onDraftEnded?.call();
      _shapeDraft.cancel();
      _pendingErasePoint = null;
      _beginPan(event.pointer, event.localPosition);
      return;
    }
    if (_totalPointers > 1) {
      final hadDraft = !_draft.isEmpty;
      _draft.cancel();
      if (hadDraft) widget.onDraftEnded?.call();
      _shapeDraft.cancel();
      _pendingErasePoint = null;
      return;
    }
    if (!widget.enabled) return;
    if (widget.tool.placesInk &&
        !widget.document.acceptsPlacementAt(_toWorld(event.localPosition))) {
      return;
    }
    switch (widget.tool) {
      case CanvasTool.eraser:
        _pendingErasePoint = _toWorld(event.localPosition);
      case CanvasTool.pan:
        widget.onSelectStart?.call(_toWorld(event.localPosition));
      case CanvasTool.note:
        _pendingPlacementTool = CanvasTool.note;
        _pendingPlacementWorld = _toWorld(event.localPosition);
      case CanvasTool.shape:
        _pendingPlacementTool = CanvasTool.shape;
        _pendingPlacementWorld = _toWorld(event.localPosition);
        _shapeDraft.begin(event.localPosition, widget.shapeKind);
      case CanvasTool.pen:
        // Pan is the middle button, so a right-press reaches here; it opens the menu, it does not draw.
        if (event.buttons & kPrimaryButton == 0) return;
        _draft.begin(event.localPosition);
        widget.onDraftPoint?.call(_toWorld(event.localPosition));
    }
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
        _resumeToolAt(event.localPosition);
      }
      return;
    }
    if (_isPanButton(event.buttons)) {
      _interruptForPan();
      _beginPan(event.pointer, event.localPosition);
      return;
    }
    if (_totalPointers != 1 || !widget.enabled) return;
    switch (widget.tool) {
      case CanvasTool.eraser:
        if (_pendingErasePoint case final pending?) {
          widget.onErase?.call(pending);
          _pendingErasePoint = null;
        }
        widget.onErase?.call(_toWorld(event.localPosition));
      case CanvasTool.pan:
        widget.onSelectDrag?.call(_toWorld(event.localPosition));
      case CanvasTool.note:
        break;
      case CanvasTool.shape:
        _shapeDraft.update(event.localPosition);
      case CanvasTool.pen:
        _draft.extend(event.localPosition);
        widget.onDraftPoint?.call(_toWorld(event.localPosition));
    }
  }

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

  /// `wasAlone` is read before the decrement below: a second finger a presence
  /// tile absorbed never reaches [_down], so this is the only place a one-point
  /// draft can still learn it was never alone.
  void _up(PointerEvent event) {
    final wasAlone = _totalPointers <= 1;
    _pointers = (_pointers - 1).clamp(0, 10);
    _reportLeftIfTouch(event);
    if (_panning.value) {
      // An unrelated pointer lifting (a second finger, say) must not end someone else's grab.
      if (event.pointer != _panPointer) return;
      _endPan();
      return;
    }
    _resolvePendingPlacement();
    switch (widget.tool) {
      case CanvasTool.eraser:
        if (_pendingErasePoint case final pending?) {
          widget.onErase?.call(pending);
          _pendingErasePoint = null;
        }
        if (_totalPointers == 0) widget.onEraseEnd?.call();
      case CanvasTool.pan:
        if (_totalPointers == 0) widget.onSelectEnd?.call();
      case CanvasTool.note:
      case CanvasTool.shape:
        break;
      case CanvasTool.pen:
        if (_draft.isEmpty) return;
        final screen = _draft.take();
        widget.onDraftEnded?.call();
        // A single point still commits: it paints as a dot, not nothing.
        if (screen.length < 2 && !wasAlone) return;
        widget.onStroke(
          screen
              .map((p) => widget.document.clampToBoard(_toWorld(p)))
              .toList(growable: false),
        );
    }
  }

  /// The system took the touch (a back gesture, palm rejection): not a lift,
  /// so nothing is committed. Live gestures still close, since they have
  /// already acted and would otherwise never learn they ended.
  void _cancel(PointerEvent event) {
    _pointers = (_pointers - 1).clamp(0, 10);
    _reportLeftIfTouch(event);
    if (_panning.value) {
      if (event.pointer == _panPointer) _endPan();
      return;
    }
    _pendingPlacementTool = null;
    _pendingPlacementWorld = null;
    _shapeDraft.cancel();
    _pendingErasePoint = null;
    switch (widget.tool) {
      case CanvasTool.eraser:
        if (_totalPointers == 0) widget.onEraseEnd?.call();
      case CanvasTool.pan:
        if (_totalPointers == 0) widget.onSelectEnd?.call();
      case CanvasTool.note:
      case CanvasTool.shape:
        break;
      case CanvasTool.pen:
        if (_draft.isEmpty) return;
        _draft.cancel();
        widget.onDraftEnded?.call();
    }
  }

  /// Fires whichever placement [_down] armed, at the point it was armed
  /// with, only on the [_up] that drops [_pointers] to zero. Runs once per
  /// lifted pointer and consumes pending state on its first call regardless
  /// of [_pointers], so any second pointer having touched down - landing
  /// that first call at a nonzero count - is what stops this ever firing.
  void _resolvePendingPlacement() {
    final tool = _pendingPlacementTool;
    final world = _pendingPlacementWorld;
    if (tool == null || world == null) return;
    _pendingPlacementTool = null;
    _pendingPlacementWorld = null;
    if (_totalPointers != 0) return;
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
  /// centre and world-space size, clamped to the same
  /// [minObjectSize]..`maxObjectExtent` a resize handle already respects, so
  /// a placement drag can never commit a box a resize could not.
  (Offset, Size?) _resolveShapeDrag(Offset world) {
    final screen = _shapeDraft.take();
    if (screen == null ||
        (screen.width < _shapeDragThreshold &&
            screen.height < _shapeDragThreshold)) {
      return (world, null);
    }
    final bounds = Rect.fromPoints(
      _toWorld(screen.topLeft),
      _toWorld(screen.bottomRight),
    );
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

  /// Re-arms the active tool at [screen] as though this pointer had just
  /// gone down here - the counterpart to [_interruptForPan]'s cancel, for
  /// when a grab ends mid-gesture (the grab button released while another
  /// stays held) rather than the whole pointer lifting. Note/shape still
  /// resolve on this same pointer's eventual up through the normal
  /// [_pendingPlacementTool] path, exactly as a fresh tap would.
  void _resumeToolAt(Offset screen) {
    switch (widget.tool) {
      case CanvasTool.eraser:
        _pendingErasePoint = _toWorld(screen);
      case CanvasTool.pan:
        widget.onSelectStart?.call(_toWorld(screen));
      case CanvasTool.note:
        _pendingPlacementTool = CanvasTool.note;
        _pendingPlacementWorld = _toWorld(screen);
      case CanvasTool.shape:
        _pendingPlacementTool = CanvasTool.shape;
        _pendingPlacementWorld = _toWorld(screen);
        _shapeDraft.begin(screen, widget.shapeKind);
      case CanvasTool.pen:
        _draft.begin(screen);
        widget.onDraftPoint?.call(_toWorld(screen));
    }
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

  /// Ends whatever tool gesture this pointer was mid-way through the moment
  /// the pan button joins it - only reachable from [_move], since [_down]
  /// has nothing to end yet. A pen draft is cancelled, not submitted as a
  /// truncated stroke or left suspended for a resume this widget never
  /// attempts - the same treatment a second touch pointer already gives it
  /// above. Erase and select flush through their own end callback instead,
  /// since both apply incrementally and an unflushed accumulator on the
  /// caller's side would otherwise sit forever unsubmitted.
  void _interruptForPan() {
    final hadDraft = !_draft.isEmpty;
    _draft.cancel();
    if (hadDraft) widget.onDraftEnded?.call();
    _shapeDraft.cancel();
    switch (widget.tool) {
      case CanvasTool.eraser:
        if (_pendingErasePoint case final pending?) {
          widget.onErase?.call(pending);
          _pendingErasePoint = null;
        }
        widget.onEraseEnd?.call();
      case CanvasTool.pan:
        widget.onSelectEnd?.call();
      case CanvasTool.note:
      case CanvasTool.shape:
      case CanvasTool.pen:
        break;
    }
    _pendingPlacementTool = null;
    _pendingPlacementWorld = null;
  }

  /// A plain wheel notch pans vertically - the one axis a mouse wheel
  /// itself reports, and what a trackpad's own vertical swipe already
  /// produces too - while Ctrl/Cmd zooms and Shift adds the horizontal axis
  /// a single-axis wheel cannot report on its own. A trackpad's native
  /// two-axis swipe keeps panning freely in both directions unmodified,
  /// which switching the unmodified case to zoom would have broken; a
  /// middle-mouse grab-drag (see [_beginPan]) is what actually gives a
  /// plain mouse free motion in both axes, not the wheel.
  ///
  /// The actual arithmetic lives in [cameraAfterWheelScroll], a pure
  /// function rather than a method here, because this surface is no longer
  /// the only thing a wheel event can land on: a manipulable presence tile
  /// in the app layer sits in front of it with its own opaque hit test, and
  /// has to answer for that same gesture rather than silently swallowing it
  /// - see that widget's own doc for why. Two independent copies of this
  /// would drift the day only one changed; this is the one place either
  /// caller reads it from.
  void _signal(PointerSignalEvent event) {
    final document = widget.document;
    // On the web a ctrl-wheel or trackpad pinch arrives as a scale event, never as a scroll.
    if (event is PointerScaleEvent) {
      document.setCamera(
        cameraAfterZoom(
          document.camera,
          focal: event.localPosition,
          zoomTarget: document.camera.zoom * event.scale,
        ),
      );
      return;
    }
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    document.setCamera(
      cameraAfterWheelScroll(
        document.camera,
        focal: event.localPosition,
        dx: event.scrollDelta.dx,
        dy: event.scrollDelta.dy,
        zoomModifier: keys.isControlPressed || keys.isMetaPressed,
        horizontalModifier: keys.isShiftPressed,
      ),
    );
  }

  void _scaleBegin(ScaleStartDetails details) {
    _scaleStart = widget.document.camera;
    _scaleFocalWorld = _toWorld(details.localFocalPoint);
  }

  void _scaleUpdate(ScaleUpdateDetails details) {
    final start = _scaleStart;
    final anchor = _scaleFocalWorld;
    if (start == null || anchor == null || details.pointerCount < 2) return;
    final document = widget.document;
    document.setCamera(start.copyWith(zoom: start.zoom * details.scale));
    final camera = document.camera;
    final focal = details.localFocalPoint;
    document.setCamera(
      camera.copyWith(
        x: anchor.dx - focal.dx / camera.zoom,
        y: anchor.dy - focal.dy / camera.zoom,
      ),
    );
  }
}
