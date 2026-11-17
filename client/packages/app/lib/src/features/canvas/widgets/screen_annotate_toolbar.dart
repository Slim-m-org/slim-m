// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks a viewer can leave on a shared screen, as a small pill on its tile.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'stamp_tool_button.dart';

enum ScreenAnnotateTool { pen, ellipse, note, stamp }

/// Picking the tool in use again puts the pen down, so the tile's own controls come back.
class ScreenAnnotateToolbar extends StatelessWidget {
  const ScreenAnnotateToolbar({
    super.key,
    required this.sharerName,
    required this.tool,
    required this.onChanged,
    this.onStamp,
    this.onChooseStamp,
  });

  final String sharerName;
  final ScreenAnnotateTool? tool;
  final ValueChanged<ScreenAnnotateTool?> onChanged;

  /// The Stamp button, offered only while the sharer's screen takes stamps (decision 0121).
  final void Function(BuildContext anchor)? onStamp;

  /// Opens the picker again while stamping, to change what a tap places.
  final void Function(BuildContext anchor)? onChooseStamp;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final stamping = tool == ScreenAnnotateTool.stamp;
    final choose = onChooseStamp;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _button(
              ScreenAnnotateTool.pen,
              AppIcons.pen,
              "Draw on $sharerName's screen",
            ),
            _button(
              ScreenAnnotateTool.ellipse,
              AppIcons.shapeEllipse,
              "Circle something on $sharerName's screen",
            ),
            _button(
              ScreenAnnotateTool.note,
              AppIcons.note,
              "Put a note on $sharerName's screen",
            ),
            if (onStamp case final stamp?)
              StampToolButton(
                active: stamping,
                size: AppIconButtonSize.sm,
                semanticLabel: stamping
                    ? 'Stop stamping on the screen'
                    : "Stamp on $sharerName's screen",
                tooltip: stamping ? 'Done' : "Stamp on $sharerName's screen",
                onPressed: stamp,
              ),
            if (stamping && choose != null)
              Builder(
                builder: (anchor) => AppIconButton(
                  icon: AppIcons.chevronUp,
                  semanticLabel: 'Choose a stamp',
                  tooltip: 'Choose a stamp',
                  size: AppIconButtonSize.sm,
                  onPressed: () => choose(anchor),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _button(ScreenAnnotateTool value, IconData icon, String label) {
    final active = tool == value;
    return AppIconButton(
      icon: icon,
      semanticLabel: active ? 'Stop drawing on the screen' : label,
      tooltip: active ? 'Done' : label,
      size: AppIconButtonSize.sm,
      active: active,
      onPressed: () => onChanged(active ? null : value),
    );
  }
}
