// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas's one colour row: the named colours, the custom colours picked
/// most recently standing in for the trailing ones, and the picker at its end.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_pen_style.dart';
import '../providers/canvas_recent_colours.dart';

/// The six named pen colours, [selectedKey] marked, each handing its key to [onChoose].
List<ControlSwatch> canvasPenColourSwatches({
  required String selectedKey,
  required ValueChanged<String> onChoose,
}) => [
  for (final choice in canvasPenColors)
    ControlSwatch(
      label: choice.label,
      color: choice.color,
      selected: selectedKey == choice.key,
      onSelected: () => onChoose(choice.key),
    ),
];

/// [defaults] with the newest custom colours in place of its last entries,
/// then the picker, so the row keeps one length however many are remembered.
///
/// The first default always stays. A custom colour hands its `#rrggbb` key
/// to [onChoose], and [selectedKey] marks the one in use.
List<ControlSwatch> canvasColourRow({
  required BuildContext context,
  required WidgetRef ref,
  required List<ControlSwatch> defaults,
  required String selectedKey,
  required ValueChanged<String> onChoose,
  Color? plainColour,
}) {
  final recent = ref.watch(canvasRecentColoursProvider);
  final replaced = math.min(recent.length, defaults.length - 1);
  return [
    ...defaults.take(defaults.length - replaced),
    for (final hex in recent.take(replaced))
      ControlSwatch(
        label: 'Custom $hex',
        selected: selectedKey == hex,
        color: parseCanvasHexColor(hex),
        onSelected: () => onChoose(hex),
      ),
    _picker(context, ref, selectedKey, onChoose, plainColour),
  ];
}

ControlSwatch _picker(
  BuildContext context,
  WidgetRef ref,
  String selectedKey,
  ValueChanged<String> onChoose,
  Color? plainColour,
) => ControlSwatch(
  label: 'Custom colour',
  selected: false,
  mark: const Icon(AppIcons.appearance, size: AppSizes.icon20),
  onSelected: () async {
    final current = resolveCanvasInk(
      canvasPenInkByKey,
      selectedKey,
      plainColour ?? AppCanvasColors.annotation,
    );
    final picked = await showAppColourPicker(context, initial: current);
    if (picked == null) return;
    final hex = canvasHexOf(picked);
    await ref.read(canvasRecentColoursProvider.notifier).remember(hex);
    onChoose(hex);
  },
);
