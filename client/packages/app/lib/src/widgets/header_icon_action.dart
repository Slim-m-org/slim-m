// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An icon action in a pane header, wide or compact: named by a tooltip on
/// hover and keyboard focus, and never by one on touch.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class HeaderIconAction extends StatelessWidget {
  const HeaderIconAction({
    super.key,
    required this.icon,
    required this.label,
    this.semanticLabel,
    this.active,
    this.touch,
    this.onPressed,
  });

  final IconData icon;

  /// The tooltip, and the accessible name unless [semanticLabel] says more.
  final String label;
  final String? semanticLabel;
  final bool? active;

  /// Null follows [AppTouchTargets.of].
  final bool? touch;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final touch = this.touch ?? AppTouchTargets.of(context);
    return AppIconButton(
      icon: icon,
      semanticLabel: semanticLabel ?? label,
      tooltip: touch ? null : label,
      touch: touch,
      active: active,
      onPressed: onPressed,
    );
  }
}
