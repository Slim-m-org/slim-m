// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line that shows where a carried channel or category will land.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:slimm_design_system/design_system.dart';

/// Two logical pixels thick, in the accent colour, with a round cap at its
/// start; the caller positions it on the gap between two neighbouring items.
///
/// A [refused] line marks a place a drop does nothing, such as a third
/// category level: danger-toned, with the reason beneath it.
class RailInsertionLine extends StatelessWidget {
  const RailInsertionLine({super.key, this.refused = false});

  static const double thickness = 2;

  /// What a refused line says, short enough for the compact rail.
  static const refusedReason = 'Two levels at most';

  final bool refused;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final colour = refused ? tokens.dangerBorder : tokens.accent;
    const cap = AppSpacing.s8;
    final line = SizedBox(
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
    if (!refused) return line;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line,
        const SizedBox(height: AppSpacing.s4),
        // Ends with the line and grows left past a deep line's start, so it never wraps.
        OverflowBox(
          alignment: Alignment.topRight,
          minWidth: 0,
          maxWidth: double.infinity,
          fit: OverflowBoxFit.deferToChild,
          child: _RefusedReason(tokens: tokens),
        ),
      ],
    );
  }
}

class _RefusedReason extends StatelessWidget {
  const _RefusedReason({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.dangerBorder),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s8,
          vertical: AppSpacing.s4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.notAllowed,
              size: AppSizes.icon16,
              color: tokens.dangerText,
            ),
            const SizedBox(width: AppSpacing.s4),
            Text(
              RailInsertionLine.refusedReason,
              maxLines: 1,
              style: AppText.caption.copyWith(color: tokens.dangerText),
            ),
          ],
        ),
      ),
    );
  }
}
