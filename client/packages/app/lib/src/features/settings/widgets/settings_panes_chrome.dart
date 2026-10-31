// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../../routing/close_screen.dart';

/// A pane's heading row beside the nav: its name, any pane actions, and the
/// close that the app bar used to carry (personal settings redesign,
/// 2026-10-16).
class SettingsPaneHeading extends StatelessWidget {
  const SettingsPaneHeading(
    this.label, {
    super.key,
    this.actions,
    this.onClose,
  });

  final String label;
  final List<Widget>? actions;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: AppText.heading.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
          ),
          ...?actions,
          if (onClose != null)
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Close settings',
              tooltip: 'Close settings',
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}

/// The nav's own top: the way back and the title, where the app bar used to
/// sit across both columns.
class NavHeader extends StatelessWidget {
  const NavHeader({
    super.key,
    required this.title,
    required this.backTooltip,
    required this.backFallback,
  });

  final String title;
  final String backTooltip;
  final String backFallback;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      height: 40,
      margin: const EdgeInsets.only(bottom: AppSpacing.s12),
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          AppIconButton(
            icon: AppIcons.back,
            semanticLabel: backTooltip,
            tooltip: backTooltip,
            onPressed: () => closeScreen(context, backFallback),
          ),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A nav group's name: mono, uppercase and faint, with a hairline above
/// every group but the first.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.label, {required this.first, super.key});

  final String label;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      margin: EdgeInsets.only(top: first ? 0 : 10),
      padding: EdgeInsets.fromLTRB(10, first ? 4 : AppSpacing.s16, 10, 6),
      decoration: BoxDecoration(
        border: first
            ? null
            : Border(top: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Semantics(
        header: true,
        child: Text(
          label.toUpperCase(),
          // Spoken as written: a reader spells some all-caps words out letter by letter.
          semanticsLabel: label,
          style: AppText.code.copyWith(
            fontSize: AppText.micro.fontSize,
            letterSpacing: AppText.micro.fontSize! * 0.06,
            color: tokens.textSecondary,
          ),
        ),
      ),
    );
  }
}
