// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which seqs of one channel were fetched from the server this session, since
/// a row with no extras looks the same whether it has none or was never fetched.
library;

import 'dart:math' as math;

typedef _Span = ({int lo, int hi});

class HydratedRanges {
  /// Above every seq: how far up a page fetched with no cursor reaches.
  static const newest = 9007199254740991;

  /// Ascending, disjoint and never touching.
  final _spans = <_Span>[];

  /// Records every seq from [lo] to [hi], both included, as fetched.
  void add(int lo, int hi) {
    if (lo > hi) return;
    var from = lo;
    var to = hi;
    final apart = <_Span>[];
    for (final span in _spans) {
      if (span.hi + 1 < from || span.lo > to + 1) {
        apart.add(span);
        continue;
      }
      from = math.min(from, span.lo);
      to = math.max(to, span.hi);
    }
    _spans
      ..clear()
      ..addAll([...apart, (lo: from, hi: to)])
      ..sort((a, b) => a.lo.compareTo(b.lo));
  }

  /// The highest unfetched seq at or above [floor], [newest] when not even the
  /// newest page was fetched, or null when [floor] and all above it were.
  int? highestGap(int floor) {
    var gap = newest;
    for (final span in _spans.reversed) {
      if (span.hi < gap) break;
      gap = span.lo - 1;
    }
    return gap >= floor ? gap : null;
  }
}
