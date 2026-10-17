// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Edge scrolling for a carried rail item, so it can travel past the fold.
library;

import 'package:flutter/widgets.dart';

const double _edge = 48;

/// Scrolls the nearest scrollable one step when [pointerY] (global) is within
/// the edge band of its viewport; true when it moved. Faster the deeper in.
bool autoScrollRail(BuildContext context, double pointerY) {
  final scrollable = Scrollable.maybeOf(context);
  final viewport = scrollable?.context.findRenderObject();
  if (scrollable == null || viewport is! RenderBox) return false;
  final area = viewport.localToGlobal(Offset.zero) & viewport.size;
  final double depth;
  if (pointerY < area.top + _edge) {
    depth = -(area.top + _edge - pointerY);
  } else if (pointerY > area.bottom - _edge) {
    depth = pointerY - (area.bottom - _edge);
  } else {
    return false;
  }
  final speed = 2 + 12 * (depth.abs() / _edge).clamp(0.0, 1.0);
  final position = scrollable.position;
  final target = (position.pixels + speed * depth.sign).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if (target == position.pixels) return false;
  position.jumpTo(target);
  return true;
}
