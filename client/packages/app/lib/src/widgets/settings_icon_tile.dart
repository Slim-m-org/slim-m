// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small rounded square that leads a settings row with its glyph.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsIconTile extends StatelessWidget {
  const SettingsIconTile(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Icon(icon, size: AppSizes.icon16, color: tokens.textSecondary),
    );
  }
}
