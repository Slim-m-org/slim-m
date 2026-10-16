// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rows for a flush settings card that carry an icon tile and a second line:
/// the design's `.row` with a `.lead` tile, `.lab` and `.dm`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';

/// The 32px sunken rounded square a row's glyph sits on.
class SettingsIconTile extends StatelessWidget {
  const SettingsIconTile(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: Container(
        width: AppSizes.icon32,
        height: AppSizes.icon32,
        decoration: BoxDecoration(
          color: tokens.surfaceBase,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Icon(icon, size: 18, color: tokens.textSecondary),
      ),
    );
  }
}

/// A card row: tile, title with an optional badge, one detail line, trailing.
class SettingsDetailRow extends StatelessWidget {
  const SettingsDetailRow({
    super.key,
    required this.title,
    this.icon,
    this.badge,
    this.detail,
    this.monoDetail = false,
    this.trailing,
    this.dimmed = false,
  });

  final String title;
  final IconData? icon;
  final Widget? badge;
  final String? detail;

  /// Machine-ish detail (versions, ids) reads in the mono face.
  final bool monoDetail;
  final Widget? trailing;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final metrics = SettingsRowMetrics.of(context);
    final detailStyle = AppText.caption.copyWith(
      color: tokens.textSecondary,
      fontFamily: monoDetail ? AppFonts.mono : null,
    );
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical + 2,
        ),
        child: Row(
          spacing: 14,
          children: [
            if (icon != null) SettingsIconTile(icon!),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  Row(
                    spacing: AppSpacing.s8,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.ui.copyWith(color: tokens.textPrimary),
                        ),
                      ),
                      ?badge,
                    ],
                  ),
                  if (detail != null) Text(detail!, style: detailStyle),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
    return dimmed ? Opacity(opacity: 0.6, child: row) : row;
  }
}

/// A row that is a sentence with its action beside it.
class SettingsActionRow extends StatelessWidget {
  const SettingsActionRow({
    super.key,
    required this.message,
    required this.action,
  });

  final String message;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final metrics = SettingsRowMetrics.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical + 2,
        ),
        child: Row(
          spacing: 14,
          children: [
            Expanded(
              child: Text(
                message,
                style: AppText.caption.copyWith(color: tokens.textPrimary),
              ),
            ),
            action,
          ],
        ),
      ),
    );
  }
}

/// The mono uppercase label that names a group of rows inside a card.
class SettingsGroupLabelRow extends StatelessWidget {
  const SettingsGroupLabelRow(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppCardRowScope.inset,
        12,
        AppCardRowScope.inset,
        6,
      ),
      child: Text(
        label.toUpperCase(),
        style: AppText.micro.copyWith(
          color: tokens.textSecondary,
          fontFamily: AppFonts.mono,
          letterSpacing: AppText.micro.fontSize! * 0.06,
        ),
      ),
    );
  }
}
