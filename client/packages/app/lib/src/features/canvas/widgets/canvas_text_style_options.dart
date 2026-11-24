// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls that dress a text box: its colour and its size.
///
/// One list, so the bar over a selected box and the bar over one being typed in show the same controls.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart'
    show canvasDefaultTextColor;

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_text_props.dart';
import 'canvas_custom_colours.dart';

const List<String> _sizeLabels = ['S', 'M', 'L'];

/// The two groups, size first so it stays in view when a narrow bar scrolls; each hands back only what it changed, so a quick second tap never undoes the first.
List<ControlOptionEntry> canvasTextStyleOptions({
  required BuildContext context,
  required WidgetRef ref,
  required String size,
  required String colorKey,
  required ValueChanged<String> onSize,
  required ValueChanged<String> onColour,
}) {
  final tokens = Theme.of(context).extension<AppTokens>()!;
  void chooseColour(String key) => onColour(key);
  final sizeIndex = canvasTextSizeKeys.indexOf(size);
  return [
    ControlSegmented(
      label: 'Text size',
      options: [
        for (final label in _sizeLabels) AppSegmentedOption(label: label),
      ],
      selectedIndex: sizeIndex < 0 ? 1 : sizeIndex,
      onSelected: (i) => onSize(canvasTextSizeKeys[i]),
    ),
    ControlSwatchGroup(
      heading: 'Text colour',
      swatches: canvasColourRow(
        context: context,
        ref: ref,
        defaults: [
          ControlSwatch(
            label: 'Default colour',
            selected: colorKey == canvasDefaultTextColor,
            onSelected: () => chooseColour(canvasDefaultTextColor),
            color: tokens.textPrimary,
          ),
          ...canvasPenColourSwatches(
            selectedKey: colorKey,
            onChoose: chooseColour,
          ),
        ],
        selectedKey: colorKey,
        plainColour: tokens.textPrimary,
        onChoose: chooseColour,
      ),
    ),
  ];
}
