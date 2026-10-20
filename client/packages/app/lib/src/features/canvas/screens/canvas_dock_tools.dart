// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas half of the dock, split out of `canvas_call_dock.dart` so the
/// phone layout (`canvas_compact_dock.dart`) can draw the same row.
library;

import 'package:flutter/material.dart';

import 'canvas_call_dock.dart';
import 'canvas_tools_row.dart';

/// The canvas half of the dock: the tool strip, in fullscreen too.
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
  Widget build(BuildContext context) => CanvasToolsRow(
    tool: canvas.tool,
    onToolChanged: canvas.onToolChanged,
    canDraw: canvas.canDraw,
    canUndo: canvas.canUndo,
    onUndo: canvas.onUndo,
    canRedo: canvas.canRedo,
    onRedo: canvas.onRedo,
    canManage: canvas.canManage,
    onClear: canvas.onClear,
    scopedClear: canvas.scopedClear,
    onPasteImage: canvas.onPasteImage,
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
    fullscreen: canvas.fullscreen,
    showTools: !canvas.activityLogOpen,
    part: part,
    overflowOpensBelow: overflowOpensBelow,
  );
}
