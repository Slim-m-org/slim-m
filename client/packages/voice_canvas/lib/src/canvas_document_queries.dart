// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_document.dart';

/// The document's read-only spatial-index queries: the slot a live object
/// occupies, whether one is known or alive, and the per-kind live counts the
/// accessibility summary reads. Split from `canvas_document.dart` for the line
/// budget, as an `extension` in a `part of` file so it keeps access to the
/// private slot table without exposing it - the shape `CanvasDocumentSelection`
/// already uses.
extension CanvasDocumentQueries on CanvasDocument {
  /// The stroke at [slot]. Only safe on a slot [paintOrder] just handed back;
  /// a slot from an arbitrary cull may have since been removed or killed, and
  /// [strokeIfAlive] is the one to use there.
  CanvasStroke strokeAt(int slot) => _strokes[slot]!;

  /// Paint order between two slots, bottom first: z-index, then the server's
  /// seq, then the slot, the same total order the server's (z_index, seq)
  /// gives, so ties never shuffle between frames or between clients.
  int comparePaintOrder(int a, int b) {
    final sa = _strokes[a]!;
    final sb = _strokes[b]!;
    final byZ = sa.zIndex.compareTo(sb.zIndex);
    if (byZ != 0) return byZ;
    final bySeq = sa.seq.compareTo(sb.seq);
    return bySeq != 0 ? bySeq : a.compareTo(b);
  }

  /// The stroke at [slot], or null if it was never a real object, has been
  /// removed, or failed to land.
  CanvasStroke? strokeIfAlive(int slot) {
    final stroke = _strokes[slot];
    return (stroke != null && stroke.alive) ? stroke : null;
  }

  /// The slot [id] currently occupies, or null if it is unknown or no longer
  /// alive. The companion to [strokeAt], which takes a slot: together they
  /// let a caller holding an id reach the object without this document
  /// handing out its own map.
  int? slotOf(String id) {
    final slot = _slotById[id];
    if (slot == null) return null;
    return (_strokes[slot]?.alive ?? false) ? slot : null;
  }

  bool knows(String id) => _slotById.containsKey(id);

  /// True if [id] names a stroke this document currently shows as alive: it
  /// landed (or was drawn locally) and has not since been killed or removed.
  ///
  /// The distinction undo needs: a gesture's placement may have already
  /// failed for good by the time somebody undoes it, and a failed one needs
  /// no further removal, unlike a genuinely committed one.
  bool isAlive(String id) {
    final slot = _slotById[id];
    return slot != null && (_strokes[slot]?.alive ?? false);
  }

  /// True for a live image with no bitmap that has not failed to load: the
  /// one state worth fetching for. Asked of the document rather than
  /// remembered by the fetcher, because a removal, a restore and a hard reset
  /// each replace the stroke, and a remembered "already done" goes stale.
  bool imageAwaitsBitmap(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    return stroke != null &&
        stroke.alive &&
        stroke.kind == CanvasObjectKind.image &&
        stroke.image == null &&
        !stroke.imageLoadFailed;
  }

  /// Whether [id] is a live object currently holding a decoded bitmap.
  bool hasImageBitmap(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    return stroke != null && stroke.alive && stroke.image != null;
  }

  /// Ids of the live objects the last cull kept, so a bitmap cache can tell
  /// what is on screen from what is merely fetched.
  Set<String> get visibleIds => {
        for (final slot in scene.visible)
          if (strokeIfAlive(slot) case final stroke?) stroke.id,
      };

  /// The on-screen images that still wait for a bitmap, with the attachment
  /// to fetch for each: what a pan inside an already fetched region needs to
  /// bring back an image evicted while it was off screen.
  List<({String id, String attachmentId})> get visibleImagesAwaitingBitmap => [
        for (final slot in scene.visible)
          if (strokeIfAlive(slot) case final stroke?)
            if (imageAwaitsBitmap(stroke.id) && stroke.attachmentId != null)
              (id: stroke.id, attachmentId: stroke.attachmentId!),
      ];

  /// Every live slot inside [world] (padded for ink width), in paint order.
  List<int> orderedSlotsIn(ui.Rect world) {
    final pad = cullPad;
    final out = CullResult();
    scene.queryRect(
      world.left - pad,
      world.top - pad,
      world.right + pad,
      world.bottom + pad,
      out,
    );
    final slots = [
      for (final slot in out.slots)
        if (strokeIfAlive(slot) != null) slot,
    ]..sort(comparePaintOrder);
    return slots;
  }

  /// The on-screen images that hold a bitmap, so a zoom can tell which are
  /// now drawn larger than they were decoded.
  List<({String id, String attachmentId})> get visibleImagesHoldingBitmap => [
        for (final slot in scene.visible)
          if (strokeIfAlive(slot) case final stroke?)
            if (stroke.kind == CanvasObjectKind.image &&
                stroke.image != null &&
                stroke.attachmentId != null)
              (id: stroke.id, attachmentId: stroke.attachmentId!),
      ];

  /// The attachment [id] names, or null for any other object.
  String? attachmentIdOf(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    return stroke != null && stroke.alive ? stroke.attachmentId : null;
  }

  /// Live object counts by kind, across the whole document rather than only
  /// what the last cull kept - the one query the accessibility summary
  /// needs and nothing else here does, so it is a scan rather than a
  /// maintained counter. Cheap even at the channel's own object ceiling (the
  /// server itself measured a plain scan at 20,000 rows as 1.56ms), and it
  /// is only ever asked for when a screen-reader user opens the activity
  /// panel, never once per frame the way [objectCount] is.
  ({int strokes, int images, int notes, int shapes}) get liveCountsByKind {
    var strokes = 0;
    var images = 0;
    var notes = 0;
    var shapes = 0;
    for (final stroke in _strokes) {
      if (stroke == null || !stroke.alive) continue;
      switch (stroke.kind) {
        case CanvasObjectKind.image:
          images++;
        case CanvasObjectKind.note:
          notes++;
        case CanvasObjectKind.shape:
          shapes++;
        case CanvasObjectKind.stroke:
          strokes++;
      }
    }
    return (strokes: strokes, images: images, notes: notes, shapes: shapes);
  }

  /// The union of every live object's box, or null with nothing drawn -
  /// what "Recenter" fits the camera to instead of resetting to the world
  /// origin. A plain scan for the same reason [liveCountsByKind] is: asked
  /// for once per Recenter tap, never once per frame.
  Rect? get contentBounds {
    Rect? bounds;
    for (final stroke in _strokes) {
      if (stroke == null || !stroke.alive) continue;
      final box = Rect.fromLTWH(stroke.x, stroke.y, stroke.w, stroke.h);
      bounds = bounds?.expandToInclude(box) ?? box;
    }
    return bounds;
  }
}
