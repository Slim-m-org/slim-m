// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A label (and optional description) with a segmented choice at its right
/// edge, the design's `.row` with a segmented control.
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
    this.footnote,
  });

  final String label;
  final String? description;
  final T value;
  final List<SettingsChoice<T>> choices;
  final ValueChanged<T> onChanged;

  /// Extra caption under the description, for a state the choice cannot show.
  final String? footnote;

  /// Below this row width the control drops under the label instead of
  /// squeezing it.
  static const stackBelowWidth = 480.0;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final metrics = SettingsRowMetrics.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppText.ui.copyWith(color: tokens.textPrimary)),
        for (final line in [description, footnote].nonNulls) ...[
          const SizedBox(height: 2),
          Text(
            line,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ],
    );
    final control = AppSegmentedControl.inline(
      semanticLabel: label,
      options: [for (final c in choices) AppSegmentedOption(label: c.label)],
      selectedIndex: choices.indexWhere((c) => c.value == value),
      onSegmentSelected: (i) => onChanged(choices[i].value),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth + 2 * metrics.inset < stackBelowWidth) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.s8,
                children: [text, control],
              );
            }
            return Row(
              spacing: AppSpacing.s16,
              children: [
                Expanded(child: text),
                control,
              ],
            );
          },
        ),
      ),
    );
  }
}
