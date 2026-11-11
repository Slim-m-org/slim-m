// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The content layouts [fitStage] scores: justified rows, even grids, a pinned
/// item with a row or a column, and the bento.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'stage_item.dart';

/// A laid-out set of items; [rects] and [crop] are indexed like the input.
class StageBlock {
  const StageBlock(this.rects, this.rows, this.shape, [this.crop = const {}]);

  final List<Rect> rects;
  final int rows;
  final StageShape shape;
  final Map<int, double> crop;

  double get area => rects.fold(0.0, (s, r) => s + r.width * r.height);

  StageBlock shifted(double dx, double dy) => StageBlock(
    [for (final r in rects) r.shift(Offset(dx, dy))],
    rows,
    shape,
    crop,
  );
}

const double _tie = 0.005;
const double _minRest = 48;

StageBlock? _better(StageBlock? a, StageBlock? b) {
  if (b == null) return a;
  if (a == null) return b;
  if (b.area > a.area * (1 + _tie)) return b;
  if (b.area >= a.area * (1 - _tie) && b.rows < a.rows) return b;
  return a;
}

/// The best layout of [items] in [box]; the first item is the pinned one.
StageBlock? bestContent(List<StageItem> items, Rect box, double gap) {
  if (items.isEmpty || box.width <= 0 || box.height <= 0) return null;
  final all = <StageBlock?>[
    justified(items, box, gap, StageShape.grid),
    for (var c = 1; c <= items.length; c++) evenGrid(items, c, box, gap),
    pinnedRow(items, box, gap),
    pinnedColumn(items, box, gap),
    bento(items, box, gap),
  ];
  var pool = [for (final b in all) ?b];
  for (final keep in [_pinnedIsLargest, _legible]) {
    final kept = [
      for (final b in pool)
        if (keep(b)) b,
    ];
    if (kept.isNotEmpty) pool = kept;
  }
  StageBlock? best;
  for (final b in pool) {
    best = _better(best, b);
  }
  return best;
}

/// The narrowest a content tile may get while a roomier layout exists.
const double stageMinContentWidth = 108;

bool _legible(StageBlock b) =>
    b.rects.every((r) => r.width >= stageMinContentWidth);

bool _pinnedIsLargest(StageBlock b) {
  final pinned = b.rects.first.width * b.rects.first.height;
  return b.rects.skip(1).every((r) => r.width * r.height <= pinned * 1.001);
}

Size _contain(double aspect, double w, double h) {
  final width = math.min(w, h * aspect);
  return Size(width, width / aspect);
}

/// Rows of items, each stretched to the box width, all scaled down to fit its height.
StageBlock? justified(
  List<StageItem> items,
  Rect region,
  double gap,
  StageShape shape,
) {
  final n = items.length;
  if (n == 0 || region.width <= 0 || region.height <= 0) return null;
  final aspects = [for (final i in items) i.aspect];
  StageBlock? best;
  for (var rows = 1; rows <= math.min(n, 8); rows++) {
    final seen = <String>{};
    for (final factor in const [0.6, 0.8, 1.0, 1.25, 1.6]) {
      final ideal = region.width * rows / region.height * factor;
      final cuts = _partition(aspects, rows, ideal);
      if (!seen.add(cuts.join(','))) continue;
      best = _better(best, _layoutRows(items, cuts, region, gap, shape));
    }
  }
  return best;
}

/// Splits [a] in order into [rows] runs whose summed aspect is nearest [ideal];
/// ties leave the later rows fuller.
List<int> _partition(List<double> a, int rows, double ideal) {
  final n = a.length;
  final pre = [0.0];
  for (final x in a) {
    pre.add(pre.last + x);
  }
  double cost(int i, int j) {
    final d = pre[j] - pre[i] - ideal;
    return d * d;
  }

  final dp = List.generate(
    rows + 1,
    (_) => List.filled(n + 1, double.infinity),
  );
  final from = List.generate(rows + 1, (_) => List.filled(n + 1, 0));
  dp[0][0] = 0;
  for (var k = 1; k <= rows; k++) {
    for (var j = k; j <= n; j++) {
      for (var i = k - 1; i < j; i++) {
        final c = dp[k - 1][i] + cost(i, j);
        if (c < dp[k][j] - 1e-9) {
          dp[k][j] = c;
          from[k][j] = i;
        }
      }
    }
  }
  final cuts = <int>[];
  var j = n;
  for (var k = rows; k >= 1; k--) {
    j = from[k][j];
    cuts.insert(0, j);
  }
  return cuts;
}

StageBlock _layoutRows(
  List<StageItem> items,
  List<int> cuts,
  Rect region,
  double gap,
  StageShape shape,
) {
  final n = items.length;
  final rows = cuts.length;
  int end(int k) => k + 1 < rows ? cuts[k + 1] : n;
  final natural = <double>[
    for (var k = 0; k < rows; k++)
      (region.width - (end(k) - cuts[k] - 1) * gap) /
          items.sublist(cuts[k], end(k)).fold(0.0, (s, i) => s + i.aspect),
  ];
  final scale = math.min(
    1.0,
    (region.height - (rows - 1) * gap) / natural.fold(0.0, (s, h) => s + h),
  );
  final used = natural.fold(0.0, (s, h) => s + h * scale) + (rows - 1) * gap;
  var y = region.top + (region.height - used) / 2;
  final rects = List<Rect>.filled(n, Rect.zero);
  final crop = <int, double>{};
  for (var k = 0; k < rows; k++) {
    final h = natural[k] * scale;
    final idx = [for (var i = cuts[k]; i < end(k); i++) i];
    final widths = [for (final i in idx) items[i].aspect * h];
    final cams = [
      for (final i in idx)
        if (items[i].kind == StageKind.camera) i,
    ];
    final slack =
        region.width -
        widths.fold(0.0, (s, w) => s + w) -
        (idx.length - 1) * gap;
    if (slack > 0.5 && cams.isNotEmpty) {
      for (final i in cams) {
        final at = idx.indexOf(i);
        final room = widths[at] * (1 / (1 - stageMaxCrop) - 1);
        final extra = math.min(slack / cams.length, room);
        crop[i] = 1 - widths[at] / (widths[at] + extra);
        widths[at] += extra;
      }
    }
    final rowW = widths.fold(0.0, (s, w) => s + w) + (idx.length - 1) * gap;
    var x = region.left + (region.width - rowW) / 2;
    for (var m = 0; m < idx.length; m++) {
      rects[idx[m]] = Rect.fromLTWH(x, y, widths[m], h);
      x += widths[m] + gap;
    }
    y += h + gap;
  }
  return StageBlock(rects, rows, shape, crop);
}

/// Equal cells in [cols] columns, each item sized to its aspect inside its cell.
StageBlock evenGrid(List<StageItem> items, int cols, Rect box, double gap) {
  final n = items.length;
  final rows = (n / cols).ceil();
  final cw = (box.width - (cols - 1) * gap) / cols;
  final ch = (box.height - (rows - 1) * gap) / rows;
  final rects = <Rect>[];
  for (var i = 0; i < n; i++) {
    final row = i ~/ cols;
    final inRow = row == rows - 1 ? n - row * cols : cols;
    final x0 = box.left + (box.width - (inRow * cw + (inRow - 1) * gap)) / 2;
    final cell = Rect.fromLTWH(
      x0 + (i - row * cols) * (cw + gap),
      box.top + row * (ch + gap),
      cw,
      ch,
    );
    final s = _contain(items[i].aspect, cw, ch);
    rects.add(
      Rect.fromCenter(center: cell.center, width: s.width, height: s.height),
    );
  }
  return StageBlock(rects, rows, StageShape.grid);
}

StageBlock _compose(
  Rect box,
  List<Rect> head,
  StageBlock? rest,
  int headRows,
  StageShape shape, {
  required bool centerVertical,
}) {
  final rects = [...head, ...?rest?.rects];
  final bottom = rects.fold(box.top, (m, r) => math.max(m, r.bottom));
  final right = rects.fold(box.left, (m, r) => math.max(m, r.right));
  final block = StageBlock(rects, headRows + (rest?.rows ?? 0), shape, {
    for (final e in (rest?.crop ?? const <int, double>{}).entries)
      e.key + head.length: e.value,
  });
  return centerVertical
      ? block.shifted(0, (box.bottom - bottom) / 2)
      : block.shifted((box.right - right) / 2, 0);
}

List<double> _steps(double lo, double hi) => [
  for (var s = 24; s >= 0; s--) lo + (hi - lo) * s / 24,
];

/// The pinned item across the top, everything else in rows below.
StageBlock? pinnedRow(List<StageItem> items, Rect box, double gap) {
  if (items.length < 2) return null;
  final lo = box.height * 0.2;
  final hi = box.height - _minRest - gap;
  if (hi <= lo) return null;
  final rest = items.sublist(1);
  StageBlock? best;
  for (final hp in _steps(lo, hi)) {
    final s = _contain(items.first.aspect, box.width, hp);
    final below = Rect.fromLTRB(
      box.left,
      box.top + s.height + gap,
      box.right,
      box.bottom,
    );
    final rb = justified(rest, below, gap, StageShape.grid);
    if (rb == null) continue;
    final head = Rect.fromLTWH(
      box.left + (box.width - s.width) / 2,
      box.top,
      s.width,
      s.height,
    );
    best = _better(
      best,
      _compose(box, [head], rb, 1, StageShape.pinnedRow, centerVertical: true),
    );
  }
  return best;
}

/// The pinned item at the left, everything else in rows to its right.
StageBlock? pinnedColumn(List<StageItem> items, Rect box, double gap) {
  if (items.length < 2) return null;
  final lo = box.width * 0.2;
  final hi = box.width - _minRest - gap;
  if (hi <= lo) return null;
  final rest = items.sublist(1);
  StageBlock? best;
  for (final wp in _steps(lo, hi)) {
    final s = _contain(items.first.aspect, wp, box.height);
    final right = Rect.fromLTRB(
      box.left + s.width + gap,
      box.top,
      box.right,
      box.bottom,
    );
    final rb = justified(rest, right, gap, StageShape.grid);
    if (rb == null) continue;
    final head = Rect.fromLTWH(
      box.left,
      box.top + (box.height - s.height) / 2,
      s.width,
      s.height,
    );
    best = _better(
      best,
      _compose(
        box,
        [head],
        rb,
        1,
        StageShape.pinnedColumn,
        centerVertical: false,
      ),
    );
  }
  return best;
}

/// The pinned item top-left, two stacked at its right (their heights add up to
/// the pinned height), and the rest in rows below.
StageBlock? bento(List<StageItem> items, Rect box, double gap) {
  if (items.length < 3) return null;
  final a0 = items[0].aspect;
  final k = 1 / (1 / items[1].aspect + 1 / items[2].aspect);
  final rest = items.sublist(3);
  final byWidth = (box.width - gap + gap * k) / (a0 + k);
  final byHeight = rest.isEmpty ? box.height : box.height - _minRest - gap;
  final hi = math.min(byWidth, byHeight);
  if (hi <= gap + 20) return null;
  final lo = math.min(hi, box.height * 0.3);
  StageBlock? best;
  for (final hp in _steps(lo, hi)) {
    final pw = hp * a0;
    final ws = (hp - gap) * k;
    final x0 = box.left + (box.width - (pw + gap + ws)) / 2;
    final h1 = ws / items[1].aspect;
    final head = [
      Rect.fromLTWH(x0, box.top, pw, hp),
      Rect.fromLTWH(x0 + pw + gap, box.top, ws, h1),
      Rect.fromLTWH(
        x0 + pw + gap,
        box.top + h1 + gap,
        ws,
        ws / items[2].aspect,
      ),
    ];
    final below = Rect.fromLTRB(
      box.left,
      box.top + hp + gap,
      box.right,
      box.bottom,
    );
    final rb = rest.isEmpty
        ? null
        : justified(rest, below, gap, StageShape.grid);
    best = _better(
      best,
      _compose(box, head, rb, 2, StageShape.bento, centerVertical: true),
    );
  }
  return best;
}
