// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The conditional sections of the canvas overflow menu.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../widgets/canvas_clear_scope.dart';
import 'canvas_shape_icons.dart';
import 'canvas_tools_row.dart' show CanvasHiddenTile;

/// Menu rows that depend on the tool, the selection and the viewer's rights.
class CanvasOverflowSections {
  const CanvasOverflowSections({
    required this.hiddenTiles,
    required this.tool,
    required this.shapeKind,
    required this.canManage,
    required this.scopedClear,
    required this.onShowTile,
    required this.onPickShapeKind,
    required this.onBringToFront,
    required this.onSendToBack,
    required this.onDelete,
    required this.onClear,
    required this.onScopedClear,
  });

  final List<CanvasHiddenTile> hiddenTiles;
  final CanvasTool tool;
  final CanvasShapeKind shapeKind;
  final bool canManage;
  final CanvasScopedClear? scopedClear;
  final void Function(String key) onShowTile;
  final void Function(CanvasShapeKind kind) onPickShapeKind;
  final void Function(String objectId) onBringToFront;
  final void Function(String objectId) onSendToBack;
  final void Function(String objectId) onDelete;
  final VoidCallback onClear;
  final void Function(CanvasScopedClear control) onScopedClear;

  List<Widget> hiddenTileItems() {
    if (hiddenTiles.isEmpty) return const [];
    return [
      const AppMenuDivider(),
      for (final tile in hiddenTiles)
        AppMenuItem(
          label: 'Show ${tile.label}',
          leading: AppIcons.tileHide,
          onTap: () => onShowTile(tile.key),
        ),
    ];
  }

  List<Widget> shapeKindItems() {
    if (tool != CanvasTool.shape) return const [];
    return [
      const AppMenuDivider(),
      for (final kind in CanvasShapeKind.values)
        AppMenuItem(
          label: canvasShapeKindLabel(kind),
          leading: canvasShapeKindIcon(kind),
          selected: shapeKind == kind,
          onTap: () => onPickShapeKind(kind),
        ),
    ];
  }

  List<Widget> selectionItems(String selected) => [
    const AppMenuDivider(),
    AppMenuItem(
      label: 'Bring to front',
      leading: AppIcons.bringToFront,
      onTap: () => onBringToFront(selected),
    ),
    AppMenuItem(
      label: 'Send to back',
      leading: AppIcons.sendToBack,
      onTap: () => onSendToBack(selected),
    ),
    AppMenuItem(
      label: 'Delete',
      leading: AppIcons.delete,
      tone: AppMenuItemTone.danger,
      onTap: () => onDelete(selected),
    ),
  ];

  List<Widget> manageItems() {
    if (!canManage) return const [];
    return [
      const AppMenuDivider(),
      AppMenuItem(
        label: 'Clear canvas',
        leading: AppIcons.delete,
        tone: AppMenuItemTone.danger,
        onTap: onClear,
      ),
      if (scopedClear case final control?)
        AppMenuItem(
          label: 'Clear part of the canvas',
          leading: AppIcons.eraser,
          tone: AppMenuItemTone.danger,
          onTap: () => onScopedClear(control),
        ),
    ];
  }
}
