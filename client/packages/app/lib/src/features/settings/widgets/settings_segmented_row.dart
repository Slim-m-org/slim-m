// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A label (and optional description) with a segmented choice at its right
/// edge, the design's `.row` with a segmented control.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_control_column.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_search.dart';

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

  /// The least room the label keeps beside the control; with less, the
  /// control drops under it instead of squeezing it.
  static const minLabelWidth = 220.0;

  @override
  Widget build(BuildContext context) =>
      SettingsHighlightTarget(label: label, child: _content(context));

  Widget _content(BuildContext context) {
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
    final column = SettingsControlColumn.widthOf(context);
    if (column != null) return _inColumn(text, column, metrics);
    return LayoutBuilder(
      builder: (context, box) {
        final room = box.maxWidth - 2 * metrics.inset;
        final inline = AppSegmentedControl.inlineWidth(context, _options);
        final beside = room - inline - AppSpacing.s16 >= minLabelWidth;
        return _padded(
          metrics,
          beside
              ? Row(
                  children: [
                    Expanded(child: text),
                    const SizedBox(width: AppSpacing.s16),
                    AppSegmentedControl.inline(
                      semanticLabel: label,
                      options: _options,
                      selectedIndex: _selected,
                      onSegmentSelected: _select,
                    ),
                  ],
                )
              : _stacked(text),
        );
      },
    );
  }

  Widget _padded(SettingsRowMetrics metrics, Widget child) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: metrics.minHeight),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.inset,
        vertical: metrics.vertical,
      ),
      child: child,
    ),
  );

  /// The label over a control spanning the row, so rows stack to one width.
  Widget _stacked(Widget text) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    spacing: AppSpacing.s8,
    children: [
      text,
      AppSegmentedControl.fill(
        semanticLabel: label,
        options: _options,
        selectedIndex: _selected,
        onSegmentSelected: _select,
      ),
    ],
  );

  List<AppSegmentedOption> get _options => [
    for (final c in choices)
      AppSegmentedOption(
        label: c.label,
        disabled: c.disabledReason != null,
        disabledReason: c.disabledReason,
      ),
  ];

  int get _selected => choices.indexWhere((c) => c.value == value);

  void _select(int index) => onChanged(choices[index].value);

  /// In a [SettingsControlColumn]: the control fills the column at the
  /// right inset, or spans the row under its label below the column's width.
  Widget _inColumn(Widget text, double column, SettingsRowMetrics metrics) {
    final control = AppSegmentedControl.fill(
      semanticLabel: label,
      options: _options,
      selectedIndex: _selected,
      onSegmentSelected: _select,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final beside = SettingsControlColumn.besideAt(box.maxWidth);
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: metrics.minHeight),
          child: Padding(
            padding: beside
                ? EdgeInsets.symmetric(
                    horizontal: metrics.inset,
                    vertical: metrics.vertical,
                  )
                : EdgeInsets.fromLTRB(
                    metrics.inset,
                    AppSpacing.s12,
                    metrics.inset,
                    AppSpacing.s16,
                  ),
            child: beside
                ? Row(
                    children: [
                      Expanded(child: text),
                      const SizedBox(width: AppSpacing.s16),
                      SizedBox(width: column, child: control),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    spacing: AppSpacing.s8,
                    children: [text, control],
                  ),
          ),
        );
      },
    );
  }
}
