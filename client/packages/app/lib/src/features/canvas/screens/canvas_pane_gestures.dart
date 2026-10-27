// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane.dart';

/// How close a tap must land to someone's cursor to follow them, in screen pixels.
const double _cursorTapReachPx = 20;

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
    // A deliberate pick stays through leaving fullscreen.
    _toolBeforeFullscreen = null;
    _refresh(() => _tool = tool);
  }

  CanvasTool get _defaultTool => canvasDefaultTool();

  /// A finger or a pen reaches further than a mouse, on a wide window too.
  bool get _fingerReach => switch (_document.lastPointerKind) {
    PointerDeviceKind.touch ||
    PointerDeviceKind.stylus ||
    PointerDeviceKind.invertedStylus => true,
    _ => false,
  };

  /// A press anywhere in the pane takes the keyboard back from whatever outside it held it.
  void _onPanePointerDown(PointerDownEvent event) {
    _pointersDown++;

    if (_editingNoteId == null && !_focusNode.hasFocus) {
      _boardFocusNode.requestFocus();
    }
  }

  void _onPanePointerUp(PointerEvent event) {
    if (_pointersDown > 0) _pointersDown--;
  }

  /// Arms the tool whose key [event] is, unless its button is absent or disabled, or a text field is taking the key.
  KeyEventResult _onToolKey(KeyEvent event, {required bool canDraw}) {
    final keyboard = HardwareKeyboard.instance;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (textInputHasFocus()) return KeyEventResult.ignored;
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
    final startedWith = _tool;
    var text = await showCanvasNoteSheet(context);
    if (!_mounted) return;
    _boardFocusNode.requestFocus();
    while (text != null && _mounted) {
      final placed = await _quickPlacement.placeNote(
        world,
        text,
        onError: _engine.reportError,
      );
      if (placed != null) {
        _selectPlaced(placed.id, startedWith: startedWith);
        return;
      }
      // Typed text outlives a failed placement: the sheet reopens with it.
      text = await _reopenNoteSheet(text);
    }
  }

  Future<String?> _reopenNoteSheet(String text) async {
    if (!context.mounted) return null;
    return showCanvasNoteSheet(context, initialText: text);
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
  Future<void> _onShapePlace(
    Offset world,
    Size? draggedSize, {
    bool flipX = false,
    bool flipY = false,
  }) async {
    final startedWith = _tool;
    final placed = await _quickPlacement.placeShape(
      world,
      _shapeKind,
      draggedSize: draggedSize,
      flipX: flipX,
      flipY: flipY,
      onError: _engine.reportError,
    );
    if (placed != null) _selectPlaced(placed.id, startedWith: startedWith);
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
  void _selectPlaced(String objectId, {CanvasTool? startedWith}) {
    if (!_mounted) return;
    // Undoable like a stroke: placing is an edit, and Ctrl+Z must take it back.
    _ops.recordDraw([objectId]);
    // A reply that lands after the person moved on must not change what they are doing.
    if (_pointersDown > 0 || (startedWith != null && _tool != startedWith)) {
      return;
    }
    _document.selectedObjectId.value = objectId;
    _refresh(() => _tool = CanvasTool.pan);
  }

  /// Undo, redo, paste and delete over the canvas's own selection.
  Map<ShortcutActivator, VoidCallback> _canvasEditShortcuts() => unlessTyping({
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
        unawaited(_onUndo()),
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () =>
        unawaited(_onUndo()),
    const SingleActivator(
      LogicalKeyboardKey.keyZ,
      control: true,
      shift: true,
    ): () =>
        unawaited(_onRedo()),
    const SingleActivator(
      LogicalKeyboardKey.keyZ,
      meta: true,
      shift: true,
    ): () =>
        unawaited(_onRedo()),
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): () =>
        unawaited(_onRedo()),
    // Left unbound where the keystroke cannot read the clipboard: a handled keydown makes the browser drop the paste event that carries the image.
    if (pasteKeystrokeReadsClipboardImage) ...{
      const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
          unawaited(_imagePaste.pasteFromKeystroke()),
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
          unawaited(_imagePaste.pasteFromKeystroke()),
    },
    const SingleActivator(LogicalKeyboardKey.delete): _onDeleteKey,
    const SingleActivator(LogicalKeyboardKey.backspace): _onDeleteKey,
  });

  /// How soon a second click on a note makes a double click.
  static const _doubleClickWindow = Duration(milliseconds: 400);

  /// A finished select gesture that never became a drag: a double click with
  /// a mouse, or a single tap with a finger or a pen, on the selected note.
  void _onSelectTap(Offset world, PointerDeviceKind kind) {
    final id = _document.selectedObjectId.value;
    if (id == null && _followCursorAt(world)) return;
    final bounds = id == null ? null : _document.objectBounds(id);
    final onNote =
        id != null &&
        bounds != null &&
        (_document.kindOf(id) == CanvasObjectKind.note ||
            _document.kindOf(id) == CanvasObjectKind.text) &&
        Rect.fromLTWH(bounds.x, bounds.y, bounds.w, bounds.h).contains(world);
    if (!onNote) {
      _lastNoteClick = null;
      return;
    }
    if (kind != PointerDeviceKind.mouse) {
      // The first tap selects the note; only a tap on a note that was already selected edits it.
      if (id != _selectedBeforeDown) return;
    } else {
      final last = _lastNoteClick;
      final now = clock.now();
      _lastNoteClick = (id: id, at: now);
      if (last == null ||
          last.id != id ||
          now.difference(last.at) > _doubleClickWindow) {
        return;
      }
      _lastNoteClick = null;
    }
    _onEditNote(id);
  }

  /// Opens the in-place editor, unless the note is locked or the canvas is
  /// refusing writes; the select tool and the menu only ever offer notes this
  /// person may edit.
  void _onEditNote(String id) {
    final error = ref.read(canvasEngineProvider(widget.channelId)).error;
    if (_ops.isLocked(id) || canvasErrorBlocksDrawing(error)) return;
    _refresh(() => _editingNoteId = id);
  }

  Future<void> _onNoteEditSave(String id, String text) async {
    _refresh(() => _editingNoteId = null);
    _boardFocusNode.requestFocus();
    await _ops.editNote(id, text);
    _refresh();
  }

  void _onNoteEditCancel() {
    _refresh(() {
      _editingNoteId = null;
      _text.cancelDraft();
    });
    _boardFocusNode.requestFocus();
  }

  NoteSpanStyle _noteSpanStyle(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final members = ref.watch(membersProvider).valueOrNull ?? const [];
    return NoteSpanStyle(
      knownUsernames: {for (final m in members) m.username.toLowerCase()},
      mentionInk: tokens.accent,
      mentionFill: tokens.accentSoft,
      linkInk: tokens.accent,
    );
  }

  /// Whether the roster is docked beside the canvas, as the shell decides it.
  bool get _memberPaneDocked =>
      !_threadPaneDocked &&
      memberPaneWanted(ref, MediaQuery.sizeOf(context)) &&
      LayoutClass.of(context).fitsMemberPane(MediaQuery.sizeOf(context).width);

  bool get _threadPaneDocked =>
      ref.read(openThreadProvider) != null &&
      LayoutClass.of(context).fitsThreadPane(MediaQuery.sizeOf(context).width);

  void _closeThreadPane() => ref.read(openThreadProvider.notifier).state = null;

  void _closeMemberPane() =>
      ref.read(memberPaneVisibleProvider.notifier).state = false;

  /// A tap on someone's cursor follows them instead of selecting under it.
  bool _followCursorAt(Offset world) {
    final reach = _cursorTapReachPx / _document.camera.zoom;
    final hit = _cursors.all
        .where((c) => (Offset(c.x, c.y) - world).distance <= reach)
        .firstOrNull;
    if (hit == null) return false;
    final relay = _engine.viewRelay;
    relay.following.value == hit.id
        ? relay.stopFollowing()
        : relay.follow(hit.id);
    return true;
  }

  void _onSelectStart(Offset world) {
    if (_editingNoteId == null && !_boardFocusNode.hasPrimaryFocus) {
      _boardFocusNode.requestFocus();
    }
    _selectedBeforeDown = _document.selectedObjectId.value;
    final me = ref.read(meProvider).valueOrNull;
    // A safe read, not a cold one: build() already watches this same family instance every frame.
    final manageCanvas = ref
        .read(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageCanvas);
    _ops.beginSelect(
      world,
      manageCanvas: manageCanvas,
      selfId: me?.id,
      touch: AppTouchTargets.of(context) || _fingerReach,
    );
    // Nothing to move or resize under the pointer: the pan tool pans, with one finger too.
    if (_ops.activeMove == null) _dragPan.begin(world);
  }

  /// Images keep their aspect and notes or shapes resize freely; Shift flips either, Alt moves freely, touch always snaps.
  /// Read on every drag point so releasing a key mid-drag takes effect at once.
  void _onSelectDrag(Offset world) {
    if (_dragPan.active) {
      _dragPan.drag(world, _document);
      // A stroke is selected by a tap; a drag across it is a pan.
      if (_dragPan.moving) _document.selectedObjectId.value = null;
      return;
    }
    _ops.dragSelect(
      world,
      lockAspect: _aspectLocked(
        flipped: HardwareKeyboard.instance.isShiftPressed,
      ),
      snap: !HardwareKeyboard.instance.isAltPressed,
    );
    if (_ops.activeMove case final move?) {
      _objectPreview.reportLocal(move.id, move.box);
    }
  }

  bool _aspectLocked({required bool flipped}) {
    final id = _document.selectedObjectId.value;
    final isImage =
        id != null && _document.kindOf(id) == CanvasObjectKind.image;
    return isImage != flipped;
  }

  Future<void> _onSelectCancel() async {
    _dragPan.end();
    final restored = _ops.cancelSelect();
    _objectPreview.endLocal(restored?.box);
    _refresh();
  }

  Future<void> _onSelectEnd() async {
    _dragPan.end();
    _objectPreview.endLocal(_ops.activeMove?.box);
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
    final manageCanvas = ref
        .read(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageCanvas);
    await _ops.deleteSelected(objectId, manageCanvas: manageCanvas);
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

  CanvasScopedClear get _scopedClear => CanvasScopedClear(
    clear: (scope) => _onClear(scope: scope),
    authorIds: _document.authorIds,
  );

  Future<void> _onClear({
    api.CanvasClearScope scope = api.CanvasClearScope.everything,
  }) async {
    // Fenced on the newest head this client can read; a stale one would leave later ink standing.
    final fence = await _sync.fenceHead();
    if (fence == null) {
      _engine.reportError('The canvas could not be cleared.');
      return;
    }
    await _ops.clear(fence, scope: scope);
    _refresh();
  }

  Future<void> _onBringIntoBoard() async {
    final manageCanvas = ref
        .read(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageCanvas);
    final result = await _ops.bringIntoBoard(
      manageCanvas: manageCanvas,
      selfId: ref.read(meProvider).valueOrNull?.id,
    );
    // The undo entry lands after the document's own refresh, so the dock's Undo needs this rebuild.
    _refresh();
    if (result.moved == 0 &&
        !result.failed &&
        _mounted &&
        _document.idsOutsideBoard.isNotEmpty) {
      _engine.reportError(
        result.locked > 0
            ? 'Unlock the objects to bring them in.'
            : 'You can only bring in objects you placed.',
      );
    }
    if (result.moved > 0) _engine.hydrator.hydrateVisible();
    if (_mounted) _refresh();
  }

  /// Fits the camera to what is drawn, or the whole board when the canvas is empty.
  void _onRecenter() => _document.fitContent();

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
    final width = canvasPenWorldWidth(_pen.width, _document.camera.zoom);
    final segments = splitStroke(worldPoints);
    // The pieces of one long stroke share a group, so erasing one takes the whole mark.
    final group = segments.length > 1 ? newCanvasObjectId() : null;
    for (final segment in segments) {
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
          width: width,
          colorKey: _pen.colorKey,
          authorId: selfId,
          groupId: group,
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
            'width': width,
            'color': _pen.colorKey,
            'group': ?group,
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
    _ops.onErasePoint(
      world,
      manageCanvas: manageCanvas,
      selfId: me?.id,
      touch: AppTouchTargets.of(context) || _fingerReach,
    );
  }

  Future<void> _onEraseEnd() async {
    await _ops.endErase();
    _refresh();
  }

  Future<void> _onEraseCancel() async {
    _ops.cancelErase();
    _refresh();
  }
}
