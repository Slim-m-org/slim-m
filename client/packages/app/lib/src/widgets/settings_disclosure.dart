// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A folded run of rarely changed rows, so a form shows its one primary
/// action first and the long option list only when asked.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsDisclosure extends StatefulWidget {
  const SettingsDisclosure({
    super.key,
    required this.title,
    required this.summary,
    required this.children,
  });

  final String title;

  /// What is currently chosen inside, so the folded row still answers.
  final String summary;
  final List<Widget> children;

  @override
  State<SettingsDisclosure> createState() => _SettingsDisclosureState();
}

class _SettingsDisclosureState extends State<SettingsDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusableTapTarget(
          semanticLabel:
              '${widget.title}, ${widget.summary}, '
              '${_expanded ? 'expanded' : 'collapsed'}',
          onTap: () => setState(() => _expanded = !_expanded),
          builder: (context, focused, hovered) => Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
            child: Row(
              children: [
                Icon(
                  _expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
                const SizedBox(width: AppSpacing.s8),
                Text(
                  widget.title,
                  style: AppText.ui.copyWith(
                    color: hovered ? tokens.textPrimary : tokens.textSecondary,
                    fontWeight: AppWeights.medium,
                  ),
                ),
                const Spacer(),
                Text(
                  widget.summary,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}
