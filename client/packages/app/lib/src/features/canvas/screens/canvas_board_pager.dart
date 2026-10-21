// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads the rest of a board once the visible area is up, so every viewer
/// converges on the same objects however many there are.
library;

import 'package:slimm_api/api.dart' as api;

import 'canvas_sync.dart';

/// A board past the object cap cannot need more pages than this to be walked.
const int maxPagedReads = 400;

/// A page that keeps arriving older than the document is read again this often.
const int maxStaleTileReads = 3;

/// Objects held so far against the board's total, when the server says it.
class CanvasPaging {
  const CanvasPaging({required this.loaded, this.total});

  final int loaded;
  final int? total;

  @override
  bool operator ==(Object other) =>
      other is CanvasPaging && other.loaded == loaded && other.total == total;

  @override
  int get hashCode => Object.hash(loaded, total);
}

class CanvasBoardPager {
  CanvasBoardPager({
    required this.read,
    required this.apply,
    required this.onProgress,
    required this.isCancelled,
  });

  /// One page of the region from a seq cursor, oldest first.
  final Future<api.CanvasViewport> Function(int cursorSeq) read;
  final CanvasPageOutcome Function(api.CanvasViewport page) apply;

  /// Called after every applied page with the total the server reported, if any.
  final void Function(int? total) onProgress;
  final bool Function() isCancelled;

  /// Pages the board by seq until the server has no more. Returns false when
  /// it gave up: cancelled, too many pages, or a server that cannot page.
  Future<bool> run() async {
    var cursor = 0;
    int? total;
    for (var reads = 0; reads < maxPagedReads; reads++) {
      final page = await _readPage(cursor);
      if (page == null) return false;
      total ??= page.totalObjects;
      onProgress(total);
      final next = page.nextCursor;
      if (next == null) return !page.hasMore;
      cursor = next;
    }
    return false;
  }

  Future<api.CanvasViewport?> _readPage(int cursor) async {
    for (var attempt = 0; attempt < maxStaleTileReads; attempt++) {
      final page = await read(cursor);
      if (isCancelled()) return null;
      if (apply(page) == CanvasPageOutcome.applied) return page;
    }
    return null;
  }
}
