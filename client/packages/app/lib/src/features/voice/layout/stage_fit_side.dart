// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bento for a few audio-only people beside shares or cameras on a wide
/// stage: one column at the content's right, flush with its top, the tiles
/// stretched to its full height when that keeps them a sensible shape.
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'stage_fit_candidates.dart';
import 'stage_item.dart';

/// The most people the column takes; more keep the strip below.
const int stageSideMaxPeople = 4;

/// The narrowest stage the column is tried on; a phone keeps the strip.
const double _minStageWidth = 640;
const double _columnShare = 0.2;
const double _columnMin = 160;
const double _columnMax = 320;
const double _naturalHeight = 0.8;
const double _tallestAspect = 0.8;
const double _widestAspect = 2.2;

/// The content laid out beside a column of [people] tiles, the whole block
/// centred in [box]; null when the stage is too narrow or the tiles would not keep their shape.
({StageBlock block, List<Rect> tiles})? sideBento(
  int people,
  ContentFits fits,
  Rect box,
  double gap,
) {
  if (people < 1 || people > stageSideMaxPeople) return null;
  if (box.width < _minStageWidth || box.width <= box.height) return null;
  final column = (box.width * _columnShare).clamp(_columnMin, _columnMax);
  final region = Rect.fromLTRB(
    box.left,
    box.top,
    box.right - column - gap,
    box.bottom,
  );
  final block = fits.best(region);
  if (block == null) return null;
  final bounds = block.rects.reduce((a, b) => a.expandToInclude(b));
  final heights = _tileHeights(people, column, bounds.height, gap);
  if (heights == null) return null;
  final dx = box.left + (box.width - (bounds.width + gap + column)) / 2;
  final shifted = block.shifted(dx - bounds.left, 0);
  final x = dx + bounds.width + gap;
  var y = bounds.top;
  final tiles = <Rect>[];
  for (final h in heights) {
    tiles.add(Rect.fromLTWH(x, y, column, h));
    y += h + gap;
  }
  if (!_neverBeatsACamera(fits.items, shifted, tiles.first)) return null;
  return (block: shifted, tiles: tiles);
}

/// Several tiles stretch towards [height], no taller than [_tallestAspect] allows; one stays at its natural shape.
List<double>? _tileHeights(
  int people,
  double width,
  double height,
  double gap,
) {
  final stretched = (height - (people - 1) * gap) / people;
  final aspect = width / stretched;
  if (aspect > _widestAspect) return null;
  if (people > 1) {
    return List.filled(people, math.min(stretched, width / _tallestAspect));
  }
  return [math.min(width * _naturalHeight, stretched)];
}

bool _neverBeatsACamera(List<StageItem> content, StageBlock block, Rect tile) {
  for (var i = 0; i < content.length; i++) {
    final r = block.rects[i];
    if (content[i].kind == StageKind.camera &&
        r.width * r.height < tile.width * tile.height) {
      return false;
    }
  }
  return true;
}
