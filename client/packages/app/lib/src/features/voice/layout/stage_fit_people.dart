// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the audio-only people go: the whole box when nothing else is on
/// stage, otherwise small uniform tiles in a strip or column, or chips.
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'stage_fit_candidates.dart';
import 'stage_item.dart';

/// The narrowest an avatar tile gets before the people collapse to chips.
const double stagePersonMinWidth = 96;
const double _personMaxWidth = 160;
const double _personTileHeight = 0.8;
const double _gridTileHeight = 0.625;

/// The height of a collapsed chip.
const double stageChipHeight = 32;
const double _chipWidth = 120;
const double _narrowStage = 480;

/// A smaller person tile has to fill this much more of the box to win.
const double _tileBar = 1.005;

/// On a wide stage people stay readable unless shrinking them gains 8%.
const double _wideTileBar = 1.08;
const double _wideStage = 640;

/// Bigger person tiles never cost the content more than a fifth of its area.
const double _contentKept = 0.8;

/// The people's tiles and the box left for the content.
class PeoplePlan {
  const PeoplePlan(
    this.contentRegion,
    this.tiles, {
    this.collapsed = false,
    this.overflow = 0,
  });

  final Rect contentRegion;
  final List<Rect> tiles;
  final bool collapsed;
  final int overflow;
}

/// Every person as one uniform tile over the whole [box].
List<Rect> peopleGrid(int count, Rect box, double gap) {
  var bestW = 0.0;
  var bestCols = 1;
  for (var cols = 1; cols <= count; cols++) {
    final rows = (count / cols).ceil();
    final w = math.min(
      (box.width - (cols - 1) * gap) / cols,
      (box.height - (rows - 1) * gap) / rows / _gridTileHeight,
    );
    if (w > bestW * 1.005) {
      bestW = w;
      bestCols = cols;
    }
  }
  return _tiles(count, bestCols, bestW, bestW * _gridTileHeight, box, gap);
}

/// [count] tiles of [w] x [h] in [cols] columns, the last row centred, the block centred in [box].
List<Rect> _tiles(
  int count,
  int cols,
  double w,
  double h,
  Rect box,
  double gap,
) {
  final rows = (count / cols).ceil();
  final top = box.top + (box.height - (rows * h + (rows - 1) * gap)) / 2;
  Rect tile(int i) {
    final row = i ~/ cols;
    final inRow = row == rows - 1 ? count - row * cols : cols;
    final x0 = box.left + (box.width - (inRow * w + (inRow - 1) * gap)) / 2;
    return Rect.fromLTWH(
      x0 + (i - row * cols) * (w + gap),
      top + row * (h + gap),
      w,
      h,
    );
  }

  return [for (var i = 0; i < count; i++) tile(i)];
}

/// Reserves the strip, column or chip row that gives [content] plus [people] tiles the most of [box].
PeoplePlan planPeople(int people, ContentFits fits, Rect box, double gap) {
  var best = _best(people, fits, box, gap, column: false);
  final column = _best(people, fits, box, gap, column: true);
  if (column != null && (best == null || column.$1 > best.$1 * 1.15)) {
    best = column;
  }
  return best?.$2 ?? _chips(people, box, gap);
}

(double, PeoplePlan)? _best(
  int people,
  ContentFits fits,
  Rect box,
  double gap, {
  required bool column,
}) {
  final scored = <(_Score, PeoplePlan)>[];
  for (var w = _personMaxWidth; w >= stagePersonMinWidth; w -= 16) {
    for (final stretch in column ? const [false] : const [false, true]) {
      final plan = column
          ? _columnPlan(people, w, box, gap)
          : _stripPlan(people, w, box, gap, stretch: stretch);
      if (plan == null) continue;
      final score = _score(plan, people, fits);
      if (score != null) scored.add((score, plan));
    }
  }
  if (scored.isEmpty) return null;
  final fullest = scored.reduce((a, b) => b.$1.fill > a.$1.fill ? b : a).$1;
  final bar = _isWide(box) ? _wideTileBar : _tileBar;
  // Widest first, so the biggest tiles within the bar of the fullest plan win.
  final (score, plan) = scored.firstWhere(
    (s) =>
        s.$1.fill * bar >= fullest.fill &&
        s.$1.content >= fullest.content * _contentKept,
  );
  return (score.fill, plan);
}

typedef _Score = ({double fill, double content});

bool _isWide(Rect box) => box.width >= _wideStage && box.width > box.height;

_Score? _score(PeoplePlan plan, int people, ContentFits fits) {
  final content = fits.items;
  final block = fits.best(plan.contentRegion);
  if (block == null) return null;
  final tile = plan.tiles.first;
  final cameras = [
    for (var i = 0; i < content.length; i++)
      if (content[i].kind == StageKind.camera)
        block.rects[i].width * block.rects[i].height,
  ];
  // Audio-only people take what is left and are never bigger than a camera.
  if (cameras.isNotEmpty &&
      tile.width * tile.height > cameras.reduce(math.min)) {
    return null;
  }
  return (
    fill: block.area + people * tile.width * tile.height,
    content: block.area,
  );
}

PeoplePlan? _stripPlan(
  int people,
  double w,
  Rect box,
  double gap, {
  bool stretch = false,
}) {
  final h = w * _personTileHeight;
  final cols = math.min(people, ((box.width + gap) / (w + gap)).floor());
  if (cols < 1) return null;
  final rows = (people / cols).ceil();
  final height = rows * h + (rows - 1) * gap;
  if (height > box.height * 0.4) return null;
  final region = Rect.fromLTWH(
    box.left,
    box.bottom - height,
    box.width,
    height,
  );
  // On a narrow stage a single row shares the stacked tiles' width.
  final wide = stretch && rows == 1 && box.width < _narrowStage
      ? (box.width - (people - 1) * gap) / people
      : w;
  return PeoplePlan(
    Rect.fromLTRB(box.left, box.top, box.right, region.top - gap),
    _tiles(people, cols, wide, h, region, gap),
  );
}

PeoplePlan? _columnPlan(int people, double w, Rect box, double gap) {
  final h = w * _personTileHeight;
  final perColumn = math.max(1, ((box.height + gap) / (h + gap)).floor());
  final cols = (people / perColumn).ceil();
  final width = cols * w + (cols - 1) * gap;
  if (width > box.width * 0.3) return null;
  final region = Rect.fromLTWH(box.right - width, box.top, width, box.height);
  return PeoplePlan(
    Rect.fromLTRB(box.left, box.top, region.left - gap, box.bottom),
    _tiles(people, cols, w, h, region, gap),
  );
}

PeoplePlan _chips(int people, Rect box, double gap) {
  final fit = math.max(1, ((box.width + gap) / (_chipWidth + gap)).floor());
  final shown = math.min(people, fit);
  final width = shown * _chipWidth + (shown - 1) * gap;
  final top = box.bottom - stageChipHeight;
  final x0 = box.left + (box.width - width) / 2;
  return PeoplePlan(
    Rect.fromLTRB(box.left, box.top, box.right, top - gap),
    [
      for (var i = 0; i < shown; i++)
        Rect.fromLTWH(
          x0 + i * (_chipWidth + gap),
          top,
          _chipWidth,
          stageChipHeight,
        ),
    ],
    collapsed: true,
    overflow: people > shown ? people - (shown - 1) : 0,
  );
}
