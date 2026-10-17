// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

/// What [EmojiGrid] and whatever steers its highlight both need: the column
/// count, so ArrowUp and ArrowDown move a row rather than a cell, and the
/// scroll position, so the highlighted row stays on screen.
///
/// The grid writes [columns] on every layout, since the count follows the
/// width a surface gives it; the owner only reads it. Both depend on the same
/// formula `SliverGridDelegateWithMaxCrossAxisExtent` uses, which is why that
/// arithmetic lives here and not at each caller.
class EmojiGridNavigator {
  final ScrollController scroll = ScrollController();

  /// Cells per row as of the last layout; 1 until there has been one.
  int columns = 1;

  double _stride = 0;
  double _cell = 0;

  /// The grid's padding and gaps, shared with the [GridView] it configures.
  static const double padding = AppSpacing.s8;
  static const double gap = AppSpacing.s4;

  void dispose() => scroll.dispose();

  /// Recomputes [columns] and the row height for a grid [width] wide whose
  /// cells are at most [maxCellExtent] across.
  void layout(double width, double maxCellExtent) {
    final extent = math.max(0.0, width - 2 * padding);
    columns = math.max(1, (extent / (maxCellExtent + gap)).ceil());
    _cell = math.max(0.0, extent - gap * (columns - 1)) / columns;
    _stride = _cell + gap;
  }

  /// The highlight after one ArrowUp ([rows] -1) or ArrowDown (+1).
  ///
  /// Entering from no highlight lands on the first cell going down and the
  /// last going up. A move past the last row of a short final row lands on its
  /// last cell, and a move off either end stays put: unlike a single list, a
  /// grid has no sensible wrap.
  int step(int highlighted, int count, int rows) {
    if (count == 0) return -1;
    if (highlighted < 0) return rows > 0 ? 0 : count - 1;
    final target = highlighted + rows * columns;
    if (target < 0) return highlighted;
    if (target < count) return target;
    final onLastRow = highlighted ~/ columns == (count - 1) ~/ columns;
    return onLastRow ? highlighted : count - 1;
  }

  /// Scrolls just far enough that the row holding [index] is fully visible,
  /// keeping the grid's own padding in view at either end.
  ///
  /// Never clamped to `maxScrollExtent`: a grid only estimates that until it
  /// has laid out the rows near the end, and the estimate is far too small
  /// when the target is many rows past what is built.
  void reveal(int index) {
    if (index < 0 || !scroll.hasClients) return;
    final position = scroll.position;
    final top = padding + (index ~/ columns) * _stride;
    final bottom = top + _cell;
    var target = position.pixels;
    if (top - padding < position.pixels) {
      target = top - padding;
    } else if (bottom + padding >
        position.pixels + position.viewportDimension) {
      target = bottom + padding - position.viewportDimension;
    }
    scroll.jumpTo(math.max(0.0, target));
  }
}
