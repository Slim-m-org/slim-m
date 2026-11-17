// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line that shows where a carried channel or category will land.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Two logical pixels thick, in the accent colour, with a round cap at its
/// start; the caller positions it on the gap between two neighbouring items.
///
/// A [refused] line marks a place a drop does nothing, such as a third
/// category level: danger-toned, with the reason on the carried copy.
class RailInsertionLine extends StatelessWidget {
  const RailInsertionLine({super.key, this.refused = false});

  static const double thickness = 2;

  /// The round cap's diameter.
  static const double cap = AppSpacing.s8;

  final bool refused;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final colour = refused ? tokens.dangerBorder : tokens.accent;
    return SizedBox(
      height: thickness,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colour,
                borderRadius: BorderRadius.circular(thickness / 2),
              ),
            ),
          ),
          Positioned(
            left: -cap / 2,
            top: (thickness - cap) / 2,
            child: DecoratedBox(
              decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
              child: const SizedBox.square(dimension: cap),
            ),
          ),
        ],
      ),
    );
  }
}
