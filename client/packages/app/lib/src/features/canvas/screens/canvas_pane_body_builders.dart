// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane_body.dart';

/// The dock data, activity panel and drawing surface [_CanvasPaneBodyState] builds.
extension _CanvasPaneBodyBuilders on _CanvasPaneBodyState {
  CanvasDockData _dockData() => CanvasDockData(
    tool: widget.tool,
    onToolChanged: widget.onToolChanged,
    // A banner already says a place would fail; pen/note/shape must not stay selectable underneath it.
    canDraw: _canDraw,
    canUndo: widget.canUndo,
    onUndo: widget.onUndo,
    canRedo: widget.canRedo,
    onRedo: widget.onRedo,
    canManage: widget.canManage,
    onClear: widget.onClear,
    scopedClear: widget.scopedClear,
    onAddImageFile: widget.onAddImageFile,
    selection: widget.document.selectedObjectId,
    onBringToFront: widget.onBringToFront,
    onSendToBack: widget.onSendToBack,
    onDeleteSelected: widget.onDeleteSelected,
    activityLogOpen: _activityLogOpen,
    onToggleActivityLog: _toggleActivityLog,
    shapeKind: widget.shapeKind,
    onShapeKindChanged: widget.onShapeKindChanged,
    pen: widget.pen,
    onPenChanged: widget.onPenChanged,
    onClose: widget.onClose,
    hasSelfBubble: _hasSelfBubble,
    selfBubbleHidden: widget.selfBubbleHidden,
    onToggleSelfBubbleHidden: widget.onToggleSelfBubbleHidden,
    hiddenTiles: hiddenCanvasTiles(
      participants: widget.callParticipants,
      overrides: widget.tileOverrides,
    ),
    onShowTile: (key) => widget.tileOverrides.setHidden(key, false),
    fullscreen: widget.fullscreen,
    onToggleFullscreen: widget.onToggleFullscreen,
    toolsHidden: widget.toolsHidden,
    onToggleToolsHidden: widget.onToggleToolsHidden,
    readOnly: widget.readOnly,
  );

  /// Rebuilds on `document.objectCount`, the same trigger `_surface` uses, so the summary does not freeze at the count it read when opened.
  Widget _panel() => ValueListenableBuilder<int>(
    valueListenable: widget.document.objectCount,
    builder: (context, count, child) => CanvasActivityPanel(
      activityLog: widget.activityLog,
      summary: canvasSummary(widget.document),
      objectCount: count,
    ),
  );

  Widget _surface(AppTokens tokens) => CanvasSurfaceStatus(
    document: widget.document,
    tokens: tokens,
    loading: widget.loading,
    hasError: widget.error != null,
    hasCallParticipants: widget.callParticipants.isNotEmpty,
    onAddNote: _canDraw
        ? () => widget.onNotePlace(widget.document.worldView.center)
        : null,
    onAddShape: _canDraw
        ? () => widget.onShapePlace(widget.document.worldView.center, null)
        : null,
    onShowActivityLog: _toggleActivityLog,
    child: CanvasPaneSurface(
      actions: CanvasPaneSurfaceActions(
        onDraftEnded: widget.onDraftEnded,
        onDraftCancel: widget.onDraftCancel,
        gestureController: widget.gestureController,
        onDraftPoint: widget.onDraftPoint,
        onPointerLeft: widget.onPointerLeft,
        onPointerMoved: widget.onPointerMoved,
        onShapePlace: widget.onShapePlace,
        stamping: widget.stamping,
        onNotePlace: widget.onNotePlace,
        onTextPlace: widget.onTextPlace,
        onSelectLongPress: widget.onSelectLongPress,
        onSelectTap: widget.onSelectTap,
        grabsHandleAt: widget.grabsHandleAt,
        onSelectEnd: widget.onSelectEnd,
        onSelectDrag: widget.onSelectDrag,
        onSelectStart: widget.onSelectStart,
        onEraseEnd: widget.onEraseEnd,
        onEraseCancel: widget.onEraseCancel,
        onSelectCancel: widget.onSelectCancel,
        onErase: widget.onErase,
        onStroke: widget.onStroke,
        onCommitTile: widget.onCommitTile,
        onVideoInterest: widget.onVideoInterest,
        onBringToFront: widget.onBringToFront,
        onSendToBack: widget.onSendToBack,
        onDeleteSelected: widget.onDeleteSelected,
        onEditNote: widget.onEditNote,
        onRecenter: widget.onRecenter,
        onToolChanged: widget.onToolChanged,
        onBringIntoBoard: widget.onBringIntoBoard,
        onShowActivityLog: _toggleActivityLog,
        onFocusTile: widget.onFocusTile,
        participantMenuItemsBuilder: widget.participantMenuItemsBuilder,
        cameraViewFor: widget.cameraViewFor,
        screenShareViewFor: widget.screenShareViewFor,
      ),
      callParticipants: widget.callParticipants,
      canManage: widget.canManage,
      cursorColors: widget.cursorColors,
      cursors: widget.cursors,
      document: widget.document,
      error: widget.error,
      truncated: widget.truncated,
      noteEditor: widget.noteEditor,
      noteSpans: widget.noteSpans,
      noteSpansRevision: widget.noteSpansRevision,
      pen: widget.pen,
      remoteDrafts: widget.remoteDrafts,
      selfBubbleHidden: widget.selfBubbleHidden,
      selfId: widget.selfId,
      shapeKind: widget.shapeKind,
      tileOverrides: widget.tileOverrides,
      viewMode: widget.viewMode,
      tool: widget.tool,
      tokens: tokens,
      menuRequests: _menuRequests,
      toolWheel: _toolWheel,
      presenceFrames: _presenceFrames,
      focusedTileKey: widget.focusedTileKey,
      boardFocusNode: widget.boardFocusNode,
      readOnly: widget.readOnly,
    ),
  );

  bool get _canDraw =>
      !widget.readOnly && !canvasErrorBlocksDrawing(widget.error);
}
