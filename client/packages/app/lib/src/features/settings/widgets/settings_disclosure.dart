// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A folded run of rarely changed rows, so a form shows its one primary
/// action first and the long option list only when asked.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_hairline.dart';

class SettingsDisclosure extends StatefulWidget {
  const SettingsDisclosure({
    super.key,
    required this.title,
    required this.summary,
    required this.children,
    this.initiallyExpanded = false,
    this.toggleKey,
  });

  final String title;

  /// Open on first build, for a step the admin should answer now.
  final bool initiallyExpanded;

  /// On the folded row, for tests and snapshots to open it by.
  final Key? toggleKey;

  /// What is currently chosen inside, so the folded row still answers.
  final String summary;
  final List<Widget> children;

  @override
  State<SettingsDisclosure> createState() => _SettingsDisclosureState();
}

class _SettingsDisclosureState extends State<SettingsDisclosure> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return LayoutBuilder(
      builder: (context, box) =>
          _group(context, tokens, _summaryRoom(context, box.maxWidth)),
    );
  }

  /// What is left of the row once the title, chevron, gaps and insets have
  /// their natural width, so the summary gives way before the title does.
  double _summaryRoom(BuildContext context, double width) {
    final title = TextPainter(
      text: TextSpan(
        text: widget.title,
        style: AppText.ui.copyWith(fontWeight: AppWeights.medium),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    const chrome =
        2 * AppCardRowScope.inset + AppSizes.icon16 + 2 * AppSpacing.s8;
    return math.max(0, width - title.width - chrome);
  }

  Widget _group(BuildContext context, AppTokens tokens, double summaryRoom) {
    return SettingsRowGroup(
      children: [
        AppListRow(
          key: widget.toggleKey,
          label: widget.title,
          semanticLabel:
              '${widget.title}, ${widget.summary}, '
              '${_expanded ? 'expanded' : 'collapsed'}',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: AppSpacing.s8,
            children: [
              // The row's trailing slot is unbounded, so the cap lives here.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: summaryRoom),
                child: Text(
                  widget.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.ui.copyWith(color: tokens.textSecondary),
                ),
              ),
              Icon(
                _expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
            ],
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}
