// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_document.dart';

/// The resize and reorder gesture's own reads: what kind an object is,
/// who authored it, and its current stacking order. Split out of
/// `canvas_document.dart`, which crossed the 500-line hard limit once this
/// group and the accessibility summary's `liveCountsByKind` both landed on
/// it; an `extension` rather than a second class, since these still need
/// `CanvasDocument`'s own private slot table, and a `part of` file shares
/// that access without exposing it beyond this library.
extension CanvasDocumentSelection on CanvasDocument {
  /// The kind a live object was placed as, or null if [id] is unknown or has
  /// been removed. What a resize gesture needs to refuse a stroke: an image,
  /// a note and a shape all have a box with nothing thinner inside it to
  /// distort, but a stroke's ink is the thing a box would distort.
  CanvasObjectKind? kindOf(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    return (stroke != null && stroke.alive) ? stroke.kind : null;
  }

  /// A live note's own full text, or null if [id] is unknown, removed, or
  /// not a note. The one content field the current selection's own
  /// accessibility node needs beyond [kindOf] - nothing else places text
  /// as an object's content, and the painter's own clipping never touches
  /// this copy of it.
  String? textOf(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    return (stroke != null && stroke.alive) ? stroke.text : null;
  }

  /// A live object's author, or null if [id] is unknown, removed, or was
  /// authored by a since-deleted account. What a resize or reorder gesture
  /// on the *current selection* needs to decide authorship without a fresh
  /// hit test - unlike a move or an erase, the pointer is over a handle or a
  /// toolbar button, not the object itself.
  String? authorIdOf(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    return (stroke != null && stroke.alive) ? stroke.authorId : null;
  }

  /// A live object's current `zIndex`, or null if [id] is unknown or has
  /// been removed.
  int? zIndexOf(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    return (stroke != null && stroke.alive) ? stroke.zIndex : null;
  }

  /// Sets a live object's `zIndex` directly, with no reindexing: unlike
  /// [CanvasDocument.moveObject], paint order is not part of the spatial
  /// grid's own key, so there is no slot to free and re-add. Returns false
  /// if [id] is unknown or has been removed.
  bool setZIndex(String id, int zIndex) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    if (stroke == null || !stroke.alive) return false;
    stroke.zIndex = zIndex;
    _orderDirty = true;
    return true;
  }

  /// The lowest and highest `zIndex` this document currently holds live, or
  /// null if it holds nothing.
  ///
  /// Scans every loaded object, not only what [CanvasDocument.paintOrder]'s
  /// cull currently keeps: "bring to front" means in front of everything
  /// this client knows about, not only what fits on screen right now.
  /// Correctness for a concurrent reorder rests on the server's
  /// last-write-wins column, not on this being the true deployment-wide
  /// extreme - see `CanvasOpsController.bringToFront`'s own doc for why
  /// that is enough.
  (int min, int max)? get zIndexRange {
    int? lo;
    int? hi;
    for (final stroke in _strokes) {
      if (stroke == null || !stroke.alive) continue;
      // A stroke still waiting on its commit sits at a placeholder z no server holds.
      if (stroke.zIndex == provisionalLocalZIndex) continue;
      lo = lo == null ? stroke.zIndex : math.min(lo, stroke.zIndex);
      hi = hi == null ? stroke.zIndex : math.max(hi, stroke.zIndex);
    }
    return lo == null ? null : (lo, hi!);
  }
}
