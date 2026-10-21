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
      final before = await _moveTo(
        step.objectId,
        step.x,
        step.y,
        step.w,
        step.h,
        'undone',
      );
      if (before == null) {
        remaining.add(step);
      } else {
        redone.add(
          _MoveStep(step.objectId, before.x, before.y, before.w, before.h),
        );
      }
    }
    // A retry only repeats the steps that did not land.
    steps
      ..clear()
      ..addAll(remaining);
    return remaining.isEmpty ? _RedoMoveGroup(redone) : null;
  }

  Future<_UndoEntry?> _redoMoveGroup(List<_MoveStep> steps) async {
    final undone = <_MoveStep>[];
    final remaining = <_MoveStep>[];
    for (final step in steps) {
      final before = await _moveTo(
        step.objectId,
        step.x,
        step.y,
        step.w,
        step.h,
        'redone',
      );
      if (before == null) {
        remaining.add(step);
      } else {
        undone.add(
          _MoveStep(step.objectId, before.x, before.y, before.w, before.h),
        );
      }
    }
    steps
      ..clear()
      ..addAll(remaining);
    return remaining.isEmpty ? _MoveGroupEntry(undone) : null;
  }
}
