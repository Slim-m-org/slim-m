// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rows that share one slot of a flush settings card, with the card's own
/// hairline between them.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsRowGroup extends StatelessWidget {
  const SettingsRowGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            Divider(height: 1, thickness: 1, color: tokens.borderSubtle),
          children[i],
        ],
      ],
    );
  }
}
