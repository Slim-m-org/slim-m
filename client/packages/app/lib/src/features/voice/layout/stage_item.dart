// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the stage fit lays out, and the shapes it can choose.
library;

enum StageKind { share, camera }

enum StageShape { none, peopleGrid, grid, pinnedRow, pinnedColumn, bento }

/// How much of a camera's width or height a row may cut to line up.
const double stageMaxCrop = 0.15;

/// One share or camera tile; [aspect] is width over height.
class StageItem {
  const StageItem(this.id, this.kind, this.aspect);

  final String id;
  final StageKind kind;
  final double aspect;
}

/// A stage this much taller than wide is a portrait stage (a phone or tablet held upright).
const double stagePortraitRatio = 1.1;

/// What a camera lays out at on a portrait stage, so it fills the height a 16:9 tile would strand.
const double stagePortraitCameraAspect = 3 / 4;

/// [items] as the fit lays them out in a box of [width] by [height].
///
/// Shares always keep their own aspect; only cameras take the portrait shape.
List<StageItem> stageLayoutItems(
  List<StageItem> items,
  double width,
  double height,
) {
  if (height < width * stagePortraitRatio) return items;
  return [
    for (final i in items)
      i.kind == StageKind.camera && i.aspect > stagePortraitCameraAspect
          ? StageItem(i.id, i.kind, stagePortraitCameraAspect)
          : i,
  ];
}
