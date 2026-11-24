// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls a connection has, as the same option entries the Connect tool's menu and the selection bar both draw.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart';
import 'canvas_custom_colours.dart';

/// The arrow choices, in the order the segmented row shows them.
const canvasEdgeArrows = [EdgeArrow.none, EdgeArrow.end, EdgeArrow.both];

const _arrowLabels = {
  EdgeArrow.none: 'None',
  EdgeArrow.end: 'End',
  EdgeArrow.both: 'Both',
};

/// The colour row, neutral first because an absent colour means the board's neutral ink.
List<ControlSwatch> canvasEdgeColourSwatches({
  required BuildContext context,
  required WidgetRef ref,
  required AppTokens tokens,
  required String? colorKey,
  required ValueChanged<String?> onColour,
}) => canvasColourRow(
  context: context,
  ref: ref,
  defaults: [
    ControlSwatch(
      label: 'Neutral',
      selected: colorKey == null,
      onSelected: () => onColour(null),
      color: tokens.textSecondary,
    ),
    ...canvasPenColourSwatches(
      selectedKey: colorKey ?? '',
      onChoose: onColour.call,
    ),
  ],
  selectedKey: colorKey ?? '',
  plainColour: tokens.textSecondary,
  onChoose: onColour.call,
);

/// Colour, then the arrow as a segmented row: arrow, opacity and size are never dropdowns.
List<ControlOptionEntry> canvasEdgeControls({
  required BuildContext context,
  required WidgetRef ref,
  required AppTokens tokens,
  required String? colorKey,
  required EdgeArrow arrow,
  required ValueChanged<String?> onColour,
  required ValueChanged<EdgeArrow> onArrow,
}) => [
  ControlSwatchGroup(
    heading: 'Colour',
    swatches: canvasEdgeColourSwatches(
      context: context,
      ref: ref,
      tokens: tokens,
      colorKey: colorKey,
      onColour: onColour,
    ),
  ),
  ControlSegmented(
    label: 'Arrow',
    options: [
      for (final choice in canvasEdgeArrows)
        AppSegmentedOption(label: _arrowLabels[choice]!),
    ],
    selectedIndex: canvasEdgeArrows.indexOf(arrow),
    onSelected: (index) => onArrow(canvasEdgeArrows[index]),
  ),
];
