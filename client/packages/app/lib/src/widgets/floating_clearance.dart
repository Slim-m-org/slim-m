// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Room a card floating over a pane takes from its bottom edge, so a list in
/// that pane can end above the card rather than under it.
library;

import 'package:flutter/widgets.dart';

class FloatingClearance extends InheritedWidget {
  const FloatingClearance({
    super.key,
    required this.bottom,
    required super.child,
  });

  /// How far above the pane's content bottom the floating card reaches; 0 for none.
  final double bottom;

  static double bottomOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FloatingClearance>()?.bottom ??
      0;

  @override
  bool updateShouldNotify(FloatingClearance oldWidget) =>
      bottom != oldWidget.bottom;
}
