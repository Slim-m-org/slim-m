// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas dock at phone width: two small floating cards instead of one
/// tall panel stacking three toolbars.
///
/// The tools get a card of their own, the call controls another, each one row
/// that hugs its content. Undo, the overflow and close are not here: they sit
/// in the canvas header (`CanvasCompactEditGroup`), where a phone has the
/// room that the bottom edge lacks - five tools with the pen's caret already
/// fill a 360dp row, so there was never space for them beside the tools.
/// Layout follows width, never platform (docs/design/desktop-vs-mobile.md,
/// the one rule): this is the compact branch of the same dock, not a mobile
/// copy of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/floating_dock_card.dart';
import '../../voice/widgets/bot_call_chips.dart';
import '../../voice/widgets/call_leave_button.dart';
import '../../modules/screens/dock_solo_controls.dart';
import 'canvas_call_dock.dart';
import 'canvas_dock_toggle.dart';
import 'canvas_dock_tools.dart';
import 'canvas_tools_row.dart';

class CanvasCompactDock extends StatelessWidget {
  const CanvasCompactDock({super.key, required this.canvas, this.call});

  final CallDockData? call;
  final CanvasDockData canvas;

  @override
  Widget build(BuildContext context) {
    final call = this.call;
    final showTools = canvas.fullscreen || !canvas.activityLogOpen;
    // Stretched to the wider card, so the two read as one stack and not two offset pills.
    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTools)
            FloatingDockCard(
              rows: [
                CanvasDockToolsRow(
                  canvas: canvas,
                  part: CanvasToolsRowPart.toolsOnly,
                ),
                // The header that holds undo, the overflow and the way out is gone in fullscreen, so they move here.
                if (canvas.fullscreen)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CanvasDockToolsRow(
                        canvas: canvas,
                        part: CanvasToolsRowPart.editOnly,
                      ),
                      const SizedBox(width: AppSpacing.s8),
                      CanvasDockExitFullscreen(
                        onPressed: canvas.onToggleFullscreen,
                      ),
                    ],
                  ),
              ],
            ),
          if (showTools && call != null) const SizedBox(height: AppSpacing.s8),
          if (call != null)
            Consumer(
              builder: (context, ref, _) => FloatingDockCard(
                trailing: CallLeaveButton(controller: call.controller),
                rows: [
                  ...callRowsWithExtras(
                    context,
                    ref,
                    // IntrinsicWidth above rules out a LayoutBuilder; the dock sits inside the pane's s12 margin.
                    width:
                        MediaQuery.sizeOf(context).width - 2 * AppSpacing.s12,
                    controller: call.controller,
                    voice: call.voice,
                    toggle: botCallChipsFor(ref, call.channelId),
                    toggleSlots: botCallChipCount(ref, call.channelId),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Undo, the overflow menu and close, drawn in the header at phone width.
class CanvasCompactEditGroup extends StatelessWidget {
  const CanvasCompactEditGroup({super.key, required this.canvas});

  final CanvasDockData canvas;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CanvasDockToolsRow(
        canvas: canvas,
        part: CanvasToolsRowPart.editOnly,
        overflowOpensBelow: true,
      ),
      const SizedBox(width: AppSpacing.s4),
      CanvasDockToggle(open: true, onPressed: canvas.onClose),
    ],
  );
}
