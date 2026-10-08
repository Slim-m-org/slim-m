// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane.dart';

/// The select tool, undo, clear and the camera-bubble roster: split out of
/// `_CanvasPaneState` once this fix pushed the file past the 500-line hard
/// limit, the same reason `canvas_ops_controller_reorder.dart` splits its
/// own class this way - an extension in a `part of` file, not a second
/// class, since these all need `_CanvasPaneState`'s own fields.
extension _CanvasPaneGestures on _CanvasPaneState {
  /// Leaving the select tool deselects, so the outline and its resize
  /// handles do not linger over a selection nothing can act on any more
  /// while the pen or eraser is active.
  void _onToolChanged(CanvasTool tool) {
    if (tool != CanvasTool.pan) _document.selectedObjectId.value = null;
    _refresh(() => _tool = tool);
  }

  CanvasTool get _defaultTool =>
      canvasDefaultTool(compact: AppTouchTargets.of(context));

  /// Arms the tool whose key [event] is, unless its button is absent or disabled, or a text field is taking the key.
  KeyEventResult _onToolKey(
    KeyEvent event, {
    required bool canDraw,
    required bool fullscreen,
  }) {
    final keyboard = HardwareKeyboard.instance;
    if (event is! KeyDownEvent || fullscreen) return KeyEventResult.ignored;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    for (final tool in canvasToolOrder) {
      if (tool.shortcutKey != event.logicalKey) continue;
      if (!tool.isAvailable(canDraw: canDraw)) return KeyEventResult.ignored;
      _onToolChanged(tool);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Opens the note sheet, and places the note only once it comes back with
  /// real text - nothing is sent, and nothing shows on the shared canvas,
  /// for a sheet the person cancelled or left blank. [_selectPlaced] is what
  /// closes it out.
  Future<void> _onNotePlace(Offset world) async {
    final text = await showCanvasNoteSheet(context);
    if (text == null || !_mounted) return;
    final placed = await _quickPlacement.placeNote(
      world,
      text,
      onError: _engine.reportError,
    );
    if (placed != null) _selectPlaced(placed.id);
  }

  /// Places a shape of the bar's own currently-picked kind at once - no
  /// sheet, since a shape carries no text to type.
  ///
  /// Used to stay on the shape tool afterward rather than switching to
  /// select, on the theory that placing several shapes of the same kind in
  /// a row is a normal thing to want and switching tools after every tap
  /// would make that tedious. That theory is what report 3 in the backlog
  /// channel found wrong in practice: staying on the shape tool left a
  /// freshly placed shape with no way to resize it short of a manual switch
  /// to Move first, which is worse than the rapid-placement convenience it
  /// was bought with. [_selectPlaced] now matches the note and paste paths.
  Future<void> _onShapePlace(Offset world, Size? draggedSize) async {
    final placed = await _quickPlacement.placeShape(
      world,
      _shapeKind,
      draggedSize: draggedSize,
      onError: _engine.reportError,
    );
    if (placed != null) _selectPlaced(placed.id);
  }

  /// After placing a new object - a placed note, a placed shape, or a
  /// pasted image - the thing just made is the thing selected, with its
  /// resize handles already live and the surface already in Move mode: no
  /// separate switch is needed before it can be resized.
  ///
  /// Chosen over having the placement gesture itself carry a size (drag to
  /// place, sized as dragged) because it is the smaller change: it needs no
  /// new coexistence with the pinch-deferral already guarding a placement
  /// tool's own first pointer-down (see `_resolvePendingPlacement`'s doc in
  /// `canvas_surface_gestures.dart`), and no new "what does a zero-length
  /// drag produce" case to define. The cost is real and named rather than
  /// hidden: a person placing several same-sized shapes in a row now
  /// switches tools once per shape rather than never, where drag-to-place
  /// would have kept the rapid-placement flow at the cost of a heavier
  /// gesture change.
  void _selectPlaced(String objectId) {
    if (!_mounted) return;
    _document.selectedObjectId.value = objectId;
    _refresh(() => _tool = CanvasTool.pan);
  }

  void _onSelectStart(Offset world) {
    final me = ref.read(meProvider).valueOrNull;
    // A safe read, not a cold one: build() already watches this same family instance every frame.
    final manageCanvas = ref
        .read(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageCanvas);
    _ops.beginSelect(
      world,
      manageCanvas: manageCanvas,
      selfId: me?.id,
      touch: AppTouchTargets.of(context),
    );
  }

  /// Aspect locks by default; holding Shift frees it. Read fresh on every
  /// drag point rather than once at [_onSelectStart], so releasing the key
  /// mid-drag takes effect immediately rather than on the next gesture.
  void _onSelectDrag(Offset world) => _ops.dragSelect(
    world,
    lockAspect: !HardwareKeyboard.instance.isShiftPressed,
  );

  Future<void> _onSelectEnd() async {
    await _ops.endSelect();
    _refresh();
  }

  Future<void> _onBringToFront(String objectId) async {
    await _ops.bringToFront(objectId);
    _refresh();
  }

  Future<void> _onSendToBack(String objectId) async {
    await _ops.sendToBack(objectId);
    _refresh();
  }

  Future<void> _onDeleteSelected(String objectId) async {
    await _ops.deleteSelected(objectId);
    _refresh();
  }

  Future<void> _onUndo() async {
    await _ops.undo();
    _refresh();
  }

  Future<void> _onRedo() async {
    await _ops.redo();
    _refresh();
  }

  Future<void> _onClear() async {
    await _ops.clear(_sync.asOfSeq ?? 0);
    _refresh();
  }

  /// Fits the camera to whatever is actually drawn, falling back to the
  /// world origin only when there is nothing to fit - a plain camera move,
  /// so it needs no `setState` any more than a scroll or a pinch does. See
  /// `worldLimit`'s own doc for the "no route back" gap this closes, and
  /// `cameraToFit`'s own doc for why the origin fallback is still correct
  /// for an empty canvas.
  void _onRecenter() => _document.setCamera(
    cameraToFit(_document.contentBounds, _document.viewport),
  );

  /// Delete/Backspace over the current Move-tool selection, the desktop
  /// convention every other drawing surface honours - the overflow menu's
  /// own "Delete" item is the only route without this, one that needs
  /// finding rather than reaching for the key a person already expects.
  void _onDeleteKey() {
    final selected = _document.selectedObjectId.value;
    if (selected != null) unawaited(_onDeleteSelected(selected));
  }

  void _onPointerMoved(Offset world) => _relay.reportLocalPointer(world);

  /// Draws a local stroke at once - optimistic on [_document], queued for
  /// the server through [_commits] - and records it as one undoable gesture
  /// regardless of how many segments [splitStroke] broke it into.
  void _onStroke(List<Offset> worldPoints) {
    final selfId = ref.read(meProvider).valueOrNull?.id;
    final ids = <String>[];
    for (final segment in splitStroke(worldPoints)) {
      final id = newCanvasObjectId();
      ids.add(id);
      _document.applyPlaced(
        CanvasStrokeInput(
          id: id,
          seq: 0,
          zIndex: _localZ++,
          x: segment.x,
          y: segment.y,
          w: segment.w,
          h: segment.h,
          points: segment.points,
          width: _pen.width,
          colorKey: _pen.colorKey,
          authorId: selfId,
        ),
      );
      _commits.add(
        CanvasCommit(
          id: id,
          x: segment.x,
          y: segment.y,
          w: segment.w,
          h: segment.h,
          props: {
            'points': segment.points,
            'width': _pen.width,
            'color': _pen.colorKey,
          },
        ),
      );
    }
    _document.refresh();
    // recordDraw is what makes undoing this whole gesture one op, not several.
    _ops.recordDraw(ids);
    _refresh();
  }

  void _onErase(Offset world) {
    final me = ref.read(meProvider).valueOrNull;
    // A safe read, not a cold one: build() already watches this same family instance every frame.
    final manageCanvas = ref
        .read(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageCanvas);
    _ops.onErasePoint(world, manageCanvas: manageCanvas, selfId: me?.id);
  }

  Future<void> _onEraseEnd() async {
    await _ops.endErase();
    _refresh();
  }

  /// Who to show on the canvas as a camera bubble: nobody, unless this
  /// device itself has joined a call in this exact channel - a canvas
  /// viewer who has not joined the call has no LiveKit room to render a
  /// live texture from at all (`VoiceSession.cameraViewFor` answers nothing
  /// without one), so there is no video to lay out for anybody in that
  /// case, not even for participants known some other way.
  List<VoiceParticipant> _callParticipants() {
    final channelId = ref.watch(voiceFlagsProvider.select((f) => f.channelId));
    if (channelId != widget.channelId) return const [];
    final blocks = ref.watch(blocksProvider);
    final participants = ref.watch(voiceParticipantsProvider);
    return participants
        .where((p) => !blocks.contains(p.identity))
        .toList(growable: false);
  }
}
