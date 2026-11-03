// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The custom-colour tiles beside the six named ones: a picker and the last
/// few colours chosen with it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/control_swatch_row.dart';
import '../providers/canvas_pen_style.dart';
import '../providers/canvas_recent_colours.dart';

/// A tile that opens the colour picker, then the recent colours, each handing
/// a `#rrggbb` key to [onChoose]. [selectedKey] marks the one in use.
List<ControlSwatch> canvasCustomColourSwatches({
  required BuildContext context,
  required WidgetRef ref,
  required String selectedKey,
  required ValueChanged<String> onChoose,
  Color? plainColour,
  int recentLimit = canvasRecentColoursMax,
}) {
  final current = resolveCanvasInk(
    canvasPenInkByKey,
    selectedKey,
    plainColour ?? AppCanvasColors.annotation,
  );
  return [
    ControlSwatch(
      label: 'Custom colour',
      selected: false,
      mark: const Icon(AppIcons.appearance, size: AppSizes.icon20),
      onSelected: () async {
        final picked = await showAppColourPicker(context, initial: current);
        if (picked == null) return;
        final hex = canvasHexOf(picked);
        await ref.read(canvasRecentColoursProvider.notifier).remember(hex);
        onChoose(hex);
      },
    ),
    for (final hex in ref.watch(canvasRecentColoursProvider).take(recentLimit))
      ControlSwatch(
        label: 'Custom $hex',
        selected: selectedKey == hex,
        color: parseCanvasHexColor(hex),
        onSelected: () => onChoose(hex),
      ),
  ];
}
