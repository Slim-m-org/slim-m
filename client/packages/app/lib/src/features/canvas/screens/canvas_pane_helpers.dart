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
  CanvasObjectPreviewRelay get _objectPreview => _engine.objectPreviewRelay;

  CanvasImagePaste get _imagePaste => _imagePasteHelper ??= CanvasImagePaste(
    client: ref.read(apiProvider),
    channelId: widget.channelId,
    document: _document,
    onPlaced: _selectPlaced,
    onError: _engine.reportError,
    timedOutUntil: () => ref.read(meProvider).valueOrNull?.timedOutUntil,
    onBitmapAttached: _engine.hydrator.adopt,
  );

  /// Picks one still image and places it at the view's centre.
  Future<void> _pickImageFile() async {
    final PlatformFile? file;
    try {
      file = await ref.read(
        attachmentPickerProvider(AttachmentSource.stillImageFiles),
      )();
    } catch (e, stack) {
      api.reportFailure(
        api.LogTag.media,
        'pick an image for the canvas',
        e,
        stack,
      );
      _engine.reportError('The file picker could not open.');
      return;
    }
    if (file == null || !_mounted) return;
    await _imagePaste.placeFile(await file.readAsBytes(), file.name);
  }

  /// Places an image dropped onto the board, or says why it was refused.
  Future<void> _dropImage(List<DropItem> items) async {
    switch (await readDroppedImage(items)) {
      case DroppedImage(:final bytes, :final name):
        if (_mounted) await _imagePaste.placeFile(bytes, name);
      case RefusedDrop(:final message):
        if (_mounted) _engine.reportError(message);
    }
  }

  /// Deletes [objectId] for good after a confirmation; the server unlocks and erases it first.
  Future<void> _onPurge(String objectId) async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Delete this for good?',
      message:
          'It is removed for everyone and cannot be brought back with Undo.',
      confirmLabel: 'Delete for good',
      cancelLabel: 'Keep it',
    );
    if (!confirmed || !_mounted) return;
    try {
      await ref.read(apiProvider).purgeCanvasObject(widget.channelId, objectId);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'purge a canvas object', e, stack);
      _engine.reportError('That could not be deleted.');
      return;
    }
    if (!_mounted || !_document.isAlive(objectId)) return;
    _document
      ..removeObject(objectId)
      ..refresh();
  }

  CanvasQuickPlacement get _quickPlacement =>
      _quickPlacementHelper ??= CanvasQuickPlacement(
        client: ref.read(apiProvider),
        channelId: widget.channelId,
        document: _document,
        timedOutUntil: () => ref.read(meProvider).valueOrNull?.timedOutUntil,
        authorId: () => ref.read(meProvider).valueOrNull?.id,
        clearedSincePlacement: _engine.sync.clearedSincePlacement,
      );

  /// What the canvas says when this device's call in the channel failed or dropped for good.
  String? _callFailure(VoiceFlags flags) =>
      flags.channelId == widget.channelId &&
          flags.state == VoiceSessionState.failed
      ? (flags.error ?? 'The call was dropped.')
      : null;
}
