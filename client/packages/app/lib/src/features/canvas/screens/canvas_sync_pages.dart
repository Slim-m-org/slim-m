// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_sync.dart';

/// Viewport pages go through the same reducer as the feed, so a region read
/// that lands late cannot undo what a live frame already did.
extension CanvasSyncViewport on CanvasSync {
  /// Applies one region read answered at `page.latestSeq`: the first seeds the cursor, an older one is brought forward from the op log or refused if the log no longer reaches it.
  /// A complete read also drops what the document shows in the region but the read omits.
  CanvasPageOutcome applyViewport(
    api.CanvasViewport page,
    Rect region, {
    void Function(api.CanvasObject object)? onObject,
    bool listsWholeRegion = true,
  }) {
    final head = page.latestSeq;
    seedFromViewport(head);
    final cursor = _asOfSeq!;
    if (head < cursor && (!_log.covers(head) || _log.restoredAfter(head))) {
      return CanvasPageOutcome.stale;
    }
    for (final object in page.objects) {
      final input = canvasStrokeInputFrom(object);
      if (input == null) continue;
      document.applyPlaced(input, overwrite: true, snapshotSeq: head);
      onObject?.call(object);
    }
    // A document still behind the snapshot differs from it by ops the feed is about to bring.
    if (listsWholeRegion && !page.hasMore && head <= cursor) {
      _dropUnlisted(page, region, head);
    }
    if (head < cursor) _log.after(head).forEach(_reapply);
    document.refresh();
    return CanvasPageOutcome.applied;
  }

  /// Whether a clear this document already applied swept [object], which was
  /// still unconfirmed locally when the clear arrived and so escaped it.
  bool clearedSincePlacement(api.CanvasObject object) {
    var cleared = false;
    for (final op in _log.after(object.seq)) {
      switch (op) {
        case api.CanvasClearOp(
          :final beforeSeq,
          :final scope,
          :final sparedIds,
        ):
          cleared =
              cleared ||
              (beforeSeq >= object.seq &&
                  _scopeCovers(scope, object) &&
                  !sparedIds.contains(object.id));
        case api.CanvasRestoreOp(:final objectIds):
          // Restored again since, or a restore too large to name its objects.
          if (objectIds.isEmpty || objectIds.contains(object.id)) {
            cleared = false;
          }
        default:
          break;
      }
    }
    return cleared;
  }

  static bool _scopeCovers(api.CanvasClearScope scope, api.CanvasObject o) =>
      (scope.kinds.isEmpty || scope.kinds.contains(o.kind)) &&
      (scope.authorId == null || scope.authorId == o.authorId);

  void _dropUnlisted(api.CanvasViewport page, Rect region, int head) {
    final listed = {for (final object in page.objects) object.id};
    final touched = _log.touchedAfter(head);
    final stale = [
      for (final held in document.liveObjects())
        if (held.seq > 0 &&
            held.seq <= head &&
            region.overlaps(held.box) &&
            !listed.contains(held.id) &&
            !touched.contains(held.id) &&
            !(isShownOffPlace?.call(held.id) ?? false))
          held.id,
    ];
    document.dropObjects(stale);
  }
}
