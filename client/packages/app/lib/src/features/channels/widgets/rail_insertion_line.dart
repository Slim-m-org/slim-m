// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line that shows where a carried channel or category will land.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Two logical pixels thick, in the accent colour, with a round cap at its
/// start; the caller positions it on the gap between two neighbouring items.
class RailInsertionLine extends StatelessWidget {
  const RailInsertionLine({super.key});

  static const double thickness = 2;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    const cap = AppSpacing.s8;
    return SizedBox(
      height: thickness,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.accent,
                borderRadius: BorderRadius.circular(thickness / 2),
              ),
            ),
          ),
          Positioned(
            left: -cap / 2,
            top: (thickness - cap) / 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.accent,
                shape: BoxShape.circle,
              ),
              child: const SizedBox.square(dimension: cap),
            ),
          ),
        ],
      ),
    );
  }
}
