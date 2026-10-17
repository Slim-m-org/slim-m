// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A labelled slider for a settings card: the label with its value in mono at
/// the right, the track, and the range ends in mono underneath.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'settings_search.dart';

class SettingsSliderRow extends StatelessWidget {
  const SettingsSliderRow({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.minLabel,
    required this.maxLabel,
    required this.onChanged,
    this.divisions,
    this.sliderKey,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final String minLabel;
  final String maxLabel;
  final int? divisions;
  final Key? sliderKey;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) =>
      SettingsHighlightTarget(label: label, child: _content(context));

  Widget _content(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final mono = AppText.micro.copyWith(
      fontFamily: AppFonts.mono,
      color: tokens.textSecondary,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s12,
        AppSpacing.s16,
        14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
              Text(
                valueLabel,
                style: mono.copyWith(fontSize: AppText.caption.fontSize),
              ),
            ],
          ),
          AppSlider(
            key: sliderKey,
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            semanticLabel: label,
            onChanged: onChanged,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(minLabel, style: mono),
                Text(maxLabel, style: mono),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
