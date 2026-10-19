// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tinted strip a settings row shows its measured results in.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Lines up under a row's text, past its icon tile.
class SettingsResultInset extends StatelessWidget {
  const SettingsResultInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.fromLTRB(62, 6, AppSpacing.s16, 6),
      color: Color.lerp(tokens.surfaceBase, tokens.surfaceRaised, 0.5),
      child: child,
    );
  }
}
