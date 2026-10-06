// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mints canvas mutation ops - remove, clear, restore, move, reorder - and
/// the undo ledger that reverses them.
///
/// Plain Dart, like `CanvasSync`: nothing here is observed inside a frame,
/// so it stays off Riverpod, and it never reaches back into the widget tree
/// except through [onError].
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../ids.dart';
import 'canvas_commit_queue.dart';

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

/// How many gestures [CanvasOpsController] can reverse. About the product,
/// not the memory: a deeper stack that dies on pane close is a promise the
/// UI cannot keep.
@visibleForTesting
const int undoStackDepth = 32;

/// The event frame's own bound (`MAX_REMOVE_IDS_PER_OP` server-side), so a
/// single erase drag never collects more than one op can carry.
@visibleForTesting
const int maxRemoveIdsPerOp = 64;

sealed class _UndoEntry {}

class _DrawEntry extends _UndoEntry {
  _DrawEntry(this.objectIds);

  final List<String> objectIds;
}

class _EraseEntry extends _UndoEntry {
  _EraseEntry(this.opId);

  final String opId;
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
  });

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
  final Set<String> _dragBatch = <String>{};
  _DragState? _drag;
  _ResizeState? _resize;

  bool get canUndo => _undoStack.isNotEmpty;

  /// Records a just-drawn gesture's object ids so [undo] can reverse it as
  /// one unit, matching what one continuous stroke split into.
  void recordDraw(List<String> objectIds) {
    if (objectIds.isEmpty) return;
    _pushUndo(_DrawEntry(objectIds));
  }

  /// An id [CanvasCommitQueue.undoPlacement] armed while in flight has now
  /// landed; wired as the queue's `onEraseOnConfirm` callback.
  Future<void> eraseOnConfirm(String id) => _submitRemove([id]);

  /// Removes [objectId] the select tool picked up: applied locally at once
  /// and pushed onto the undo stack on success. An object still in the
  /// placement queue is settled there instead, like the eraser and undo do:
  /// the server has not seen it, so a remove would 404 and the placement
  /// would land after. [CanvasDocument.removeObject]'s own `_freeSlot`
  /// already clears the selection when the freed slot is the current one.
  Future<void> deleteSelected(String objectId) async {
    switch (commits.undoPlacement(objectId)) {
      case UndoPlacementOutcome.cancelled:
        document.kill(objectId);
        document.refresh();
        return;
      case UndoPlacementOutcome.armed:
        document.removeObject(objectId);
        document.refresh();
        return;
      case UndoPlacementOutcome.unresolved:
        break;
    }
    document.removeObject(objectId);
    document.refresh();
    const message = 'That could not be deleted.';
    final opId = await _submitRemove([objectId], errorMessage: message);
    if (opId != null) _pushUndo(_EraseEntry(opId));
  }

  /// Reverses the most recent drawn or erased gesture, or does nothing if
  /// there is none.
  Future<void> undo() async {
    if (_undoStack.isEmpty) return;
    final entry = _undoStack.removeLast();
    switch (entry) {
      case _DrawEntry(:final objectIds):
        await _undoDraw(objectIds);
      case _EraseEntry(:final opId):
        await _restore(opId);
      case _MoveEntry(
        :final objectId,
        :final fromX,
        :final fromY,
        :final fromW,
        :final fromH,
      ):
        await _undoMove(objectId, fromX, fromY, fromW, fromH);
      case _ReorderEntry(:final objectId, :final fromZIndex):
        await _undoReorder(objectId, fromZIndex);
    }
  }

  /// Cancels or arms anything of [objectIds] still in the placement queue,
  /// and removes the rest - already committed, since a killed (never-landed)
  /// id needs nothing further - with one ordinary op.
  Future<void> _undoDraw(List<String> objectIds) async {
    final immediate = <String>[];
    for (final id in objectIds) {
      switch (commits.undoPlacement(id)) {
        case UndoPlacementOutcome.cancelled:
          document.kill(id);
        case UndoPlacementOutcome.armed:
          document.removeObject(id);
        case UndoPlacementOutcome.unresolved:
          if (document.isAlive(id)) {
            document.removeObject(id);
            immediate.add(id);
          }
      }
    }
    document.refresh();
    if (immediate.isEmpty) return;
    // A refused remove leaves the draw standing, so its undo entry goes back.
    if (await _submitRemove(immediate) == null) {
      _pushUndo(_DrawEntry(immediate));
    }
  }

  /// Erases the topmost stroke under [world] the caller is allowed to
  /// erase - their own ink always, or anybody's with [manageCanvas] - and
  /// removes it from view at once. Scoped at hit-test time so a drag
  /// visibly picks up nothing it cannot touch, rather than sending a
  /// request the server would refuse anyway. Fires on pointer-down and every
  /// move; [endErase] is what submits the whole drag as one op.
  void onErasePoint(
    Offset world, {
    required bool manageCanvas,
    required String? selfId,
  }) {
    if (_dragBatch.length >= maxRemoveIdsPerOp) return;
    final id = hitTestStroke(
      document,
      world,
      allowed: (stroke) =>
          manageCanvas ||
          (stroke.authorId != null && stroke.authorId == selfId),
    );
    if (id == null || !_dragBatch.add(id)) return;
    document.removeObject(id);
    document.refresh();
  }

  /// Submits whatever the drag collected as one op, so undoing an erase
  /// drag is atomic. Every id here was alive at hit-test time and has
  /// already been removed from view; this only decides whether that also
  /// needs cancelling from the placement queue - a self-drawn id not yet
  /// confirmed - or an ordinary op, which is everything else.
  Future<void> endErase() async {
    if (_dragBatch.isEmpty) return;
    final ids = _dragBatch.toList(growable: false);
    _dragBatch.clear();
    final immediate = <String>[
      for (final id in ids)
        if (commits.undoPlacement(id) == UndoPlacementOutcome.unresolved) id,
    ];
    if (immediate.isEmpty) return;
    final opId = await _submitRemove(immediate);
    if (opId != null) _pushUndo(_EraseEntry(opId));
  }

  /// Clears every object placed at or before [beforeSeq] - see
  /// `CanvasSync.asOfSeq` for why that is the right fencing token - and
  /// records the resulting op so [undo] can restore it. Returns whether the
  /// request itself succeeded, so the caller can decide what to show; a
  /// clear that touched nothing still succeeds and pushes no undo entry.
  Future<bool> clear(int beforeSeq) async {
    try {
      final result = await client.submitCanvasOp(
        channelId,
        id: newCanvasOpId(),
        kind: 'clear',
        beforeSeq: beforeSeq,
      );
      if (result.op.affected > 0) {
        document.clearBelow(beforeSeq);
        document.refresh();
        _pushUndo(_EraseEntry(result.op.id));
      }
      return true;
    } on api.ApiException {
      onError('The canvas could not be cleared.');
      return false;
    }
  }

  Future<String?> _submitRemove(
    List<String> ids, {
    String errorMessage = 'That stroke could not be erased.',
  }) async {
    try {
      final result = await client.submitCanvasOp(
        channelId,
        id: newCanvasOpId(),
        kind: 'remove',
        objectIds: ids,
      );
      return result.op.id;
    } on api.ApiException {
      onError(errorMessage);
      // The objects were hidden before asking; they still exist for everyone else.
      document.forgetRemoved(ids);
      unawaited(onRemoveFailed?.call());
      return null;
    }
  }

  /// Undoes an erase or a clear. The local resurrect is not attempted - the
  /// removed stroke's payload was freed on removal - so a live
  /// `CanvasObjectsRestored` frame or the next catch-up is what brings the
  /// object back.
  Future<void> _restore(String opId) async {
    try {
      await client.submitCanvasOp(
        channelId,
        id: newCanvasOpId(),
        kind: 'restore',
        targetOp: opId,
      );
    } on api.ApiException {
      onError('That could not be undone.');
    }
  }

  void _pushUndo(_UndoEntry entry) {
    _undoStack.addLast(entry);
    while (_undoStack.length > undoStackDepth) {
      _undoStack.removeFirst();
    }
  }
}
