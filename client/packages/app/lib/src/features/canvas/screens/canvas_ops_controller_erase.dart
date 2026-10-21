// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_ops_controller.dart';

/// The eraser's sweep and its batched removal, and the clear that empties the board.
extension CanvasOpsControllerErase on CanvasOpsController {
  /// Erases the topmost ink or shape under [world] the caller is allowed to
  /// erase - their own always, or anybody's with [manageCanvas] - and
  /// removes it from view at once. Scoped at hit-test time so a drag
  /// visibly picks up nothing it cannot touch, rather than sending a
  /// request the server would refuse anyway. Fires on pointer-down and every
  /// move; [endErase] is what submits the whole drag as one op.
  void onErasePoint(
    Offset world, {
    required bool manageCanvas,
    required String? selfId,
    bool touch = false,
  }) {
    final from = _lastErase;
    _lastErase = world;
    for (final point in _sweepPoints(from, world)) {
      _eraseAt(point, manageCanvas: manageCanvas, selfId: selfId, touch: touch);
    }
  }

  /// The samples a pointer crossed between two events, so a fast sweep
  /// cannot step over a thin stroke the way sampling only its endpoints does.
  static Iterable<Offset> _sweepPoints(Offset? from, Offset to) {
    if (from == null) return [to];
    final steps = ((to - from).distance / _sweepStepPx).ceil().clamp(1, 64);
    return [for (var i = 1; i <= steps; i++) Offset.lerp(from, to, i / steps)!];
  }

  void _eraseAt(
    Offset world, {
    required bool manageCanvas,
    required String? selfId,
    required bool touch,
  }) {
    // Legacy content past the board is hidden by its clip, so a press there must not reach it.
    if (!document.acceptsPlacementAt(world)) return;
    bool allowed(CanvasStroke stroke) =>
        !isLocked(stroke.id) &&
        (manageCanvas ||
            (stroke.authorId != null && stroke.authorId == selfId));
    final id = hitTestTopmost(
      document,
      world,
      touch: touch,
      allowed: allowed,
      accepts: CanvasOpsController._isInk,
    );
    if (id == null || _dragBatch.contains(id)) return;
    // A long stroke was saved in pieces; the whole mark goes with the one touched.
    for (final member in document.groupOf(id)) {
      final author = document.authorIdOf(member);
      final mine = manageCanvas || (author != null && author == selfId);
      if (isLocked(member) || !mine || !_dragBatch.add(member)) continue;
      document.removeObject(member);
    }
    document.refresh();
    if (_dragBatch.length >= maxRemoveIdsPerOp) unawaited(_flushErase());
  }

  /// Submits whatever the drag collected, so undoing an erase drag is atomic
  /// per op. Every id here was alive at hit-test time and has already been
  /// removed from view; this only decides whether that also needs cancelling
  /// from the placement queue - a self-drawn id not yet confirmed - or an
  /// ordinary op, which is everything else.
  Future<void> endErase() {
    _lastErase = null;
    return _flushErase();
  }

  Future<void> _flushErase() async {
    if (_dragBatch.isEmpty) return;
    final ids = _dragBatch.toList(growable: false);
    _dragBatch.clear();
    final immediate = <String>[
      for (final id in ids)
        if (commits.undoPlacement(id) == UndoPlacementOutcome.unresolved) id,
    ];
    if (immediate.isEmpty) return;
    final removed = await _submitRemove(immediate);
    if (removed.opIds.isNotEmpty) {
      _pushUndo(_EraseEntry(removed.opIds, immediate));
    }
  }

  /// The erase pointer was cancelled by the system: what it hid comes back from the server and nothing is removed.
  void cancelErase() {
    if (_dragBatch.isEmpty) return;
    final ids = _dragBatch.toList(growable: false);
    _dragBatch.clear();
    document.forgetRemoved(ids);
    unawaited(onRemoveFailed?.call());
  }

  /// Clears every object placed at or before [beforeSeq] - see
  /// `CanvasSync.asOfSeq` for why that is the right fencing token - and
  /// records the resulting op so [undo] can restore it. Returns whether the
  /// request itself succeeded, so the caller can decide what to show; a
  /// clear that touched nothing still succeeds and pushes no undo entry.
  Future<bool> clear(
    int beforeSeq, {
    api.CanvasClearScope scope = api.CanvasClearScope.everything,
  }) async {
    try {
      final result = await _sendOp(
        (id) => client.submitCanvasOp(
          channelId,
          id: id,
          kind: scope.isEverything ? 'clear' : 'clear_scoped',
          beforeSeq: beforeSeq,
          clearScope: scope,
        ),
      );
      // The clear's own frame removes the objects: it names the locked ones the server spared, which this reply does not.
      if (result.op.affected > 0) {
        _pushUndo(_EraseEntry([result.op.id]));
      }
      return true;
    } on api.BadRequestException {
      onError(
        scope.isEverything
            ? 'The canvas could not be cleared.'
            : 'This server cannot clear by type yet.',
      );
      return false;
    } on api.ApiException {
      onError('The canvas could not be cleared.');
      return false;
    }
  }
}
