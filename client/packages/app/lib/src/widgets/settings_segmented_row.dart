// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A label (and optional description) with a segmented choice at its right
/// edge, the design's `.row` with a segmented control.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';

class SettingsSegmentedRow extends StatelessWidget {
  const SettingsSegmentedRow({
    super.key,
    required this.label,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.description,
    this.footnote,
  });

  final String label;
  final String? description;
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Extra caption under the description, for a state the choice cannot show.
  final String? footnote;

  /// Below this the control drops under the label instead of squeezing it.
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
      options: [for (final l in labels) AppSegmentedOption(label: l)],
      selectedIndex: selectedIndex,
      onSegmentSelected: onSelected,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical + 2,
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
              children: [
                Expanded(child: text),
                const SizedBox(width: AppSpacing.s12),
                control,
              ],
            );
          },
        ),
      ),
    );
  }
}
