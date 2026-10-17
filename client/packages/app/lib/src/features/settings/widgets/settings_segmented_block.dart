// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A short list of exclusive choices as a segmented control at the card's inset.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';

class SettingsSegmentedBlock extends StatelessWidget {
  const SettingsSegmentedBlock({
    super.key,
    required this.semanticLabel,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.disabled = false,
  });

  final String semanticLabel;
  final List<String> labels;

  /// -1 selects nothing, for a value that has not loaded or fits no choice.
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool disabled;

  @override
  Widget build(BuildContext context) => SettingsCardBlock(
    children: [
      AppSegmentedControl.inline(
        semanticLabel: semanticLabel,
        options: [
          for (final label in labels)
            AppSegmentedOption(label: label, disabled: disabled),
        ],
        selectedIndex: selectedIndex,
        onSegmentSelected: onSelected,
      ),
    ],
  );
}
