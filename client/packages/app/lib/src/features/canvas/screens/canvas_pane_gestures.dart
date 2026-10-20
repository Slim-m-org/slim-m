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
    _refresh(() => _tool = tool);
  }

  CanvasTool get _defaultTool => canvasDefaultTool();

  /// Arms the tool whose key [event] is, unless its button is absent or disabled, or a text field is taking the key.
  KeyEventResult _onToolKey(KeyEvent event, {required bool canDraw}) {
    final keyboard = HardwareKeyboard.instance;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
    // Undoable like a stroke: placing is an edit, and Ctrl+Z must take it back.
    _ops.recordDraw([objectId]);
    _document.selectedObjectId.value = objectId;
    _refresh(() => _tool = CanvasTool.pan);
  }

  /// Undo, redo, paste and delete over the canvas's own selection.
  Map<ShortcutActivator, VoidCallback> _canvasEditShortcuts() => {
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
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
        unawaited(_imagePaste.pasteFromKeystroke()),
    const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
        unawaited(_imagePaste.pasteFromKeystroke()),
    const SingleActivator(LogicalKeyboardKey.delete): _onDeleteKey,
    const SingleActivator(LogicalKeyboardKey.backspace): _onDeleteKey,
  };

  /// How soon a second click on a note makes a double click.
  static const _doubleClickWindow = Duration(milliseconds: 400);

  /// A finished select gesture that never became a drag: a double click with
  /// a mouse, or a single tap with a finger or a pen, on the selected note.
  void _onSelectTap(Offset world, PointerDeviceKind kind) {
    final id = _document.selectedObjectId.value;
    final bounds = id == null ? null : _document.objectBounds(id);
    final onNote =
        id != null &&
        bounds != null &&
        _document.kindOf(id) == CanvasObjectKind.note &&
        Rect.fromLTWH(bounds.x, bounds.y, bounds.w, bounds.h).contains(world);
    if (!onNote) {
      _lastNoteClick = null;
      return;
    }
    if (kind == PointerDeviceKind.mouse) {
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
    await _ops.editNote(id, text);
    _refresh();
  }

  void _onNoteEditCancel() => _refresh(() => _editingNoteId = null);

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
      memberPaneWanted(ref, MediaQuery.sizeOf(context)) &&
      LayoutClass.of(context).fitsMemberPane(MediaQuery.sizeOf(context).width);

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
    if (_followCursorAt(world)) return;
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
    // Nothing of yours under the pointer: the pan tool pans, with one finger too.
    if (_document.selectedObjectId.value == null) _dragPan.begin(world);
  }

  /// Aspect locks by default; holding Shift frees it. Read fresh on every
  /// drag point rather than once at [_onSelectStart], so releasing the key
  /// mid-drag takes effect immediately rather than on the next gesture.
  /// Alt moves freely; touch has no modifier, so it always snaps.
  void _onSelectDrag(Offset world) {
    if (_dragPan.active) return _dragPan.drag(world, _document);
    _ops.dragSelect(
      world,
      lockAspect: !HardwareKeyboard.instance.isShiftPressed,
      snap: !HardwareKeyboard.instance.isAltPressed,
    );
    if (_ops.activeMove case final move?) {
      _objectPreview.reportLocal(move.id, move.box);
    }
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

  CanvasScopedClear get _scopedClear => CanvasScopedClear(
    clear: (scope) => _onClear(scope: scope),
    authorIds: _document.authorIds,
  );

  Future<void> _onClear({
    api.CanvasClearScope scope = api.CanvasClearScope.everything,
  }) async {
    // Fenced on the newest head this client can read; a stale one would leave later ink standing.
    await _sync.catchUp();
    final fence = _sync.asOfSeq;
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
    if (result.moved == 0 &&
        !result.failed &&
        _mounted &&
        _document.idsOutsideBoard.isNotEmpty) {
      _engine.reportError('You can only bring in objects you placed.');
    }
  }

  /// Brings the whole shared board back into view.
  void _onRecenter() => _document.fitBoard();

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
          width: width,
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
            'width': width,
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
    _ops.onErasePoint(
      world,
      manageCanvas: manageCanvas,
      selfId: me?.id,
      touch: AppTouchTargets.of(context),
    );
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
    final participants = ref
        .watch(voiceParticipantsProvider.select(CanvasCallParticipants.new))
        .participants;
    return participants
        .where((p) => !blocks.contains(p.identity))
        .toList(growable: false);
  }
}

/// The call participants as the canvas sees them: equal whenever nothing but
/// a speaking level moved, since the canvas draws no level and rebuilding the
/// whole pane several times a second per speaker made it lag.
@visibleForTesting
class CanvasCallParticipants {
  const CanvasCallParticipants(this.participants);

  final List<VoiceParticipant> participants;

  static bool _same(VoiceParticipant a, VoiceParticipant b) =>
      a.identity == b.identity &&
      a.name == b.name &&
      a.isSpeaking == b.isSpeaking &&
      a.isMuted == b.isMuted &&
      a.isLocal == b.isLocal &&
      a.isScreenSharing == b.isScreenSharing &&
      a.isCameraOn == b.isCameraOn;

  @override
  bool operator ==(Object other) {
    if (other is! CanvasCallParticipants) return false;
    final a = participants;
    final b = other.participants;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(participants.map((p) => p.identity));
}
