// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane.dart';

/// The tool strip, note editing, undo, clear and ink, split out of
/// `_CanvasPaneState` for the line budget; they all need its fields. The
/// Move tool's own gestures are [CanvasSelectGesture].
extension _CanvasPaneGestures on _CanvasPaneState {
  /// Leaving the select tool deselects, so the outline and its resize
  /// handles do not linger over a selection nothing can act on any more
  /// while the pen or eraser is active.
  void _onToolChanged(CanvasTool tool) {
    if (tool != CanvasTool.pan && _spectating) return;
    if (tool == CanvasTool.stamp &&
        ref.read(armedStampProvider).content == null) {
      return showBoardStampPicker(
        context,
        onPicked: () => _onToolChanged(CanvasTool.stamp),
      );
    }
    if (tool != CanvasTool.pan) _document.selectedObjectId.value = null;
    // Arming a tool by key or wheel brings the folded tools back, so what is armed shows.
    if (tool != CanvasTool.pan && ref.read(canvasToolsHiddenProvider)) {
      unawaited(ref.read(canvasToolsHiddenProvider.notifier).select(false));
    }
    // A deliberate pick stays through leaving fullscreen.
    _toolBeforeFullscreen = null;
    _refresh(() => _tool = tool);
  }

  /// Folding the tools away puts the tool down too, so a drag pans rather than drawing unseen.
  void _onToggleToolsHidden() {
    final hide = !ref.read(canvasToolsHiddenProvider);
    if (hide) _onToolChanged(CanvasTool.pan);
    unawaited(ref.read(canvasToolsHiddenProvider.notifier).select(hide));
  }

  /// Escape with a drawing tool armed: drop a half-drawn stroke or shape, else close a docked thread, else put the tool down to Pan.
  void _onEscapeTool() {
    if (_gestureController.cancelDrawing()) return;
    if (_threadPaneDocked) return _closeThreadPane();
    _onToolChanged(CanvasTool.pan);
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
    if (event.logicalKey == LogicalKeyboardKey.keyF &&
        _focusedTileKey != null) {
      _focusTile(null);
      return KeyEventResult.handled;
    }
    for (final tool in canvasToolOrder) {
      if (tool.shortcutKey != event.logicalKey) continue;
      if (!tool.isAvailable(canDraw: canDraw)) return KeyEventResult.ignored;
      if (tool == CanvasTool.stamp &&
          !ref.read(canvasStampsSupportedProvider)) {
        return KeyEventResult.ignored;
      }
      _onToolChanged(tool);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Opens the note sheet and places the note only once it comes back with
  /// text; a cancelled or blank sheet sends and shows nothing.
  Future<void> _onNotePlace(Offset world, [Size? draggedSize]) async {
    if (_spectating) return;
    final startedWith = _tool;
    var text = await showCanvasNoteSheet(context);
    if (!_mounted) return;
    _boardFocusNode.requestFocus();
    while (text != null && _mounted) {
      final placed = await _quickPlacement.placeNote(
        world,
        text,
        draggedSize: draggedSize,
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

  /// Places a shape of the picked kind at once and selects it; the tool stays
  /// armed so several can be drawn in a row (see `CanvasSurface.grabsHandleAt`).
  Future<void> _onShapePlace(
    Offset world,
    Size? draggedSize, {
    bool flipX = false,
    bool flipY = false,
  }) async {
    if (_spectating) return;
    final startedWith = _tool;
    final placed = await _quickPlacement.placeShape(
      world,
      _shapeKind,
      draggedSize: draggedSize,
      flipX: flipX,
      flipY: flipY,
      onError: _engine.reportError,
    );
    if (placed != null) {
      _selectPlaced(placed.id, startedWith: startedWith, keepTool: true);
    }
  }

  /// After placing a new object the thing just made is the thing selected,
  /// with its resize handles live. A note or pasted image also switches to
  /// the Pan tool; a shape ([keepTool]) leaves its tool armed for the next one.
  void _selectPlaced(
    String objectId, {
    CanvasTool? startedWith,
    bool keepTool = false,
  }) {
    if (!_mounted) return;
    // Undoable like a stroke: placing is an edit, and Ctrl+Z must take it back.
    _ops.recordDraw([objectId]);
    // A reply that lands after the person moved on must not change what they are doing.
    if (_pointersDown > 0 || (startedWith != null && _tool != startedWith)) {
      return;
    }
    _document.selectedObjectId.value = objectId;
    _refresh(() {
      if (!keepTool) _tool = CanvasTool.pan;
    });
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

  /// Opens the in-place editor, unless the note is locked or the canvas is
  /// refusing writes; the select tool and the menu only ever offer notes this
  /// person may edit.
  void _onEditNote(String id) {
    final error = ref.read(canvasEngineProvider(widget.channelId)).error;
    if (_spectating || _ops.isLocked(id) || canvasErrorBlocksDrawing(error)) {
      return;
    }
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
      mentionNames: ref.watch(mentionNamesProvider),
    );
  }

  /// Whether the roster is docked beside the canvas, as the shell decides it.
  bool get _memberPaneDocked =>
      !_threadPaneDocked &&
      memberPaneWanted(ref, MediaQuery.sizeOf(context)) &&
      LayoutClass.of(context).fitsMemberPane(MediaQuery.sizeOf(context).width);

  bool get _threadPaneDocked =>
      dockedThreadBeside(ref.read(dockedThreadsProvider), widget.channelId) !=
          null &&
      LayoutClass.of(context).fitsThreadPane(MediaQuery.sizeOf(context).width);

  void _closeThreadPane() => closeDockedThread(
    ref.read(dockedThreadsProvider.notifier),
    widget.channelId,
  );

  void _closeMemberPane() =>
      ref.read(memberPaneVisibleProvider.notifier).state = false;

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

  /// Delete/Backspace over the current Move-tool selection, the desktop convention.
  void _onDeleteKey() {
    final selected = _document.selectedObjectId.value;
    if (selected != null) unawaited(_onDeleteSelected(selected));
  }

  /// A spectator's pointer is not relayed: the server only relays one that may draw.
  void _onPointerMoved(Offset world) {
    if (!_spectating) _relay.reportLocalPointer(world);
  }

  /// Draws a local stroke at once - optimistic on [_document], queued for
  /// the server through [_commits] - and records it as one undoable gesture
  /// regardless of how many segments [splitStroke] broke it into.
  void _onStroke(List<Offset> worldPoints) {
    if (_spectating || _drawingRefused) return;
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
    if (_spectating) return;
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
