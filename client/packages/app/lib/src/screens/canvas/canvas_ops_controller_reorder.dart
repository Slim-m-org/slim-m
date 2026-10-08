// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_ops_controller.dart';

/// One `z_index` change in progress, and the undo that reverses it.
class _ReorderEntry extends _UndoEntry {
  _ReorderEntry(this.objectId, this.fromZIndex);

  final String objectId;
  final int fromZIndex;
}

/// The `z_index` an undone reorder left, which a redo restores.
class _RedoReorder extends _RedoEntry {
  _RedoReorder(this.objectId, this.toZIndex);

  final String objectId;
  final int toZIndex;
}

/// Bring-to-front and send-to-back, called from a button rather than a
/// drag gesture - unlike resize and move, there is no in-progress state to
/// track here, only a request and its undo.
extension CanvasOpsControllerReorder on CanvasOpsController {
  /// Restacks [objectId] to stand strictly above every live object this
  /// client currently knows about, or does nothing if it already does.
  ///
  /// The target `z_index` is this client's own best local guess - see
  /// `CanvasDocument.zIndexRange`'s own doc for why that is enough:
  /// correctness rests on the server's last-write-wins column, not on the
  /// guess being the true deployment-wide extreme.
  Future<void> bringToFront(String objectId) =>
      _reorder(objectId, toFront: true);

  /// The mirror of [bringToFront]: restacks [objectId] to stand strictly
  /// below everything this client knows about.
  Future<void> sendToBack(String objectId) =>
      _reorder(objectId, toFront: false);

  Future<void> _reorder(String objectId, {required bool toFront}) async {
    final current = document.zIndexOf(objectId);
    if (current == null) return;
    final range = document.zIndexRange;
    final target = toFront
        ? (range != null && range.$2 > current ? range.$2 + 1 : null)
        : (range != null && range.$1 < current ? range.$1 - 1 : null);
    if (target == null) return;
    await _submitReorder(objectId, current, target);
  }

  Future<void> _submitReorder(String objectId, int fromZ, int toZ) async {
    document.setZIndex(objectId, toZ);
    document.refresh();
    try {
      await client.submitCanvasOp(
        channelId,
        id: newCanvasOpId(),
        kind: 'reorder',
        objectId: objectId,
        zIndex: toZ,
      );
      _pushUndo(_ReorderEntry(objectId, fromZ));
    } on api.ApiException {
      document.setZIndex(objectId, fromZ);
      document.refresh();
      onError('That could not be reordered.');
    }
  }

  Future<_RedoEntry?> _undoReorder(String objectId, int z) async {
    final before = await _reorderTo(objectId, z, 'undone');
    return before == null ? null : _RedoReorder(objectId, before);
  }

  Future<_UndoEntry?> _redoReorder(String objectId, int z) async {
    final before = await _reorderTo(objectId, z, 'redone');
    return before == null ? null : _ReorderEntry(objectId, before);
  }

  /// Resubmits an exact `z_index` a history step names - exact, unlike a
  /// relative "bring to front", because the op stream carries the literal
  /// value - and returns the one it replaced, or null on failure.
  Future<int?> _reorderTo(String objectId, int z, String verb) async {
    final before = document.zIndexOf(objectId);
    document.setZIndex(objectId, z);
    document.refresh();
    try {
      await client.submitCanvasOp(
        channelId,
        id: newCanvasOpId(),
        kind: 'reorder',
        objectId: objectId,
        zIndex: z,
      );
      return before;
    } on api.ApiException {
      if (before != null) {
        document.setZIndex(objectId, before);
        document.refresh();
      }
      onError('That could not be $verb.');
      return null;
    }
  }
}
