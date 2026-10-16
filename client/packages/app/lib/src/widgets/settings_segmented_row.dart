// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A settings row whose value is a short segmented choice at the right.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';
import 'settings_select_row.dart';

class SettingsSegmentedRow<T> extends StatelessWidget {
  const SettingsSegmentedRow({
    super.key,
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.description,
  });

  final String label;
  final String? description;
  final T value;
  final List<SettingsChoice<T>> choices;
  final ValueChanged<T> onChanged;

  static const _stackBelow = 480.0;

  Widget get _control => AppSegmentedControl.inline(
    semanticLabel: label,
    options: [
      for (final choice in choices) AppSegmentedOption(label: choice.label),
    ],
    selectedIndex: choices.indexWhere((c) => c.value == value),
    onSegmentSelected: (i) => onChanged(choices[i].value),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final metrics = SettingsRowMetrics.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final labels = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
                if (description != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    description!,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ],
            );
            // Beside the label only when both fit; a phone stacks them.
            if (box.maxWidth < _stackBelow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.s8,
                children: [labels, _control],
              );
            }
            return Row(
              spacing: AppSpacing.s16,
              children: [
                Expanded(child: labels),
                _control,
              ],
            );
          },
        ),
      ),
    );
  }
}
