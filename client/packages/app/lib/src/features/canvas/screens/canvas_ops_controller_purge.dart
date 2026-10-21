// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_ops_controller.dart';

/// A delete the server has already made final; undo places these rows again.
class _PurgeEntry extends _UndoEntry {
  _PurgeEntry(this.objects);

  final List<api.CanvasObject> objects;
}

/// Re-applies an undone delete by deleting the objects the undo placed again.
class _RedoPurge extends _RedoEntry {
  _RedoPurge(this.objectIds);

  final List<String> objectIds;
}

/// Delete is always for good, so undo is the client re-creating its own copy of the row.
extension CanvasOpsControllerPurge on CanvasOpsController {
  /// Deletes [ids] for good one by one; the rows come back in [rows] so a delete can be undone.
  /// An id the server no longer has was deleted elsewhere and counts as done.
  Future<({bool ok, List<api.CanvasObject> rows})> _purge(
    List<String> ids,
    String errorMessage,
  ) async {
    final rows = <api.CanvasObject>[];
    final unfinished = [...ids];
    try {
      for (final id in ids) {
        try {
          rows.add(
            await retryCanvasRequest(
              () => client.purgeCanvasObject(channelId, id),
              giveUp: () => _disposed,
            ),
          );
        } on api.NotFoundException catch (error, stack) {
          api.AppLog.swallowed(
            api.LogTag.ui,
            'Already deleted by another client; nothing to undo',
            error,
            stack,
          );
        }
        unfinished.remove(id);
      }
    } on api.ApiException {
      onError(errorMessage);
      _rereadRegion(unfinished);
      return (ok: false, rows: rows);
    }
    return (ok: true, rows: rows);
  }

  /// Places the deleted rows again as new objects, which is all an undo of a delete can do.
  Future<_RedoEntry?> _undoPurge(List<api.CanvasObject> objects) async {
    final placedIds = <String>[];
    try {
      for (final object in objects) {
        final id = newCanvasObjectId();
        final placed = await _sendOp(
          (_) => client.placeCanvasObject(
            channelId,
            id: id,
            kind: object.kind,
            x: object.x,
            y: object.y,
            w: object.w,
            h: object.h,
            props: object.props,
          ),
        );
        placedIds.add(id);
        final input = canvasStrokeInputFrom(placed);
        if (input == null) continue;
        document
          ..applyPlaced(input)
          ..refresh();
      }
    } on api.ApiException {
      onError('That could not be undone.');
      return null;
    }
    return _RedoPurge(placedIds);
  }

  Future<_UndoEntry?> _redoPurge(List<String> ids) async {
    final removable = [
      for (final id in ids)
        if (!isLocked(id)) id,
    ];
    for (final id in removable) {
      if (document.isAlive(id)) document.removeObject(id);
    }
    document.refresh();
    final purged = await _purge(removable, 'That could not be redone.');
    if (!purged.ok) return null;
    return purged.rows.isEmpty ? const _NoUndo() : _PurgeEntry(purged.rows);
  }
}
