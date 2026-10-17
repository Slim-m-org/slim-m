// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane.dart';

/// The helper objects `_CanvasPaneState` hands its child widgets: split out
/// once the floating call dock's own wiring pushed `canvas_pane.dart` to the
/// 500-line hard limit, the same reason `_CanvasPaneGestures` already lives
/// in its own `part of` file rather than as a second class - these all need
/// `_CanvasPaneState`'s own fields.
///
/// `_document`, `_cursors`, `_remoteDrafts`, `_activityLog`,
/// `_tileOverrides`, `_slotSync`, `_sync`, `_commits` and `_ops` are every
/// one of them a thin forward onto [canvasEngineProvider]'s own notifier now
/// - this pane owns none of them directly any more, only the two helpers
/// below that are genuinely its own (a note sheet to await, a keystroke to
/// register).
extension _CanvasPaneHelpers on _CanvasPaneState {
  CanvasDocument get _document => _engine.document;
  CanvasCursors get _cursors => _engine.cursors;
  RemoteStrokeDrafts get _remoteDrafts => _engine.remoteDrafts;
  CanvasActivityLog get _activityLog => _engine.activityLog;
  CanvasPresenceTileOverrides get _tileOverrides => _engine.tileOverrides;
  CanvasMediaSlotSync get _slotSync => _engine.slotSync;
  CanvasSync get _sync => _engine.sync;
  CanvasCommitQueue get _commits => _engine.commits;
  CanvasOpsController get _ops => _engine.ops;
  CanvasCursorRelay get _relay => _engine.cursorRelay;
  CanvasStrokePreviewRelay get _strokePreview => _engine.strokePreviewRelay;

  CanvasImagePaste get _imagePaste => _imagePasteHelper ??= CanvasImagePaste(
    client: ref.read(apiProvider),
    channelId: widget.channelId,
    document: _document,
    onPlaced: _selectPlaced,
    onError: _engine.reportError,
    timedOutUntil: () => ref.read(meProvider).valueOrNull?.timedOutUntil,
  );

  CanvasQuickPlacement get _quickPlacement =>
      _quickPlacementHelper ??= CanvasQuickPlacement(
        client: ref.read(apiProvider),
        channelId: widget.channelId,
        document: _document,
        timedOutUntil: () => ref.read(meProvider).valueOrNull?.timedOutUntil,
      );
}
