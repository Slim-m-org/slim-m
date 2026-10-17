// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mic-off mark on a voice channel row that starts joiners muted.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class RailJoinMutedGlyph extends StatelessWidget {
  const RailJoinMutedGlyph({super.key});

  static const label = 'Joins muted';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Tooltip(
      message: label,
      child: Icon(
        AppIcons.micOff,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
        semanticLabel: label,
      ),
    );
  }
}
