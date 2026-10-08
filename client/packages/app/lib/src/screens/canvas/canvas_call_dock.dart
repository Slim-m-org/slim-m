// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one floating dock a voice call and the canvas share, so opening the
/// canvas during a call no longer costs the call its own controls.
///
/// Before this, a call's controls (`CallControls`) lived in a full-width bar
/// at the bottom of `VoiceScreen`, and the canvas's own controls
/// (`CanvasBar`, now `CanvasToolsRow`) lived in a full-width bar at the top
/// of `CanvasPane` - and opening the canvas swapped `VoiceScreen` out
/// entirely (`ConversationPane`'s stage ternary), taking the call's controls
/// with it. The owner reported this directly: "we should still have call
/// controls while in the canvas."
///
/// [CanvasCallDock] is the fix: one [FloatingDockCard], built with whichever
/// of [call] and [canvas] apply right now, so the exact same card renders a
/// call alone, a canvas alone, or both together. Nothing here decides
/// *whether* a call is active in this channel - `canvas_pane.dart` already
/// reads that off `voiceControllerProvider` for the presence layer, and
/// passes the same answer here.
///
/// **One order, always (decision 0047): tools, edit, call, leave.** The call
/// controls never scroll - a call nobody can mute or leave is the one failure
/// this dock must never produce - and leave sits alone after a divider at the
/// far edge. The canvas toggle sits after share in the call group, so it is in
/// the same slot whether the canvas is open or not. The canvas's five tools
/// keep their own scroll-and-fade strip (decision 0004), which only scrolls
/// when even the hugged width does not fit.
///
/// **A narrow pane stacks rows in one card; a wide one draws one.** The five
/// tools get a row of their own so the eraser is on screen at 360, 390 and
/// 430; undo, the overflow and the canvas toggle share the next row, and the
/// call controls the last. One row needs [_oneRowMinWidth], measured, not
/// [kCompactWidth]: between the two the combined row overflows and scrolls.
///
/// **The gaps either side of the divider shrank from [AppSpacing.s12] to
/// [AppSpacing.s8], the same compaction pass as `FloatingDockCard`'s own
/// inset and `voice_call_controls.dart`'s control size.** Nothing here
/// bounds a touch target - the row stays two rows below [kCompactWidth]
/// regardless, so a phone never sees this branch at all - so there was
/// nothing stopping the gap from tightening alongside everything else.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../call_leave_button.dart';
import '../voice_call_controls.dart';
import '../../providers/voice_controller.dart';
import '../../providers/voice_flags.dart';
import '../../widgets/floating_dock_card.dart';
import 'canvas_compact_dock.dart';
import 'canvas_dock_toggle.dart';
import 'canvas_dock_tools.dart';
import 'canvas_pen_style.dart';
import 'canvas_tools_row.dart';

/// The call half of the dock: exactly what `CallControls` already needs.
class CallDockData {
  const CallDockData({required this.voice, required this.controller});

  final VoiceFlags voice;
  final VoiceController controller;
}

// CanvasHiddenTile lives in canvas_tools_row.dart, imported below - defining it there rather than here avoids a two-way import with CanvasOverflowMenu, its only other user.

/// The canvas half of the dock: exactly what [CanvasToolsRow] already needs.
class CanvasDockData {
  const CanvasDockData({
    required this.tool,
    required this.onToolChanged,
    required this.canDraw,
    required this.canUndo,
    required this.onUndo,
    required this.canRedo,
    required this.onRedo,
    required this.canManage,
    required this.onClear,
    required this.onPasteImage,
    required this.selection,
    required this.onBringToFront,
    required this.onSendToBack,
    required this.onDeleteSelected,
    required this.activityLogOpen,
    required this.onToggleActivityLog,
    required this.shapeKind,
    required this.onShapeKindChanged,
    required this.pen,
    required this.onPenChanged,
    required this.onClose,
    required this.hasSelfBubble,
    required this.selfBubbleHidden,
    required this.onToggleSelfBubbleHidden,
    required this.hiddenTiles,
    required this.onShowTile,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  final CanvasTool tool;
  final ValueChanged<CanvasTool> onToolChanged;

  /// False while the pane's error is one a place would fail the same way as
  /// (`canvasErrorBlocksDrawing`) - see `canvas_tools_row.dart`'s own doc for
  /// which tools this disarms and why.
  final bool canDraw;
  final bool canUndo;
  final VoidCallback onUndo;
  final bool canRedo;
  final VoidCallback onRedo;
  final bool canManage;
  final Future<void> Function() onClear;
  final VoidCallback onPasteImage;
  final ValueListenable<String?> selection;
  final ValueChanged<String> onBringToFront;
  final ValueChanged<String> onSendToBack;
  final ValueChanged<String> onDeleteSelected;
  final bool activityLogOpen;
  final VoidCallback onToggleActivityLog;
  final CanvasShapeKind shapeKind;
  final ValueChanged<CanvasShapeKind> onShapeKindChanged;
  final CanvasPenStyle pen;
  final ValueChanged<CanvasPenStyle> onPenChanged;
  final VoidCallback onClose;

  /// Whether the caller is on this channel's call at all, and the overflow
  /// menu's own hide toggle for it - see `canvas_tools_row.dart`'s own doc
  /// on why the menu item is absent rather than merely disabled when this
  /// is false.
  final bool hasSelfBubble;
  final bool selfBubbleHidden;
  final VoidCallback onToggleSelfBubbleHidden;

  /// Every remote camera or screen-share tile hidden on this viewer's own
  /// canvas right now, and the recovery action for each - a hide must stay
  /// reversible without leaving the call.
  final List<CanvasHiddenTile> hiddenTiles;
  final ValueChanged<String> onShowTile;

  /// Whether the pane has dropped its chrome, and the control that flips it.
  /// While true this dock draws its canvas half as one button - the way back
  /// - instead of the tool strip; the call half is untouched, for the reason
  /// this file's own doc gives about a call nobody can leave.
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;
}

/// [call] whenever this device is connected to a call in [channelId], or is
/// auto-rejoining one there, null otherwise - the one question
/// `canvas_pane.dart` has to ask before it can hand this dock a call section at all. Read fresh on
/// every build rather than cached, since a call joined or left while the
/// canvas stays open must show up here on the very next frame.
CallDockData? callDockDataFor(
  VoiceFlags voice,
  VoiceController controller,
  String channelId,
) {
  if (!voice.inCallStageFor(channelId)) return null;
  return CallDockData(voice: voice, controller: controller);
}

/// Measured: the one-row dock with the pen caret out is 776dp wide at touch
/// density, so narrower panes stack instead of scrolling a tool off the edge.
const _oneRowMinWidth = 800.0;

class CanvasCallDock extends StatelessWidget {
  const CanvasCallDock({
    super.key,
    this.call,
    this.canvas,
    this.compact = false,
  }) : assert(
         call != null || canvas != null,
         'a dock with neither a call nor a canvas has nothing to show',
       );

  final CallDockData? call;
  final CanvasDockData? canvas;

  /// A phone-width pane: the tools and the call get a card each, and undo,
  /// the overflow and close move to the header (`CanvasCompactEditGroup`).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final call = this.call;
    final canvas = this.canvas;
    if (compact && canvas != null) {
      return CanvasCompactDock(call: call, canvas: canvas);
    }
    if (call == null) {
      return LayoutBuilder(
        builder: (context, constraints) => FloatingDockCard(
          rows: constraints.maxWidth >= kCompactWidth
              ? [_inlineCanvasRow(canvas!)]
              : _stackedCanvasRows(canvas!),
        ),
      );
    }
    final leave = CallLeaveButton(controller: call.controller);
    if (canvas == null) {
      return FloatingDockCard(rows: [_callRow(call)], trailing: leave);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final oneRow = constraints.maxWidth >= _oneRowMinWidth;
        return FloatingDockCard(
          trailing: leave,
          rows: oneRow
              ? [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: CanvasDockToolsRow(canvas: canvas)),
                      const SizedBox(width: AppSpacing.s8),
                      const DockVerticalDivider(),
                      const SizedBox(width: AppSpacing.s8),
                      _callRow(call, toggle: _toggle(canvas)),
                    ],
                  ),
                ]
              : [..._stackedCanvasRows(canvas), _callRow(call)],
        );
      },
    );
  }

  static Widget _inlineCanvasRow(CanvasDockData canvas) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: CanvasDockToolsRow(canvas: canvas)),
      ..._toggleAfterGap(canvas),
    ],
  );

  /// Tools on their own row so the eraser never scrolls out of reach; undo,
  /// the overflow and the canvas toggle share the row beneath.
  static List<Widget> _stackedCanvasRows(CanvasDockData canvas) {
    if (canvas.fullscreen) return [CanvasDockToolsRow(canvas: canvas)];
    return [
      if (!canvas.activityLogOpen)
        CanvasDockToolsRow(canvas: canvas, part: CanvasToolsRowPart.toolsOnly),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CanvasDockToolsRow(canvas: canvas, part: CanvasToolsRowPart.editOnly),
          ..._toggleAfterGap(canvas),
        ],
      ),
    ];
  }

  static Widget _callRow(CallDockData call, {Widget? toggle}) => CallControls(
    controller: call.controller,
    voice: call.voice,
    extraControl: toggle,
  );

  static Widget? _toggle(CanvasDockData canvas) => canvas.fullscreen
      ? null
      : CanvasDockToggle(open: true, onPressed: canvas.onClose);

  static List<Widget> _toggleAfterGap(CanvasDockData canvas) {
    final toggle = _toggle(canvas);
    return [
      if (toggle != null) ...[const SizedBox(width: AppSpacing.s8), toggle],
    ];
  }
}
