// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fits a call's shares, cameras and audio-only people into one box.
///
/// Pure geometry (decision 0114): the caller hands over the box and what is in
/// the call, and gets one rect per tile back. Several layouts are scored and
/// the one covering the most of the box wins, ties going to fewer rows.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'stage_fit_candidates.dart';
import 'stage_fit_people.dart';
import 'stage_item.dart';

export 'stage_item.dart';

/// Where every tile of the call goes inside the stage box.
class StageFit {
  const StageFit({
    required this.items,
    required this.people,
    required this.shape,
    required this.fill,
    this.crop = const {},
    this.peopleCollapsed = false,
    this.peopleOverflow = 0,
  });

  /// One rect per content item, keyed by [StageItem.id].
  final Map<String, Rect> items;

  /// One rect per audio-only person, in input order. Collapsed, these are chips
  /// and the last stands for [peopleOverflow] more people when that is non-zero.
  final List<Rect> people;
  final StageShape shape;

  /// The share of the box the tiles cover, 0 to 1.
  final double fill;

  /// The fraction of a camera's width or height its rect cuts off.
  final Map<String, double> crop;
  final bool peopleCollapsed;
  final int peopleOverflow;
}

/// Lays [content] (pinned item first, shares before cameras) and [people]
/// audio-only tiles out in [box], with [gap] between tiles.
StageFit fitStage({
  required Size box,
  required double gap,
  required List<StageItem> content,
  required int people,
}) {
  final full = Offset.zero & box;
  final boxArea = box.width * box.height;
  if (box.width <= 0 || box.height <= 0 || (content.isEmpty && people == 0)) {
    return const StageFit(
      items: {},
      people: [],
      shape: StageShape.none,
      fill: 0,
    );
  }
  if (content.isEmpty) {
    final tiles = peopleGrid(people, full, gap);
    return StageFit(
      items: const {},
      people: tiles,
      shape: StageShape.peopleGrid,
      fill: _area(tiles) / boxArea,
    );
  }
  final plan = people == 0 ? null : planPeople(people, content, full, gap);
  final region = plan?.contentRegion ?? full;
  final block = bestContent(content, region, gap);
  if (block == null) {
    return const StageFit(
      items: {},
      people: [],
      shape: StageShape.none,
      fill: 0,
    );
  }
  return StageFit(
    items: {
      for (var i = 0; i < content.length; i++) content[i].id: block.rects[i],
    },
    people: plan?.tiles ?? const [],
    shape: block.shape,
    fill: (block.area + _area(plan?.tiles ?? const [])) / boxArea,
    crop: {for (final e in block.crop.entries) content[e.key].id: e.value},
    peopleCollapsed: plan?.collapsed ?? false,
    peopleOverflow: plan?.overflow ?? 0,
  );
}

double _area(List<Rect> rects) =>
    rects.fold(0.0, (sum, r) => sum + r.width * r.height);

/// The share of [box] the best plain even grid of [content] would cover, for comparison.
double plainGridFill(Size box, double gap, List<StageItem> content) {
  final full = Offset.zero & box;
  var best = 0.0;
  for (var cols = 1; cols <= content.length; cols++) {
    best = math.max(best, evenGrid(content, cols, full, gap).area);
  }
  return best / (box.width * box.height);
}
