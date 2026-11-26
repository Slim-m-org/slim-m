// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a group of boxes goes for an align or a distribute.
library;

import 'canvas_object_previews.dart' show ObjectBox;

enum CanvasAlign {
  left,
  centre,
  right,
  top,
  middle,
  bottom,
  distributeHorizontally,
  distributeVertically;

  /// Distributing spreads the ones between the outermost two, so it needs a third.
  int get minimumCount => name.startsWith('distribute') ? 3 : 2;
}

/// The box each id takes for [mode]; only positions change, never sizes.
Map<String, ObjectBox> alignBoxes(
  Map<String, ObjectBox> boxes,
  CanvasAlign mode,
) {
  if (boxes.length < mode.minimumCount) return boxes;
  final values = boxes.values;
  final left = values.map((b) => b.x).reduce((a, b) => a < b ? a : b);
  final top = values.map((b) => b.y).reduce((a, b) => a < b ? a : b);
  final right = values.map((b) => b.x + b.w).reduce((a, b) => a > b ? a : b);
  final bottom = values.map((b) => b.y + b.h).reduce((a, b) => a > b ? a : b);
  ObjectBox at(ObjectBox b, {double? x, double? y}) =>
      (x: x ?? b.x, y: y ?? b.y, w: b.w, h: b.h);
  return switch (mode) {
    CanvasAlign.left => {
        for (final e in boxes.entries) e.key: at(e.value, x: left)
      },
    CanvasAlign.right => {
        for (final e in boxes.entries) e.key: at(e.value, x: right - e.value.w),
      },
    CanvasAlign.centre => {
        for (final e in boxes.entries)
          e.key: at(e.value, x: (left + right) / 2 - e.value.w / 2),
      },
    CanvasAlign.top => {
        for (final e in boxes.entries) e.key: at(e.value, y: top)
      },
    CanvasAlign.bottom => {
        for (final e in boxes.entries)
          e.key: at(e.value, y: bottom - e.value.h),
      },
    CanvasAlign.middle => {
        for (final e in boxes.entries)
          e.key: at(e.value, y: (top + bottom) / 2 - e.value.h / 2),
      },
    CanvasAlign.distributeHorizontally => _distribute(
        boxes,
        start: (b) => b.x,
        size: (b) => b.w,
        place: (b, p) => at(b, x: p),
      ),
    CanvasAlign.distributeVertically => _distribute(
        boxes,
        start: (b) => b.y,
        size: (b) => b.h,
        place: (b, p) => at(b, y: p),
      ),
  };
}

/// Equal gaps between neighbours along one axis, the first and last staying put.
Map<String, ObjectBox> _distribute(
  Map<String, ObjectBox> boxes, {
  required double Function(ObjectBox) start,
  required double Function(ObjectBox) size,
  required ObjectBox Function(ObjectBox, double) place,
}) {
  final order = boxes.keys.toList()
    ..sort((a, b) => start(boxes[a]!).compareTo(start(boxes[b]!)));
  final first = boxes[order.first]!;
  final last = boxes[order.last]!;
  final span = start(last) + size(last) - start(first);
  final used = order.fold<double>(0, (sum, id) => sum + size(boxes[id]!));
  final gap = (span - used) / (order.length - 1);
  final out = <String, ObjectBox>{};
  var cursor = start(first);
  for (final id in order) {
    final box = boxes[id]!;
    out[id] = place(box, cursor);
    cursor += size(box) + gap;
  }
  return {for (final id in boxes.keys) id: out[id]!};
}
