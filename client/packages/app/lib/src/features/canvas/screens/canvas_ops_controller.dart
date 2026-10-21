// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mints canvas mutation ops - remove, clear, restore, move, reorder, edit - and
/// the undo ledger that reverses them.
///
/// Plain Dart, like `CanvasSync`: nothing here is observed inside a frame,
/// so it stays off Riverpod, and it never reaches back into the widget tree
/// except through [onError].
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../ids.dart';
import 'canvas_commit_queue.dart';
import 'canvas_note_sizing.dart';
import 'canvas_object_inputs.dart';
import 'canvas_retry.dart';

/// Bring-to-front/send-to-back: split out once resize joined this file and
/// pushed it over the 500-line hard limit. A part, not a sibling library,
/// for the same reason `client_canvas.dart` is one of `client.dart`'s: it
/// reaches this file's private undo stack and document, and Dart privacy is
/// library-scoped, not file-scoped.
part 'canvas_ops_controller_reorder.dart';

/// The select tool: drag, resize, and their shared move commit. Split out
/// once the elevation-shadow wiring pushed this file back toward the
/// 500-line hard limit a second time, the same reason and the same shape
/// `canvas_ops_controller_reorder.dart` already split off.
part 'canvas_ops_controller_select.dart';

/// Editing a note's text, and the undo entry that reverses it.
part 'canvas_ops_controller_edit.dart';

/// Moving several objects at once as one undo step.
part 'canvas_ops_controller_group.dart';

/// The eraser's sweep and its batched removal, and the clear.
part 'canvas_ops_controller_erase.dart';

/// Delete, which is always for good, and the undo that places its rows again.
part 'canvas_ops_controller_purge.dart';

/// How many gestures [CanvasOpsController] can reverse. About the product,
/// not the memory: a deeper stack that dies on pane close is a promise the
/// UI cannot keep.
@visibleForTesting
const int undoStackDepth = 32;

/// How far apart the eraser tests along a sweep, under a thin stroke's reach.
const double _sweepStepPx = 4;

/// The event frame's own bound (`MAX_REMOVE_IDS_PER_OP` server-side), so a
/// single erase drag never collects more than one op can carry.
@visibleForTesting
const int maxRemoveIdsPerOp = 64;

sealed class _UndoEntry {
  const _UndoEntry();
}

class _DrawEntry extends _UndoEntry {
  _DrawEntry(this.objectIds);

  final List<String> objectIds;
}

class _EraseEntry extends _UndoEntry {
  _EraseEntry(this.opIds, [this.objectIds = const <String>[]]);

  /// One per 64-id chunk the erase was split into; a restore drains it.
  final List<String> opIds;

  /// Empty for a clear, whose reach is a seq fence, so it cannot be redone.
  final List<String> objectIds;
}

sealed class _RedoEntry {
  const _RedoEntry();
}

/// Re-applies an undone draw by restoring the remove op that undid it.
class _RedoRestore extends _RedoEntry {
  _RedoRestore(this.opIds, this.objectIds);

  final List<String> opIds;
  final List<String> objectIds;
}

/// Re-applies an undone erase by removing the same objects again.
class _RedoRemove extends _RedoEntry {
  _RedoRemove(this.objectIds);

  final List<String> objectIds;
}

/// A history step that succeeded and has no opposite to remember.
class _NoRedo extends _RedoEntry {
  const _NoRedo();
}

/// A history step that found nothing left to reverse, so the next one runs.
class _Skipped extends _RedoEntry {
  const _Skipped();
}

class _NoUndo extends _UndoEntry {
  const _NoUndo();
}

/// Reconciles the undo stack, the erase tool, and the clear control against
/// [document] and the server's op stream.
class CanvasOpsController {
  CanvasOpsController({
    required this.channelId,
    required this.client,
    required this.document,
    required this.commits,
    required this.onError,
    this.onRemoveFailed,
    this.isLocked = _nothingLocked,
  });

  bool _disposed = false;
  bool _historyBusy = false;

  Offset? _lastErase;

  /// Stops retries and any batch still walking, once the pane is gone.
  void dispose() => _disposed = true;

  /// Mints the op id once so every retry of one request is the same op.
  Future<T> _sendOp<T>(Future<T> Function(String opId) send) {
    final opId = newCanvasOpId();
    return retryCanvasRequest(() => send(opId), giveUp: () => _disposed);
  }

  static bool _nothingLocked(String objectId) => false;

  /// Whether an object is locked in place; a drag, a resize and an erase all pass through one.
  final bool Function(String objectId) isLocked;

  final String channelId;
  final api.SlimmApi client;
  final CanvasDocument document;
  final CanvasCommitQueue commits;

  /// A sentence to show once an op this controller submitted fails.
  final void Function(String message) onError;

  /// Reads the region again after a remove the server refused, so the
  /// objects hidden for it come back from the server, the way a restore does.
  final Future<void> Function()? onRemoveFailed;

  final Queue<_UndoEntry> _undoStack = Queue<_UndoEntry>();
  final Queue<_RedoEntry> _redoStack = Queue<_RedoEntry>();

  // Bumped by every fresh edit so an undo still in flight cannot refill a redo stack the edit just cleared.
  int _editEpoch = 0;
  final Set<String> _dragBatch = <String>{};
  _DragState? _drag;
  _ResizeState? _resize;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// Records a just-drawn gesture's object ids so [undo] can reverse it as
  /// one unit, matching what one continuous stroke split into.
  void recordDraw(List<String> objectIds) {
    if (objectIds.isEmpty) return;
    _pushUndo(_DrawEntry(objectIds));
  }

  /// An id [CanvasCommitQueue.undoPlacement] armed while in flight has now
  /// landed; wired as the queue's `onEraseOnConfirm` callback.
  Future<void> eraseOnConfirm(String id) async {
    await _submitRemove([id]);
  }

  /// Deletes [objectId] (and the rest of its mark) for good: hidden at once, then
  /// purged on the server, with the rows kept so [undo] can place them again.
  /// An object still in the placement queue is settled there instead, like the
  /// eraser and undo do: the server has not seen it, so a delete would 404 and
  /// the placement would land after. A moderator's delete also takes a locked object.
  Future<void> deleteSelected(
    String objectId, {
    bool manageCanvas = false,
  }) async {
    bool pinned(String id) => !manageCanvas && isLocked(id);
    if (pinned(objectId)) return;
    final mark = document.groupOf(objectId);
    final members = mark.length > 1 ? mark : [objectId];
    final immediate = <String>[];
    for (final member in members) {
      if (pinned(member)) continue;
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

  /// Reverses the most recent drawn or erased gesture and makes it available to [redo]; an entry leaves the stack only once its reversal succeeded.
  Future<void> undo() async {
    if (_historyBusy) return;
    _historyBusy = true;
    try {
      var skipped = 0;
      while (_undoStack.isNotEmpty && !_disposed) {
        final epoch = _editEpoch;
        final entry = _undoStack.last;
        final redo = await _undoStep(entry);
        if (redo == null) return;
        _undoStack.remove(entry);
        if (redo is _Skipped) {
          skipped++;
          continue;
        }
        if (redo is! _NoRedo && epoch == _editEpoch) _pushRedo(redo);
        return;
      }
      if (skipped > 0) onError('Nothing left to undo is still on the board.');
    } finally {
      _historyBusy = false;
    }
  }

  Future<_RedoEntry?> _undoStep(_UndoEntry entry) => switch (entry) {
    _DrawEntry(:final objectIds) => _undoDraw(objectIds),
    _EraseEntry(:final opIds, :final objectIds) => _restore(opIds, objectIds),
    _PurgeEntry(:final objects) => _undoPurge(objects),
    _MoveEntry(
      :final objectId,
      :final fromX,
      :final fromY,
      :final fromW,
      :final fromH,
    ) =>
      _undoMove(objectId, fromX, fromY, fromW, fromH),
    _MoveGroupEntry(:final from) => _undoMoveGroup(from),
    _ReorderEntry(:final objectId, :final fromZIndex) => _undoReorder(
      objectId,
      fromZIndex,
    ),
    _EditEntry(:final objectId, :final fromText) => _undoEdit(
      objectId,
      fromText,
    ),
    _NoUndo() => Future.value(const _NoRedo()),
  };

  void _pushRedo(_RedoEntry redo) {
    _redoStack.addLast(redo);
    while (_redoStack.length > undoStackDepth) {
      _redoStack.removeFirst();
    }
  }

  /// Re-applies the most recently undone gesture, or does nothing if there
  /// is none. Any fresh edit since the undo has already dropped it.
  Future<void> redo() async {
    if (_historyBusy || _redoStack.isEmpty) return;
    _historyBusy = true;
    try {
      final entry = _redoStack.last;
      final undoEntry = await _redoStep(entry);
      if (undoEntry == null) return;
      _redoStack.remove(entry);
      if (undoEntry is! _NoUndo) _pushUndo(undoEntry, keepRedo: true);
    } finally {
      _historyBusy = false;
    }
  }

  Future<_UndoEntry?> _redoStep(_RedoEntry entry) => switch (entry) {
    _RedoRestore(:final opIds, :final objectIds) => _redoRestore(
      opIds,
      objectIds,
    ),
    _RedoRemove(:final objectIds) => _redoRemove(objectIds),
    _RedoPurge(:final objectIds) => _redoPurge(objectIds),
    final _RedoMove move => _redoMove(move),
    _RedoMoveGroup(:final to) => _redoMoveGroup(to),
    _RedoReorder(:final objectId, :final toZIndex) => _redoReorder(
      objectId,
      toZIndex,
    ),
    _RedoEdit(:final objectId, :final toText) => _redoEdit(objectId, toText),
    _NoRedo() || _Skipped() => Future.value(const _NoUndo()),
  };

  Future<_UndoEntry?> _redoRestore(List<String> opIds, List<String> ids) async {
    if (!await _restoreOps(opIds, 'That could not be redone.')) return null;
    return _DrawEntry(ids);
  }

  Future<_UndoEntry?> _redoRemove(List<String> ids) async {
    final removable = [
      for (final id in ids)
        if (!isLocked(id)) id,
    ];
    for (final id in removable) {
      if (document.isAlive(id)) document.removeObject(id);
    }
    document.refresh();
    final removed = await _submitRemove(
      removable,
      errorMessage: 'That could not be redone.',
    );
    if (!removed.ok) return null;
    if (removed.opIds.isEmpty) return const _NoUndo();
    return _EraseEntry(removed.opIds, removable);
  }

  /// Cancels or arms anything of [objectIds] still in the placement queue,
  /// and removes the rest - already committed, or removed meanwhile, since
  /// only a killed (never-landed) id needs nothing further - with ordinary ops.
  Future<_RedoEntry?> _undoDraw(List<String> objectIds) async {
    final immediate = <String>[];
    for (final id in objectIds) {
      switch (commits.undoPlacement(id)) {
        case UndoPlacementOutcome.cancelled:
          document.kill(id);
        case UndoPlacementOutcome.armed:
          document.removeObject(id);
        case UndoPlacementOutcome.unresolved:
          if (isLocked(id)) continue;
          if (document.isAlive(id)) {
            document.removeObject(id);
            immediate.add(id);
          } else if (document.wasRemoved(id)) {
            // Removed, not killed: the server decides, and answers 0 if it is gone.
            immediate.add(id);
          }
      }
    }
    document.refresh();
    if (immediate.isEmpty) return const _Skipped();
    final removed = await _submitRemove(immediate);
    if (!removed.ok) return null;
    if (removed.opIds.isEmpty) return const _Skipped();
    return _RedoRestore(removed.opIds, immediate);
  }

  /// Ink and shapes are what the eraser takes; an image or a note goes through the object menu's Delete.
  static bool _isInk(CanvasStroke stroke) =>
      stroke.kind == CanvasObjectKind.stroke ||
      stroke.kind == CanvasObjectKind.shape;

  /// Removes [ids] in ops of at most [maxRemoveIdsPerOp]. `opIds` names only
  /// the ops that removed something, since a no-op has nothing to restore.
  Future<({bool ok, List<String> opIds})> _submitRemove(
    List<String> ids, {
    String errorMessage = 'That stroke could not be erased.',
  }) async {
    final opIds = <String>[];
    var affected = 0;
    try {
      for (var i = 0; i < ids.length; i += maxRemoveIdsPerOp) {
        final chunk = ids.sublist(
          i,
          math.min(i + maxRemoveIdsPerOp, ids.length),
        );
        final result = await _sendOp(
          (id) => client.submitCanvasOp(
            channelId,
            id: id,
            kind: 'remove',
            objectIds: chunk,
          ),
        );
        document.confirmRemoved(chunk, result.op.seq);
        if (result.op.affected > 0) opIds.add(result.op.id);
        affected += result.op.affected;
      }
    } on api.ApiException {
      onError(errorMessage);
      _rereadRegion(ids);
      return (ok: false, opIds: opIds);
    }
    // Locked or already-gone ids were skipped server-side, so they may not be hidden here.
    if (affected < ids.length) _rereadRegion(ids);
    return (ok: true, opIds: opIds);
  }

  void _rereadRegion(List<String> ids) {
    document.forgetRemoved(ids);
    unawaited(onRemoveFailed?.call());
  }

  /// Undoes an erase or a clear. The local resurrect is not attempted - the
  /// removed stroke's payload was freed on removal - so a live
  /// `CanvasObjectsRestored` frame or the next catch-up is what brings the
  /// object back.
  Future<_RedoEntry?> _restore(List<String> opIds, List<String> ids) async {
    if (!await _restoreOps(opIds, 'That could not be undone.')) return null;
    return ids.isEmpty ? const _NoRedo() : _RedoRemove(ids);
  }

  /// Restores each op, dropping it from [opIds] once done so a retry of a
  /// half-finished list does not restore the same op twice.
  Future<bool> _restoreOps(List<String> opIds, String errorMessage) async {
    try {
      while (opIds.isNotEmpty) {
        final target = opIds.first;
        await _sendOp(
          (id) => client.submitCanvasOp(
            channelId,
            id: id,
            kind: 'restore',
            targetOp: target,
          ),
        );
        opIds.removeAt(0);
      }
      return true;
    } on api.ApiException {
      onError(errorMessage);
      return false;
    }
  }

  void _pushUndo(_UndoEntry entry, {bool keepRedo = false}) {
    if (!keepRedo) {
      _editEpoch++;
      _redoStack.clear();
    }
    _undoStack.addLast(entry);
    while (_undoStack.length > undoStackDepth) {
      _undoStack.removeFirst();
    }
  }
}
