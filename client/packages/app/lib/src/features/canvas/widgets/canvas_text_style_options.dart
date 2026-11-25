// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls that dress a text box: its colour and its size.
///
/// The bar over a selected box and the bar over one being typed in both build from these.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart'
    show canvasDefaultTextColor, resolveCanvasInk;

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_pen_style.dart';
import '../providers/canvas_text_props.dart';
import 'canvas_custom_colours.dart';

const List<String> _sizeLabels = ['S', 'M', 'L'];

/// The colour the bar's one colour button shows for a text box in [colorKey].
Color canvasTextBarColour(BuildContext context, String colorKey) {
  final ink = Theme.of(context).extension<AppTokens>()!.textPrimary;
  return colorKey == canvasDefaultTextColor
      ? ink
      : resolveCanvasInk(canvasPenInkByKey, colorKey, ink);
}

/// The one colour group: what the bar's colour popover holds for a text box.
List<ControlOptionEntry> canvasTextColourEntries({
  required BuildContext context,
  required WidgetRef ref,
  required String colorKey,
  required ValueChanged<String> onColour,
}) {
  final tokens = Theme.of(context).extension<AppTokens>()!;
  return [
    ControlSwatchGroup(
      heading: 'Text colour',
      swatches: canvasColourRow(
        context: context,
        ref: ref,
        defaults: [
          ControlSwatch(
            label: 'Default colour',
            selected: colorKey == canvasDefaultTextColor,
            onSelected: () => onColour(canvasDefaultTextColor),
            color: tokens.textPrimary,
          ),
          ...canvasPenColourSwatches(selectedKey: colorKey, onChoose: onColour),
        ],
        selectedKey: colorKey,
        plainColour: tokens.textPrimary,
        onChoose: onColour,
      ),
    ),
  ];
}

/// The S, M, L steps of a text box's size, handing back the key of the one chosen.
ControlSegmented canvasTextSizeEntry(String size, ValueChanged<String> onSize) {
  final sizeIndex = canvasTextSizeKeys.indexOf(size);
  return ControlSegmented(
    label: 'Text size',
    options: [
      for (final label in _sizeLabels) AppSegmentedOption(label: label),
    ],
    selectedIndex: sizeIndex < 0 ? 1 : sizeIndex,
    onSelected: (i) => onSize(canvasTextSizeKeys[i]),
  );
}
