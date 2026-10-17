// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The refresh button beside a readout's section title.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsRefreshButton extends StatelessWidget {
  const SettingsRefreshButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  /// Names what is refreshed, e.g. "Refresh memory readout".
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: AppIcons.retry,
    semanticLabel: label,
    tooltip: label,
    iconSize: AppSizes.icon16,
    onPressed: onPressed,
  );
}
