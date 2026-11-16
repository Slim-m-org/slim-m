// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one column the right-side controls of a settings card share, so
/// segments and sliders end on one edge.
library;

import 'package:flutter/widgets.dart';

const kSettingsControlColumnWidth = 280.0;

/// From this much content width a row puts its control in the column; below
/// it, the control drops under its label and spans the row.
const kSettingsControlColumnFrom = 480.0;

/// Marks a subtree whose rows put their control in a [width] column.
class SettingsControlColumn extends InheritedWidget {
  const SettingsControlColumn({
    super.key,
    this.width = kSettingsControlColumnWidth,
    required super.child,
  });

  final double width;

  /// Null outside a column, where a row sizes its control to fit.
  static double? widthOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsControlColumn>()
      ?.width;

  /// Whether a row [rowWidth] wide keeps its control beside its label.
  static bool besideAt(double rowWidth) =>
      rowWidth >= kSettingsControlColumnFrom;

  @override
  bool updateShouldNotify(SettingsControlColumn oldWidget) =>
      oldWidget.width != width;
}
