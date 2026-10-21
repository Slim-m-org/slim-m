// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane_body.dart';

/// The dock data, activity panel and drawing surface [_CanvasPaneBodyState] builds.
extension _CanvasPaneBodyBuilders on _CanvasPaneBodyState {
  CanvasDockData _dockData() => CanvasDockData(
    tool: widget.tool,
    onToolChanged: widget.onToolChanged,
    // A banner already says a place would fail; pen/note/shape must not stay selectable underneath it.
    canDraw: !canvasErrorBlocksDrawing(widget.error),
    canUndo: widget.canUndo,
    onUndo: widget.onUndo,
    canRedo: widget.canRedo,
    onRedo: widget.onRedo,
    canManage: widget.canManage,
    onClear: widget.onClear,
    scopedClear: widget.scopedClear,
    onPasteImage: widget.onPasteImage,
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
    onAddNote: canvasErrorBlocksDrawing(widget.error)
        ? null
        : () => widget.onNotePlace(widget.document.worldView.center),
    onAddShape: canvasErrorBlocksDrawing(widget.error)
        ? null
        : () => widget.onShapePlace(widget.document.worldView.center, null),
    child: CanvasPaneSurface(
      actions: CanvasPaneSurfaceActions(
        onDraftEnded: widget.onDraftEnded,
        onDraftPoint: widget.onDraftPoint,
        onPointerLeft: widget.onPointerLeft,
        onPointerMoved: widget.onPointerMoved,
        onShapePlace: widget.onShapePlace,
        onNotePlace: widget.onNotePlace,
        onSelectTap: widget.onSelectTap,
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
        onPurge: widget.onPurge,
        onPasteImageAt: widget.onPasteImageAt,
        onEditNote: widget.onEditNote,
        onRecenter: widget.onRecenter,
        onBringIntoBoard: widget.onBringIntoBoard,
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
      presenceFrames: _presenceFrames,
      focusedTileKey: widget.focusedTileKey,
    ),
  );
}
