// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The container vocabulary every settings screen is built from: a section is
/// a [SettingsSectionHeader] above a [SettingsSectionCard] of edge-to-edge
/// rows. See docs/decisions/0013-settings-container-system.md.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_hairline.dart';

/// The default space above a section's title.
const double kSettingsSectionTopGap = 28;

/// For a pane of many short cards, like Profile.
const double kDenseSectionTopGap = 18;

/// A section's title and optional one-line description, above its card.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(
    this.title, {
    super.key,
    this.description,
    this.topGap = kSettingsSectionTopGap,
  });

  final String title;
  final String? description;

  /// Space above the title; a pane that stacks many cards tightens it.
  final double topGap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.only(top: topGap, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: AppText.ui.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ),
          if (description != null) ...[
            const SizedBox(height: 2),
            Text(
              description!,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// A group of related settings: rows edge to edge on the raised surface, with
/// a full-width hairline between every child. Rows inside take the card's
/// metrics from [AppCardRowScope]; non-row content goes in a
/// [SettingsCardBlock].
class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({
    super.key,
    this.title,
    this.description,
    this.trailing,
    this.topGap = kSettingsSectionTopGap,
    required this.children,
  });

  /// See [SettingsSectionHeader.topGap].
  final double topGap;

  /// Null when the pane holds only this group and its heading already names it.
  final String? title;
  final String? description;

  /// Beside the title, for a section-level action (a refresh button).
  final Widget? trailing;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // A description with no title had nowhere to render and no test caught it; this catches it instead.
    assert(
      title != null || description == null,
      'SettingsSectionCard.description needs a title to render under',
    );
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final header = title == null
        ? SizedBox(height: topGap)
        : SettingsSectionHeader(
            title!,
            description: description,
            topGap: topGap,
          );
    final radius = BorderRadius.circular(AppRadii.card);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (trailing == null)
          header
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: header),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: trailing,
              ),
            ],
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: radius,
          ),
          child: DecoratedBox(
            // In front, so a child that fills its own background (a banner) cannot cover it.
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border.all(color: tokens.borderSubtle),
              borderRadius: radius,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.card - 1),
              // A ListTile or InkWell row paints its ink on the nearest Material.
              child: Material(
                type: MaterialType.transparency,
                child: AppStrongLabelScope(
                  child: AppCardRowScope(
                    child: SettingsRowGroup(children: children),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Non-row content inside a [SettingsSectionCard] (form fields, a preview),
/// inset by the card's own 16 on every side.
class SettingsCardBlock extends StatelessWidget {
  const SettingsCardBlock({
    super.key,
    required this.children,
    this.gap = AppSpacing.s16,
  });

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: children,
    ),
  );
}

/// A setting that belongs to the row above it (the key under push to talk,
/// the days under a schedule): indented, shorter, on a slightly deeper tint.
class SettingsSubRow extends StatelessWidget {
  const SettingsSubRow({
    super.key,
    required this.label,
    this.leading,
    this.trailing,
    this.onTap,
    this.semanticLabel,
  });

  final String label;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.fromLTRB(32, 6, AppSpacing.s16, 6),
      color: Color.lerp(tokens.surfaceBase, tokens.surfaceRaised, 0.5),
      child: Row(
        spacing: 10,
        children: [
          if (leading != null) leading!,
          Expanded(
            child: Text(
              label,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      child: InkWell(
        onTap: onTap,
        child: ExcludeSemantics(child: row),
      ),
    );
  }
}

/// The padding and least height a settings row takes: the card's metrics
/// inside a [SettingsSectionCard], the list metrics anywhere else.
class SettingsRowMetrics {
  const SettingsRowMetrics._(this.minHeight, this.inset, this.vertical);

  factory SettingsRowMetrics.of(BuildContext context) =>
      AppCardRowScope.of(context)
      ? const SettingsRowMetrics._(
          AppCardRowScope.minHeight,
          AppCardRowScope.inset,
          AppSpacing.s8,
        )
      : SettingsRowMetrics._(
          AppListRow.heightFor(context),
          AppSpacing.s8,
          AppSpacing.s4,
        );

  final double minHeight;
  final double inset;
  final double vertical;
}
