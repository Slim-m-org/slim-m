// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_ops_controller.dart';

/// One object's box in a grouped move.
class _MoveStep {
  const _MoveStep(this.objectId, this.x, this.y, this.w, this.h);

  final String objectId;
  final double x;
  final double y;
  final double w;
  final double h;
}

/// Several moves undone together; [from] holds the boxes to go back to.
class _MoveGroupEntry extends _UndoEntry {
  _MoveGroupEntry(this.from);

  final List<_MoveStep> from;
}

/// The boxes an undone group left, which a redo moves back to.
class _RedoMoveGroup extends _RedoEntry {
  _RedoMoveGroup(this.to);

  final List<_MoveStep> to;
}

/// Several objects picked up together: each one's box when the drag began, and the press that began it.
class _GroupDragState {
  _GroupDragState(this.from, this.anchor);

  final Map<String, ObjectBox> from;
  final Offset anchor;
  Offset delta = Offset.zero;
}

/// Pause between bring-in requests, so a big batch does not trip the rate limit.
const Duration _bringInPace = Duration(milliseconds: 60);

extension CanvasOpsControllerGroup on CanvasOpsController {
  /// Moves every object the caller may move back onto the board, stopping at the first refusal, as one undo step.
  /// Returns how many moved, how many were locked, and whether a request failed ([onError] has already told the viewer).
  Future<({int moved, int locked, bool failed})> bringIntoBoard({
    required bool manageCanvas,
    required String? selfId,
  }) async {
    final done = <_MoveStep>[];
    var locked = 0;
    var failed = false;
    for (final id in document.idsOutsideBoard.toList()) {
      if (_disposed) break;
      final from = document.objectBounds(id);
      final mine =
          manageCanvas || (selfId != null && document.authorIdOf(id) == selfId);
      if (from == null || !mine) continue;
      if (isLocked(id)) {
        locked++;
        continue;
      }
      final to = document.boxOnBoard(id, from.x, from.y, from.w, from.h);
      if (to == from) continue;
      document.moveObject(id, to.x, to.y, to.w, to.h);
      final ok = await _commitBounds(
        id,
        from,
        to,
        'That could not be moved.',
        record: false,
      );
      if (!ok) {
        failed = true;
        break;
      }
      done.add(_MoveStep(id, from.x, from.y, from.w, from.h));
      await Future<void>.delayed(_bringInPace);
    }
    document.refresh();
    if (done.isNotEmpty) _pushUndo(_MoveGroupEntry(done));
    return (moved: done.length, locked: locked, failed: failed);
  }

  Future<_RedoEntry?> _undoMoveGroup(List<_MoveStep> steps) async {
    final redone = <_MoveStep>[];
    final remaining = <_MoveStep>[];
    for (final step in steps) {
      _history.clearGone();
      final before = await _moveTo(
        step.objectId,
        step.x,
        step.y,
        step.w,
        step.h,
        'undone',
      );
      if (before == null) {
        if (!_history.entryGone) remaining.add(step);
      } else {
        redone.add(
          _MoveStep(step.objectId, before.x, before.y, before.w, before.h),
        );
      }
    }
    _history.clearGone();
    // A retry only repeats the steps that did not land.
    steps
      ..clear()
      ..addAll(remaining);
    if (remaining.isEmpty && redone.isEmpty) return const _Skipped();
    return remaining.isEmpty ? _RedoMoveGroup(redone) : null;
  }

  Future<_UndoEntry?> _redoMoveGroup(List<_MoveStep> steps) async {
    final undone = <_MoveStep>[];
    final remaining = <_MoveStep>[];
    for (final step in steps) {
      _history.clearGone();
      final before = await _moveTo(
        step.objectId,
        step.x,
        step.y,
        step.w,
        step.h,
        'redone',
      );
      if (before == null) {
        if (!_history.entryGone) remaining.add(step);
      } else {
        undone.add(
          _MoveStep(step.objectId, before.x, before.y, before.w, before.h),
        );
      }
    }
    _history.clearGone();
    steps
      ..clear()
      ..addAll(remaining);
    if (remaining.isEmpty && undone.isEmpty) {
      _history.markGone();
      return null;
    }
    return remaining.isEmpty ? _MoveGroupEntry(undone) : null;
  }

  /// Deletes [ids] for good, a whole mark at a time, as one undo step; a locked one is passed over unless [manageCanvas].
  Future<void> deleteObjects(
    Iterable<String> ids, {
    bool manageCanvas = false,
  }) async {
    bool pinned(String id) => !manageCanvas && isLocked(id);
    final members = <String>{};
    for (final id in ids) {
      final mark = document.groupOf(id);
      members.addAll(mark.length > 1 ? mark : [id]);
    }
    final immediate = <String>[];
    for (final member in members.where((id) => !pinned(id))) {
      switch (commits.undoPlacement(member)) {
        case UndoPlacementOutcome.cancelled:
          document.kill(member);
        case UndoPlacementOutcome.armed:
          document.removeObject(member);
        case UndoPlacementOutcome.unresolved:
          document.removeObject(member);
          immediate.add(member);
      }
    }
    document.refresh();
    if (immediate.isEmpty) return;
    final purged = await _purge(immediate, 'That could not be deleted.');
    if (purged.rows.isNotEmpty) _pushUndo(_PurgeEntry(purged.rows));
  }

  /// Picks up every one of [ids] this person may move, to be dragged by [dragSelect]; false when none can be.
  bool beginGroupDrag(
    Offset world,
    Iterable<String> ids, {
    required bool manageCanvas,
    required String? selfId,
  }) {
    final from = _movableBoxes(ids, manageCanvas, selfId);
    if (from.isEmpty) return false;
    _groupDrag = _GroupDragState(from, world);
    return true;
  }

  /// The boxes of those of [ids] this person may move: not locked, not ink, and theirs unless [manageCanvas].
  Map<String, ObjectBox> _movableBoxes(
    Iterable<String> ids,
    bool manageCanvas,
    String? selfId,
  ) {
    final boxes = <String, ObjectBox>{};
    for (final id in ids) {
      final bounds = document.objectBounds(id);
      final mine = manageCanvas || document.authorIdOf(id) == selfId;
      if (bounds == null || !mine || isLocked(id)) continue;
      if (document.kindOf(id) == CanvasObjectKind.stroke) continue;
      boxes[id] = bounds;
    }
    return boxes;
  }

  /// Aligns or distributes the movable members of [ids] as one undo step; the ones it leaves where they are send nothing.
  Future<void> alignObjects(
    Iterable<String> ids,
    CanvasAlign mode, {
    required bool manageCanvas,
    required String? selfId,
  }) async {
    final from = _movableBoxes(ids, manageCanvas, selfId);
    final to = alignBoxes(from, mode);
    for (final MapEntry(:key, :value) in to.entries) {
      final box = document.boxOnBoard(key, value.x, value.y, value.w, value.h);
      if (box == from[key]) continue;
      document.moveObject(key, box.x, box.y, box.w, box.h);
    }
    document.refresh();
    await _commitMoves(from);
  }

  void _dragGroup(Offset world, {bool lockAxis = false}) {
    final drag = _groupDrag!;
    var delta = world - drag.anchor;
    if (lockAxis) delta = _alongLongerAxis(delta);
    final board = document.board;
    if (board != null) delta = _keptOnBoard(drag, delta, board);
    drag.delta = delta;
    for (final MapEntry(:key, :value) in drag.from.entries) {
      document.moveObject(
        key,
        value.x + delta.dx,
        value.y + delta.dy,
        value.w,
        value.h,
      );
    }
    document.refresh();
  }

  /// The drag [delta], held so the group's joint box stays inside [board] and the members keep their places relative to each other.
  Offset _keptOnBoard(_GroupDragState drag, Offset delta, Rect board) {
    final joint = drag.from.values
        .map((b) => Rect.fromLTWH(b.x, b.y, b.w, b.h))
        .reduce((a, b) => a.expandToInclude(b));
    double held(double d, double lo, double hi) =>
        lo > hi ? 0 : d.clamp(lo, hi).toDouble();
    return Offset(
      held(delta.dx, board.left - joint.left, board.right - joint.right),
      held(delta.dy, board.top - joint.top, board.bottom - joint.bottom),
    );
  }

  void _cancelGroupDrag() {
    final drag = _groupDrag!;
    _groupDrag = null;
    for (final MapEntry(:key, :value) in drag.from.entries) {
      document.moveObject(key, value.x, value.y, value.w, value.h);
    }
    document.refresh();
  }

  Future<void> _commitGroupDrag() async {
    final drag = _groupDrag!;
    _groupDrag = null;
    if (drag.delta == Offset.zero) return;
    await _commitMoves(drag.from);
  }

  /// Sends the move of each of [from] that now sits elsewhere, one after another, and records the ones that landed as one undo step.
  Future<void> _commitMoves(Map<String, ObjectBox> from) async {
    final done = <_MoveStep>[];
    for (final MapEntry(:key, :value) in from.entries) {
      final to = document.objectBounds(key);
      if (to == null || to == value) continue;
      final ok = await _commitBounds(
        key,
        value,
        to,
        'That could not be moved.',
        record: false,
      );
      if (!ok) {
        _cancelRest(from, done);
        break;
      }
      done.add(_MoveStep(key, value.x, value.y, value.w, value.h));
    }
    if (done.isNotEmpty) _pushUndo(_MoveGroupEntry(done));
  }

  /// Puts back the members a failed commit never reached, so the board matches the server.
  void _cancelRest(Map<String, ObjectBox> from, List<_MoveStep> done) {
    final sent = done.map((s) => s.objectId).toSet();
    for (final MapEntry(:key, :value) in from.entries) {
      if (sent.contains(key)) continue;
      document.moveObject(key, value.x, value.y, value.w, value.h);
    }
    document.refresh();
  }

  /// [delta] with its shorter component dropped, so a drag holds to the horizontal or the vertical.
  Offset _alongLongerAxis(Offset delta) => delta.dx.abs() >= delta.dy.abs()
      ? Offset(delta.dx, 0)
      : Offset(0, delta.dy);
}
