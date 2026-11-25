// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls that dress a note: fill, how much of it shows, text colour and text size.
///
/// One list of options, so the Note tool's options before placing and the bar over a placed note show the same controls.
/// The bar keeps the colours behind one button and the size beside it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_pen_style.dart';
import 'canvas_custom_colours.dart';

/// Solid, tinted (what every note looked like before) and clear; the order the opacity segments run in.
const List<double> canvasNoteOpacitySteps = [
  canvasNoteSolidOpacity,
  canvasNoteTintedOpacity,
  canvasNoteClearOpacity,
];

const List<String> _sizeKeys = ['small', 'medium', 'large'];

/// The step in [steps] closest to [value], so a note styled by a bot still marks a segment.
int nearestOpacityIndex(double? value) {
  final v = value ?? canvasNoteTintedOpacity;
  var best = 0;
  for (var i = 1; i < canvasNoteOpacitySteps.length; i++) {
    if ((canvasNoteOpacitySteps[i] - v).abs() <
        (canvasNoteOpacitySteps[best] - v).abs()) {
      best = i;
    }
  }
  return best;
}

/// The colour the bar's one colour button shows for [style]: the note's fill.
Color canvasNoteBarColour(CanvasNoteStyle style) {
  final fill = style.fill;
  return fill == null
      ? AppCanvasColors.note
      : resolveCanvasInk(canvasPenInkByKey, fill, AppCanvasColors.note);
}

/// Fill, how much of it shows and text colour: what the bar's colour popover holds.
List<ControlOptionEntry> canvasNoteColourEntries({
  required BuildContext context,
  required WidgetRef ref,
  required CanvasNoteStyle style,
  required ValueChanged<CanvasNoteStyle> onChanged,
}) => [
  ControlSwatchGroup(
    heading: 'Fill',
    swatches: canvasColourRow(
      context: context,
      ref: ref,
      defaults: [
        ControlSwatch(
          label: 'Default fill',
          color: AppCanvasColors.note,
          selected: style.fill == null,
          onSelected: () => onChanged(style.copyWith(fill: () => null)),
        ),
        ...canvasPenColourSwatches(
          selectedKey: style.fill ?? '',
          onChoose: (key) => onChanged(style.copyWith(fill: () => key)),
          // Default fill is already the amber.
          without: const {'amber'},
        ),
      ],
      selectedKey: style.fill ?? '',
      onChoose: (key) => onChanged(style.copyWith(fill: () => key)),
      plainColour: AppCanvasColors.note,
    ),
  ),
  ControlSegmented(
    label: 'Fill opacity',
    options: const [
      AppSegmentedOption(label: 'Solid'),
      AppSegmentedOption(label: 'Tint'),
      AppSegmentedOption(label: 'Clear'),
    ],
    selectedIndex: nearestOpacityIndex(style.fillOpacity),
    onSelected: (i) => onChanged(
      style.copyWith(
        fillOpacity: () => i == 1 ? null : canvasNoteOpacitySteps[i],
      ),
    ),
  ),
  ControlSwatchGroup(
    heading: 'Text',
    swatches: canvasColourRow(
      context: context,
      ref: ref,
      defaults: [
        ControlSwatch(
          label: 'Automatic text colour',
          mark: const Icon(AppIcons.textBox, size: AppSizes.icon20),
          selected: style.color == null || style.color == canvasNoteAutoColor,
          onSelected: () => onChanged(style.copyWith(color: () => null)),
        ),
        ...canvasPenColourSwatches(
          selectedKey: style.color ?? '',
          onChoose: (key) => onChanged(style.copyWith(color: () => key)),
        ),
      ],
      selectedKey: style.color ?? '',
      onChoose: (key) => onChanged(style.copyWith(color: () => key)),
    ),
  ),
];

/// The S, M, L steps of a note's text.
ControlSegmented canvasNoteSizeEntry(
  CanvasNoteStyle style,
  ValueChanged<CanvasNoteStyle> onChanged,
) {
  final sizeIndex = _sizeKeys.indexOf(style.size ?? canvasDefaultTextSize);
  return ControlSegmented(
    label: 'Text size',
    options: const [
      AppSegmentedOption(label: 'S'),
      AppSegmentedOption(label: 'M'),
      AppSegmentedOption(label: 'L'),
    ],
    selectedIndex: sizeIndex < 0 ? 1 : sizeIndex,
    onSelected: (i) =>
        onChanged(style.copyWith(size: () => i == 1 ? null : _sizeKeys[i])),
  );
}

/// Every group in one list, each handing back the whole next style through [onChanged].
List<ControlOptionEntry> canvasNoteStyleOptions({
  required BuildContext context,
  required WidgetRef ref,
  required CanvasNoteStyle style,
  required ValueChanged<CanvasNoteStyle> onChanged,
}) => [
  ...canvasNoteColourEntries(
    context: context,
    ref: ref,
    style: style,
    onChanged: onChanged,
  ),
  canvasNoteSizeEntry(style, onChanged),
];
