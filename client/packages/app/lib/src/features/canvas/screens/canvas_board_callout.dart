// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A warning laid over the board, on a solid surface so ink under it never
/// shows through the callout's tinted fill.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class CanvasBoardCallout extends StatelessWidget {
  const CanvasBoardCallout(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s12,
        0,
        AppSpacing.s12,
        AppSpacing.s12,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: AppCallout(child: Text(message)),
      ),
    );
  }
}
