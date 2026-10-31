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

  /// The tiles of blocked callers, kept in the default layout so blocking someone moves nobody else's slot.
  Set<String> _blockedTileKeys() {
    final channelId = ref.watch(voiceFlagsProvider.select((f) => f.channelId));
    if (channelId != widget.channelId) return const {};
    final blocks = ref.watch(blocksProvider);
    return presenceTileKeys([
      for (final p
          in ref
              .watch(
                voiceParticipantsProvider.select(CanvasCallParticipants.new),
              )
              .participants)
        if (blocks.contains(p.identity)) p,
    ]);
  }

  /// Who to show as a camera or share bubble: nobody unless this device joined a call in this channel, since without one there is no LiveKit room to render from.
  List<VoiceParticipant> _callParticipants() {
    final channelId = ref.watch(voiceFlagsProvider.select((f) => f.channelId));
    if (channelId != widget.channelId) return const [];
    final blocks = ref.watch(blocksProvider);
    final stoppedShares = ref.watch(
      shareWatchProvider.select((w) => w.stopped),
    );
    final participants = ref
        .watch(voiceParticipantsProvider.select(CanvasCallParticipants.new))
        .participants;
    return [
      for (final p in participants)
        if (!blocks.contains(p.identity))
          if (p.isScreenSharing &&
              !p.isLocal &&
              stoppedShares.contains(p.identity))
            p.copyWith(isScreenSharing: false)
          else
            p,
    ];
  }
}

/// The call participants as the canvas sees them: equal whenever nothing but
/// a speaking flag or level moved, since the tiles draw neither (speaking is
/// the cursor label's glow and the dock roster's ring) and rebuilding the
/// whole pane several times a second per speaker made it lag.
@visibleForTesting
class CanvasCallParticipants {
  const CanvasCallParticipants(this.participants);

  final List<VoiceParticipant> participants;

  static bool _same(VoiceParticipant a, VoiceParticipant b) =>
      a.identity == b.identity &&
      a.name == b.name &&
      a.isMuted == b.isMuted &&
      a.isDeafened == b.isDeafened &&
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
