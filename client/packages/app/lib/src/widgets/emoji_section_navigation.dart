// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keyboard geometry for [EmojiSectionedGrid]: which flat index an arrow key
/// lands on, and where that cell sits, computed from the sections alone so it
/// works for a cell the lazy grid has not built.
library;

import 'dart:math' as math;

import 'package:slimm_design_system/design_system.dart';

import 'emoji_catalog.dart';
import 'emoji_picker_grid.dart';
import 'emoji_sectioned_grid.dart';

class EmojiSectionNavigation {
  EmojiSectionNavigation({
    required this.sections,
    required double crossAxisExtent,
  }) {
    const spacing = AppSpacing.s4;
    columns = math.max(
      1,
      (crossAxisExtent / (EmojiGrid.cellExtent + spacing)).ceil(),
    );
    _cell = math.max(0.0, crossAxisExtent - spacing * (columns - 1)) / columns;
    var start = 0;
    for (final section in sections) {
      _starts.add(start);
      start += section.emoji.length;
    }
  }

  final List<EmojiSection> sections;

  /// Cells per row, by the formula `SliverGridDelegateWithMaxCrossAxisExtent`
  /// itself uses.
  late final int columns;
  late final double _cell;
  final List<int> _starts = [];

  double get _stride => _cell + AppSpacing.s4;

  /// The flat index one row up ([rows] -1) or down (+1) from [highlighted].
  ///
  /// Leaving a section's first or last row enters its neighbour in the same
  /// column; a move off either end of the whole list stays put.
  int stepRow(int highlighted, int rows) {
    final s = _sectionOf(highlighted);
    if (s == null) return highlighted;
    final count = sections[s].emoji.length;
    final local = highlighted - _starts[s];
    final target = local + rows * columns;
    if (target >= 0 && target < count) return _starts[s] + target;
    final column = local % columns;
    if (rows > 0) {
      if (local ~/ columns < (count - 1) ~/ columns) {
        return _starts[s] + count - 1;
      }
      final next = _firstFilled(s + 1, 1);
      if (next == null) return highlighted;
      return _starts[next] + math.min(column, sections[next].emoji.length - 1);
    }
    final previous = _firstFilled(s - 1, -1);
    if (previous == null) return highlighted;
    final length = sections[previous].emoji.length;
    final lastRow = (length - 1) ~/ columns * columns;
    return _starts[previous] + math.min(lastRow + column, length - 1);
  }

  int? _sectionOf(int index) {
    for (var s = 0; s < sections.length; s++) {
      if (index >= _starts[s] &&
          index < _starts[s] + sections[s].emoji.length) {
        return s;
      }
    }
    return null;
  }

  int? _firstFilled(int from, int direction) {
    for (var s = from; s >= 0 && s < sections.length; s += direction) {
      if (sections[s].emoji.isNotEmpty) return s;
    }
    return null;
  }

  /// The scroll offset that brings the row holding [index] fully into a
  /// viewport [viewport] tall currently scrolled to [pixels], or [pixels]
  /// itself when it already is.
  double reveal(int index, double pixels, double viewport) {
    final top = _rowTop(index);
    final bottom = top + _cell;
    if (top < pixels) return top;
    if (bottom > pixels + viewport) return bottom - viewport;
    return pixels;
  }

  double _rowTop(int index) {
    var offset = 0.0;
    for (var s = 0; s < sections.length; s++) {
      final count = sections[s].emoji.length;
      offset += EmojiSectionedGrid.headerHeight;
      if (index < _starts[s] + count) {
        return offset + (index - _starts[s]) ~/ columns * _stride;
      }
      final rows = (count / columns).ceil();
      final gridHeight = count == 0 ? 0.0 : rows * _stride - AppSpacing.s4;
      offset += gridHeight + EmojiSectionedGrid.sectionGap;
    }
    return offset;
  }
}
