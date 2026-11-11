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
