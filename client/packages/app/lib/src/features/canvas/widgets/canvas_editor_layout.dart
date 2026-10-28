// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a canvas object's in-place editor sits: over the object, kept inside the board and clear of the keyboard.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

/// The narrowest the editor gets, so a small object still has room to type.
const double canvasEditorMinWidth = 280;

/// Puts an in-place editor panel over an object's top left, slid back inside [area] (the
/// board on screen) when the note is near an edge or the keyboard covers it.
class CanvasEditorLayout extends SingleChildLayoutDelegate {
  const CanvasEditorLayout({
    required this.area,
    required this.anchor,
    required this.objectWidth,
    required this.keyboardInset,
    this.bottomInset = 0,
  });

  static const double _margin = AppSpacing.s8;

  final Rect? area;
  final Offset anchor;
  final double objectWidth;
  final double keyboardInset;
  final double bottomInset;

  Rect _bounds(Size size) {
    final screen = Offset.zero & size;
    return area == null ? screen : screen.intersect(area!);
  }

  /// The lowest the panel may reach: the board's bottom, or above the dock/keyboard.
  double _floor(Size size, Rect bounds) => math.min(
    bounds.bottom,
    size.height - math.max(keyboardInset, bottomInset),
  );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final room = math.max(
      0.0,
      _bounds(constraints.biggest).width - _margin * 2,
    );
    final width = objectWidth
        .clamp(math.min(canvasEditorMinWidth, room), room)
        .toDouble();
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight:
          (_floor(constraints.biggest, _bounds(constraints.biggest)) -
                  _bounds(constraints.biggest).top -
                  _margin * 2)
              .clamp(0, double.infinity)
              .toDouble(),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = _bounds(size);
    final minX = bounds.left + _margin;
    final minY = bounds.top + _margin;
    final maxX = bounds.right - childSize.width - _margin;
    final maxY = _floor(size, bounds) - childSize.height - _margin;
    return Offset(
      anchor.dx.clamp(minX, maxX < minX ? minX : maxX).toDouble(),
      anchor.dy.clamp(minY, maxY < minY ? minY : maxY).toDouble(),
    );
  }

  @override
  bool shouldRelayout(CanvasEditorLayout old) =>
      old.area != area ||
      old.anchor != anchor ||
      old.objectWidth != objectWidth ||
      old.keyboardInset != keyboardInset ||
      old.bottomInset != bottomInset;
}
