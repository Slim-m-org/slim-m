// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The title row every sheet opens with, so no sheet restyles its own.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';

/// A sheet's heading with an optional one-line [caption], a [leading] mark
/// before the text and a [trailing] action.
class AppSheetHeader extends StatelessWidget {
  const AppSheetHeader(
    this.title, {
    super.key,
    this.caption,
    this.leading,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.s16,
      0,
      AppSpacing.s16,
      AppSpacing.s12,
    ),
  });

  final String title;
  final String? caption;

  /// A thumbnail or chip naming what the sheet acts on, centred on the text.
  final Widget? leading;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: AppText.heading.copyWith(color: tokens.textPrimary),
          ),
        ),
        if (caption case final caption?) ...[
          const SizedBox(height: AppSpacing.s4),
          Text(
            caption,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ],
    );
    return Padding(
      padding: padding,
      child: trailing == null && leading == null
          ? SizedBox(width: double.infinity, child: text)
          : Row(
              children: [
                if (leading case final leading?) ...[
                  leading,
                  const SizedBox(width: AppSpacing.s12),
                ],
                Expanded(child: text),
                if (trailing case final trailing?) trailing,
              ],
            ),
    );
  }
}
