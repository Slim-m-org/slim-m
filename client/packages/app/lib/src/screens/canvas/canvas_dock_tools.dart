// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas half of the dock, split out of `canvas_call_dock.dart` so the
/// phone layout (`canvas_compact_dock.dart`) can draw the same row.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_call_dock.dart';
import 'canvas_tools_row.dart';

/// The canvas half of the dock: the full tool strip normally, or the single
/// way back out of fullscreen while the chrome is dropped.
class CanvasDockToolsRow extends StatelessWidget {
  const CanvasDockToolsRow({
    super.key,
    required this.canvas,
    this.part = CanvasToolsRowPart.all,
    this.overflowOpensBelow = false,
  });

  final CanvasDockData canvas;
  final CanvasToolsRowPart part;
  final bool overflowOpensBelow;

  @override
  Widget build(BuildContext context) => canvas.fullscreen
      ? AppIconButton(
          icon: AppIcons.expand,
          semanticLabel: 'Exit fullscreen',
          tooltip: 'Exit fullscreen',
          // The same glyph entering it carries, lit - AppIconButton's own selected-tool convention, and there is no shrink glyph in AppIcons to reach for instead.
          active: true,
          onPressed: canvas.onToggleFullscreen,
        )
      : CanvasToolsRow(
          tool: canvas.tool,
          onToolChanged: canvas.onToolChanged,
          canDraw: canvas.canDraw,
          canUndo: canvas.canUndo,
          onUndo: canvas.onUndo,
          canManage: canvas.canManage,
          onClear: canvas.onClear,
          onPasteImage: canvas.onPasteImage,
          onRecenter: canvas.onRecenter,
          selection: canvas.selection,
          onBringToFront: canvas.onBringToFront,
          onSendToBack: canvas.onSendToBack,
          onDeleteSelected: canvas.onDeleteSelected,
          activityLogOpen: canvas.activityLogOpen,
          onToggleActivityLog: canvas.onToggleActivityLog,
          shapeKind: canvas.shapeKind,
          onShapeKindChanged: canvas.onShapeKindChanged,
          pen: canvas.pen,
          onPenChanged: canvas.onPenChanged,
          hasSelfBubble: canvas.hasSelfBubble,
          selfBubbleHidden: canvas.selfBubbleHidden,
          onToggleSelfBubbleHidden: canvas.onToggleSelfBubbleHidden,
          hiddenTiles: canvas.hiddenTiles,
          onShowTile: canvas.onShowTile,
          onToggleFullscreen: canvas.onToggleFullscreen,
          showTools: !canvas.activityLogOpen,
          part: part,
          overflowOpensBelow: overflowOpensBelow,
        );
}
