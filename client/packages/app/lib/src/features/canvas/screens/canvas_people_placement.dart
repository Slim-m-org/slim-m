// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the facepile sits: in the bar when the bar shows at pointer width, else in the board's readout.
library;

import 'package:flutter/widgets.dart';

/// Tells the board's readout that the bar already carries the facepile, so it leaves it out.
class CanvasPeopleInBar extends InheritedWidget {
  const CanvasPeopleInBar({
    super.key,
    required this.inBar,
    required super.child,
  });

  final bool inBar;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CanvasPeopleInBar>()?.inBar ??
      false;

  @override
  bool updateShouldNotify(CanvasPeopleInBar oldWidget) =>
      inBar != oldWidget.inBar;
}
