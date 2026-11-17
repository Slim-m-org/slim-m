// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small framed preview a file gets while it waits to be uploaded, in
/// Create emoji and Create clip alike.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsFileThumb extends StatelessWidget {
  const SettingsFileThumb({super.key, required this.child});

  /// The file itself where it can be drawn, otherwise an icon for its kind.
  final Widget child;

  /// The frame's edge, which a picture inside is decoded to.
  static const double size = AppSizes.icon32;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: child,
    );
  }
}
