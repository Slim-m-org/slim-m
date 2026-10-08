// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The whole-interface scale (decision 0062): the child is laid out at the
/// available size divided by the scale, then painted scaled to fill it.
library;

import 'package:flutter/widgets.dart';

/// [data] as the scaled tree should see it: every length divided by [scale],
/// so width breakpoints and safe-area insets read the effective size.
MediaQueryData scaleMediaQuery(MediaQueryData data, double scale) {
  if (scale == 1) return data;
  EdgeInsets shrink(EdgeInsets e) => e / scale;
  return data.copyWith(
    size: data.size / scale,
    padding: shrink(data.padding),
    viewPadding: shrink(data.viewPadding),
    viewInsets: shrink(data.viewInsets),
    systemGestureInsets: shrink(data.systemGestureInsets),
  );
}

class UiScaleFrame extends StatelessWidget {
  const UiScaleFrame({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (scale == 1) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: constraints.maxWidth / scale,
            height: constraints.maxHeight / scale,
            child: child,
          ),
        );
      },
    );
  }
}
