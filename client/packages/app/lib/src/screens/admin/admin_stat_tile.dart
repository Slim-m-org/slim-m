// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The headline-number card the storage, server metrics and analytics screens
/// share. Its width is a named constant so the loading ghost can match it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

const double adminStatTileWidth = 150;

class AdminStatTile extends StatelessWidget {
  const AdminStatTile({
    super.key,
    required this.label,
    required this.value,
    this.warn = false,
  });

  final String label;
  final String value;

  /// Highlights the value in the danger color - a pool at its ceiling, say -
  /// rather than leaving a bottleneck signal looking like any other number.
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox(
      width: adminStatTileWidth,
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: AppText.heading.copyWith(
                color: warn ? tokens.dangerText : tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              label,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
