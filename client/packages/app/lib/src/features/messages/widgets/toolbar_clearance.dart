// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/widgets.dart';

/// Keeps a row's first line clear of the hover toolbar, unless that would
/// leave it under [minWidth]; narrower, it runs under the toolbar on hover.
class ToolbarClearance extends StatelessWidget {
  const ToolbarClearance({
    super.key,
    required this.clearance,
    required this.minWidth,
    required this.child,
  });

  /// The room the toolbar needs, from `MessageHoverToolbar.clearance`.
  final EdgeInsets clearance;

  /// The least width [child] keeps once [clearance] is taken off its sides.
  final double minWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Padding(
      padding: box.maxWidth - clearance.horizontal >= minWidth
          ? clearance
          : EdgeInsets.zero,
      child: child,
    ),
  );
}
