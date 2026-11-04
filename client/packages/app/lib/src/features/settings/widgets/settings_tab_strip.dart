// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The underlined tab labels of a settings detail page (a role, a module).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsTabStrip<T> extends StatelessWidget {
  const SettingsTabStrip({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  /// Label per tab, in display order.
  final List<(T, String)> tabs;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Padding(
        // The pane inset less the focus ring's 4 per side, so the labels line up with the cards below.
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s20),
        // Scrolls rather than wraps: several labels plus a live count may not fit a phone's width.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: AppSpacing.s12,
            children: [
              for (final (tab, label) in tabs) _label(context, tab, label),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(BuildContext context, T tab, String label) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final isSelected = selected == tab;
    return FocusableTapTarget(
      onTap: () => onSelected(tab),
      semanticLabel: label,
      selected: isSelected,
      builder: (context, focused, hovered) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? tokens.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Padding(
          // The focus ring's own gap and stroke take the other four.
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
          child: Text(
            label,
            style: AppText.ui.copyWith(
              color: isSelected ? tokens.textPrimary : tokens.textSecondary,
              fontWeight: isSelected ? AppWeights.medium : AppWeights.regular,
            ),
          ),
        ),
      ),
    );
  }
}
