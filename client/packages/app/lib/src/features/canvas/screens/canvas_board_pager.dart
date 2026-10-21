// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads the rest of a board once the visible area is up, so every viewer
/// converges on the same objects however many there are.
library;

import 'dart:collection';
import 'dart:ui';

import 'package:slimm_api/api.dart' as api;

import 'canvas_sync.dart';

/// A tile this small that is still crowded is given up on and reported.
const double minPagedTile = 32;

/// A board past the object cap cannot need more reads than this to be walked.
const int maxPagedReads = 400;

/// A tile whose page keeps arriving older than the document is read again this often.
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

  final Future<api.CanvasViewport> Function(Rect region) read;
  final CanvasPageOutcome Function(api.CanvasViewport page, Rect region) apply;

  /// Called after every applied tile with the total the server reported, if any.
  final void Function(int? total) onProgress;
  final bool Function() isCancelled;

  /// Pages [seeds] in order, splitting any tile the server could not return
  /// whole. Returns false when a tile stayed crowded at the smallest size.
  Future<bool> run(List<Rect> seeds) async {
    final queue = Queue<Rect>.of(seeds);
    int? total;
    var complete = true;
    var reads = 0;
    while (queue.isNotEmpty) {
      if (isCancelled()) return false;
      if (++reads > maxPagedReads) return false;
      final tile = queue.removeFirst();
      final page = await _readTile(tile);
      if (page == null) continue;
      total ??= page.totalObjects;
      onProgress(total);
      if (!page.hasMore) continue;
      if (tile.shortestSide <= minPagedTile) {
        complete = false;
        continue;
      }
      queue.addAll(_quarters(tile));
    }
    return complete;
  }

  Future<api.CanvasViewport?> _readTile(Rect tile) async {
    for (var attempt = 0; attempt < maxStaleTileReads; attempt++) {
      final page = await read(tile);
      if (isCancelled()) return null;
      if (apply(page, tile) == CanvasPageOutcome.applied) return page;
    }
    return null;
  }

  static List<Rect> _quarters(Rect r) {
    final c = r.center;
    return [
      Rect.fromLTRB(r.left, r.top, c.dx, c.dy),
      Rect.fromLTRB(c.dx, r.top, r.right, c.dy),
      Rect.fromLTRB(r.left, c.dy, c.dx, r.bottom),
      Rect.fromLTRB(c.dx, c.dy, r.right, r.bottom),
    ];
  }

  /// The board first, then the four strips of world around it.
  static List<Rect> seedsFor(Rect board, Rect world) => [
    board,
    Rect.fromLTRB(world.left, world.top, world.right, board.top),
    Rect.fromLTRB(world.left, board.bottom, world.right, world.bottom),
    Rect.fromLTRB(world.left, board.top, board.left, board.bottom),
    Rect.fromLTRB(board.right, board.top, world.right, board.bottom),
  ];
}
