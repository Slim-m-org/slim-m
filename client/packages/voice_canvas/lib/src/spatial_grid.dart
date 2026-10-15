// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Uniform-grid viewport culling for the Voice Canvas, plus the linear-scan
/// control it has to beat to justify existing.
///
/// Deliberately free of `dart:ui` so the benchmark harness can AOT-compile and
/// run it on the plain Dart VM, where nothing else shares the isolate.
library;

import 'dart:typed_data';

/// Result of a cull, reused across frames so a steady-state pan allocates
/// nothing on the hot path.
class CullResult {
  CullResult() : slots = <int>[];

  final List<int> slots;

  /// Candidates the broad phase produced, before the exact overlap test.
  /// The ratio against [slots] is what says whether a cell size is sane.
  int candidates = 0;

  /// Grid cells the broad phase probed. Blows up when the camera zooms out,
  /// which is the failure mode the adaptive path exists to dodge.
  int cellsVisited = 0;

  /// Empties this result, both at the start of a fresh query and for a
  /// document-wide reset - after which the slots it last held may no longer
  /// be valid indices at all, so they cannot be left cached until the next
  /// query happens to overwrite them.
  void clear() {
    slots.clear();
    candidates = 0;
    cellsVisited = 0;
  }
}

/// How a query chose to answer.
enum CullStrategy { grid, linear }

/// A sparse uniform grid over an unbounded world.
///
/// Sparse rather than dense because the roadmap's plus-or-minus 5,000,000px
/// world at 2048px cells is 23.8M cells, which no client can hold as an array.
class UniformGrid {
  UniformGrid({required this.cellSize, int capacity = 1024})
      : assert(cellSize > 0, 'cellSize must be positive'),
        _bounds = Float64List(capacity * 4),
        _stamp = Int32List(capacity);

  final double cellSize;

  final Map<int, List<int>> _cells = <int, List<int>>{};
  Float64List _bounds;
  Int32List _stamp;
  int _count = 0;
  int _removed = 0;
  int _queryId = 0;

  /// Number of slots ever handed out by [insert], dead or alive.
  ///
  /// Slots are dense addresses [CanvasDocument] uses to index its own
  /// strokes and are never renumbered, so this never shrinks - a removal
  /// parks a slot rather than freeing it. See [liveLength] for the count a
  /// cull can actually still return.
  int get length => _count;

  /// Objects still findable by either cull branch.
  int get liveLength => _count - _removed;

  /// Occupied cells. Sparse-grid memory is proportional to this, not to world
  /// area, which is the whole reason the grid is a hash map.
  int get occupiedCells => _cells.length;

  /// Total slot entries across all buckets. Divided by [length] this is the
  /// duplication factor an object-larger-than-a-cell world pays.
  int get bucketEntries {
    var total = 0;
    for (final bucket in _cells.values) {
      total += bucket.length;
    }
    return total;
  }

  /// Adds an axis-aligned box and returns its dense slot.
  int insert(double left, double top, double right, double bottom) {
    if (_count == _stamp.length) {
      _grow();
    }
    final slot = _count++;
    final base = slot << 2;
    _bounds[base] = left;
    _bounds[base + 1] = top;
    _bounds[base + 2] = right;
    _bounds[base + 3] = bottom;

    final cx0 = (left / cellSize).floor();
    final cy0 = (top / cellSize).floor();
    final cx1 = (right / cellSize).floor();
    final cy1 = (bottom / cellSize).floor();
    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        (_cells[_key(cx, cy)] ??= <int>[]).add(slot);
      }
    }
    return slot;
  }

  /// Takes a slot out of every bucket it spans and parks its box inverted, so
  /// both cull branches reject it on the first comparison of the overlap test
  /// they already run.
  ///
  /// Infinities, never NaN: the overlap test below is a *rejection* test, so
  /// a NaN-parked box would make every comparison false, which the test
  /// reads as "kept" - the exact opposite of removal. Slots are never
  /// renumbered: [CanvasDocument] addresses its strokes by the integer this
  /// class hands out, and compaction would mis-address every stroke above
  /// the hole.
  void remove(int slot) {
    final base = slot << 2;
    final left = _bounds[base];
    final top = _bounds[base + 1];
    final right = _bounds[base + 2];
    final bottom = _bounds[base + 3];
    // The parked box is inverted, so this is also the idempotence guard.
    if (right < left) return;

    final cx0 = (left / cellSize).floor();
    final cy0 = (top / cellSize).floor();
    final cx1 = (right / cellSize).floor();
    final cy1 = (bottom / cellSize).floor();
    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        _removeFromBucket(_key(cx, cy), slot);
      }
    }

    _bounds[base] = double.infinity;
    _bounds[base + 1] = double.infinity;
    _bounds[base + 2] = double.negativeInfinity;
    _bounds[base + 3] = double.negativeInfinity;
    _removed++;
  }

  /// Repositions a slot already in the index, keeping its number.
  ///
  /// The operation [remove] then [insert] used to stand in for, and the
  /// reason that stand-in was wrong: [insert] always hands out a *fresh*
  /// slot, and [remove] parks the old one forever, since slots are never
  /// renumbered. A drag calls this once per pointer event, so the pair
  /// leaked a slot per event - hundreds across one gesture, never
  /// reclaimed, each one walked by every later linear cull.
  ///
  /// Only the buckets that actually change are touched: an object nudged
  /// inside one cell rewrites its bounds and nothing else.
  void move(int slot, double left, double top, double right, double bottom) {
    final base = slot << 2;
    final oldLeft = _bounds[base];
    final oldTop = _bounds[base + 1];
    final oldRight = _bounds[base + 2];
    final oldBottom = _bounds[base + 3];
    final parked = oldRight < oldLeft;

    final ncx0 = (left / cellSize).floor();
    final ncy0 = (top / cellSize).floor();
    final ncx1 = (right / cellSize).floor();
    final ncy1 = (bottom / cellSize).floor();

    if (!parked) {
      final ocx0 = (oldLeft / cellSize).floor();
      final ocy0 = (oldTop / cellSize).floor();
      final ocx1 = (oldRight / cellSize).floor();
      final ocy1 = (oldBottom / cellSize).floor();
      if (ocx0 == ncx0 && ocy0 == ncy0 && ocx1 == ncx1 && ocy1 == ncy1) {
        _bounds[base] = left;
        _bounds[base + 1] = top;
        _bounds[base + 2] = right;
        _bounds[base + 3] = bottom;
        return;
      }
      for (var cy = ocy0; cy <= ocy1; cy++) {
        for (var cx = ocx0; cx <= ocx1; cx++) {
          _removeFromBucket(_key(cx, cy), slot);
        }
      }
    } else {
      // Un-parking one: it left the live count when it was removed.
      _removed--;
    }

    _bounds[base] = left;
    _bounds[base + 1] = top;
    _bounds[base + 2] = right;
    _bounds[base + 3] = bottom;
    for (var cy = ncy0; cy <= ncy1; cy++) {
      for (var cx = ncx0; cx <= ncx1; cx++) {
        (_cells[_key(cx, cy)] ??= <int>[]).add(slot);
      }
    }
  }

  /// Empties the index for a document-wide reset.
  ///
  /// The typed arrays are kept at their current size rather than
  /// reallocated: a reset is always followed by fresh inserts, so shrinking
  /// them first would only cost a regrow.
  void reset() {
    _cells.clear();
    _count = 0;
    _removed = 0;
    _queryId = 0;
    _stamp.fillRange(0, _stamp.length, 0);
  }

  /// Swap-remove: order is irrelevant because `CanvasDocument.paintOrder`
  /// sorts by z-index, and a linear `List.remove` cannot afford a bucket
  /// holding the clustered worst case's thousands of slots.
  void _removeFromBucket(int key, int slot) {
    final bucket = _cells[key];
    if (bucket == null) return;
    final i = bucket.indexOf(slot);
    if (i == -1) return;
    bucket[i] = bucket.last;
    bucket.removeLast();
    if (bucket.isEmpty) _cells.remove(key);
  }

  /// Broad phase over grid cells, then an exact overlap test per candidate.
  void queryGrid(
    double left,
    double top,
    double right,
    double bottom,
    CullResult out,
  ) {
    out.clear();
    final stamp = _nextStamp();
    final cx0 = (left / cellSize).floor();
    final cy0 = (top / cellSize).floor();
    final cx1 = (right / cellSize).floor();
    final cy1 = (bottom / cellSize).floor();

    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        out.cellsVisited++;
        final bucket = _cells[_key(cx, cy)];
        if (bucket == null) {
          continue;
        }
        for (var i = 0; i < bucket.length; i++) {
          final slot = bucket[i];
          if (_stamp[slot] == stamp) {
            continue;
          }
          _stamp[slot] = stamp;
          out.candidates++;
          final base = slot << 2;
          if (_bounds[base] > right ||
              _bounds[base + 2] < left ||
              _bounds[base + 1] > bottom ||
              _bounds[base + 3] < top) {
            continue;
          }
          out.slots.add(slot);
        }
      }
    }
  }

  /// The control: every object tested once, straight down two typed arrays.
  void queryLinear(
    double left,
    double top,
    double right,
    double bottom,
    CullResult out,
  ) {
    out.clear();
    out.candidates = _count;
    for (var slot = 0; slot < _count; slot++) {
      final base = slot << 2;
      if (_bounds[base] > right ||
          _bounds[base + 2] < left ||
          _bounds[base + 1] > bottom ||
          _bounds[base + 3] < top) {
        continue;
      }
      out.slots.add(slot);
    }
  }

  /// Picks whichever phase does less work for this viewport.
  ///
  /// Without this a fully zoomed-out camera probes every cell in the world,
  /// which is unboundedly worse than just testing every object once. The
  /// choice is against [length], deliberately not [liveLength]: a parked
  /// slot makes the grid branch strictly cheaper (it is out of every
  /// bucket) and the linear branch no cheaper (it still walks every slot,
  /// parked or not), so [length] is the honest cost of the linear branch
  /// this is choosing against.
  CullStrategy query(
    double left,
    double top,
    double right,
    double bottom,
    CullResult out,
  ) {
    final spanX = (right / cellSize).floor() - (left / cellSize).floor() + 1;
    final spanY = (bottom / cellSize).floor() - (top / cellSize).floor() + 1;
    if (spanX * spanY > _count) {
      queryLinear(left, top, right, bottom, out);
      return CullStrategy.linear;
    }
    queryGrid(left, top, right, bottom, out);
    return CullStrategy.grid;
  }

  int _nextStamp() {
    if (_queryId == 0x7fffffff) {
      _stamp.fillRange(0, _stamp.length, 0);
      _queryId = 0;
    }
    return ++_queryId;
  }

  void _grow() {
    final grown = Float64List(_bounds.length * 2)
      ..setRange(0, _bounds.length, _bounds);
    _bounds = grown;
    final stamps = Int32List(_stamp.length * 2)
      ..setRange(0, _stamp.length, _stamp);
    _stamp = stamps;
  }

  /// Two signed cell coordinates packed into one int, so a bucket lookup
  /// hashes a scalar rather than an allocated point.
  ///
  /// Twenty-six bits each and a multiply rather than a 32-bit shift: compiled
  /// to JavaScript a shift past 31 is zero, which made every cell in a row
  /// one bucket on the web, and fifty-two bits is still exact in a double.
  /// Twenty-six bits of cells is far past the bounded world at any cell size.
  static int _key(int cx, int cy) =>
      (cx & _coordinateMask) * (_coordinateMask + 1) + (cy & _coordinateMask);

  static const int _coordinateMask = 0x3ffffff;
}
