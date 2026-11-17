// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The title row every sheet opens with, so no sheet restyles its own.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import 'sheet_dialog_scope.dart';

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

  /// Null gets the dialog's [AppSheetCloseButton]; a header that sets its own
  /// trailing action places that button itself.
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
            style: AppText.heading.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
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
    final trailing = this.trailing;
    if (trailing == null && leading == null) {
      return Padding(
        padding: padding,
        child: SheetDialogScope.of(context)
            ? _withCloseButton(context, text)
            : SizedBox(width: double.infinity, child: text),
      );
    }
    return Padding(
      padding: padding,
      child: Row(
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

  /// The close button floats over the title's line, so the title keeps the inset every sheet opens at.
  Widget _withCloseButton(BuildContext context, Widget text) {
    final line = MediaQuery.textScalerOf(
      context,
    ).scale(AppText.heading.fontSize! * (AppText.heading.height ?? 1));
    return Stack(
      children: [
        Padding(
          padding:
              const EdgeInsets.only(right: AppSizes.icon28 + AppSpacing.s8),
          child: SizedBox(width: double.infinity, child: text),
        ),
        Positioned(
          top: 0,
          right: 0,
          width: AppSizes.icon28,
          height: line,
          child: const OverflowBox(
            maxHeight: double.infinity,
            child: AppSheetCloseButton(),
          ),
        ),
      ],
    );
  }
}
