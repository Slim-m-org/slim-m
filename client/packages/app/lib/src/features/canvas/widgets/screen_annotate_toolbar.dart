// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three marks a viewer can leave on a shared screen, as a small pill on its tile.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

enum ScreenAnnotateTool { pen, ellipse, note }

/// Picking the tool in use again puts the pen down, so the tile's own controls come back.
class ScreenAnnotateToolbar extends StatelessWidget {
  const ScreenAnnotateToolbar({
    super.key,
    required this.sharerName,
    required this.tool,
    required this.onChanged,
  });

  final String sharerName;
  final ScreenAnnotateTool? tool;
  final ValueChanged<ScreenAnnotateTool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
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
