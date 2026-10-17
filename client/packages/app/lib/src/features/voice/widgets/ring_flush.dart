// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lines an `AppInput`'s visible box up with the cards around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

/// An `AppInput` reserves a 2px focus ring and a 2px gutter on every side, so
/// outside a card its box sits 4px inside its neighbours' edges.
const double appInputRingReserve = 4;

/// Lets [child] overflow its slot by [appInputRingReserve] on both sides, so
/// the input's box is as wide as the sibling cards instead of 8px narrower.
class RingFlush extends StatelessWidget {
  const RingFlush({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth + 2 * appInputRingReserve;
      return OverflowBox(
        fit: OverflowBoxFit.deferToChild,
        minWidth: width,
        maxWidth: width,
        child: child,
      );
    },
  );
}
