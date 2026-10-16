// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A one-line aside inside a flush settings card: an info glyph and a caption.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsInfoLine extends StatelessWidget {
  const SettingsInfoLine(
    this.text, {
    super.key,
    this.tinted = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.s16,
      vertical: 10,
    ),
  });

  final String text;

  /// Sub-row tint, for a line that belongs to the rows above it.
  final bool tinted;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      color: tinted
          ? Color.lerp(tokens.surfaceBase, tokens.surfaceRaised, 0.5)
          : null,
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s8,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              AppIcons.info,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
