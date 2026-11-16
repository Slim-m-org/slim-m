// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one column the right-side controls of a settings card share, so
/// segments and sliders end on one edge.
library;

import 'package:flutter/widgets.dart';

const kSettingsControlColumnWidth = 280.0;

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

  @override
  bool updateShouldNotify(SettingsControlColumn oldWidget) =>
      oldWidget.width != width;
}
