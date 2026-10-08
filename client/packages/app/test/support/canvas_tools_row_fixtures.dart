// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [CanvasToolsRow] wrapped for a widget test, and its own
/// fill-in-the-blanks constructor - shared between `canvas_tools_row_test.dart`
/// (everything the row does), `canvas_tools_row_shape_kind_test.dart` (the
/// shape-kind picker and the armed icon it drives) and
/// `canvas_tools_row_touch_reach_test.dart` (the tool strip's own scroll and
/// edge-fade behaviour at a phone width).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pen_style.dart';
import 'package:slimm_app/src/screens/canvas/canvas_tools_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// [touch], when non-null, forces [AppTouchTargets] rather than relying on
/// its own width fallback, which reads the real test window - a `SizedBox`
/// here only constrains this widget's own render box, not
/// `MediaQuery.sizeOf`, so a narrow [width] alone does not put every button
/// at its 44dp touch size the way a real phone always would. Left null, the
/// fallback applies exactly as it would for any other caller (needed by the
/// one existing test here that shrinks the real test window itself and
/// wants that fallback to see it).
///
/// Bottom-aligned rather than sat at the Scaffold's own top-left: this row
/// only ever renders inside the floating dock in production, near the
/// bottom of the pane, and its own overflow menu opens *upward* from there
/// on purpose (`canvas_overflow_menu.dart`'s own doc explains why). A test
/// harness that instead put the row at the top of the screen would have
/// nothing above it for that menu to open into, which is a fixture problem,
/// not a real one - production never renders this row anywhere but there.
Widget wrapCanvasToolsRow(Widget child, {double width = 800, bool? touch}) =>
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: width,
            child: touch == null
                ? child
                : AppTouchTargets(enabled: touch, child: child),
          ),
        ),
      ),
    );

CanvasToolsRow buildCanvasToolsRow({
  CanvasTool tool = CanvasTool.pen,
  ValueChanged<CanvasTool>? onToolChanged,
  bool canDraw = true,
  bool canUndo = false,
  VoidCallback? onUndo,
  bool canRedo = false,
  VoidCallback? onRedo,
  bool canManage = false,
  Future<void> Function()? onClear,
  VoidCallback? onPasteImage,
  ValueListenable<String?>? selection,
  ValueChanged<String>? onBringToFront,
  ValueChanged<String>? onSendToBack,
  ValueChanged<String>? onDeleteSelected,
  bool activityLogOpen = false,
  VoidCallback? onToggleActivityLog,
  CanvasShapeKind shapeKind = CanvasShapeKind.rectangle,
  ValueChanged<CanvasShapeKind>? onShapeKindChanged,
  CanvasPenStyle pen = const CanvasPenStyle(),
  ValueChanged<CanvasPenStyle>? onPenChanged,
  bool hasSelfBubble = false,
  bool selfBubbleHidden = false,
  VoidCallback? onToggleSelfBubbleHidden,
  List<CanvasHiddenTile> hiddenTiles = const [],
  ValueChanged<String>? onShowTile,
  VoidCallback? onToggleFullscreen,
  bool showTools = true,
}) => CanvasToolsRow(
  tool: tool,
  onToolChanged: onToolChanged ?? (_) {},
  canDraw: canDraw,
  canUndo: canUndo,
  onUndo: onUndo ?? () {},
  canRedo: canRedo,
  onRedo: onRedo ?? () {},
  canManage: canManage,
  onClear: onClear ?? () async {},
  onPasteImage: onPasteImage ?? () {},
  selection: selection ?? ValueNotifier<String?>(null),
  onBringToFront: onBringToFront ?? (_) {},
  onSendToBack: onSendToBack ?? (_) {},
  onDeleteSelected: onDeleteSelected ?? (_) {},
  activityLogOpen: activityLogOpen,
  onToggleActivityLog: onToggleActivityLog ?? () {},
  onToggleFullscreen: onToggleFullscreen ?? () {},
  shapeKind: shapeKind,
  onShapeKindChanged: onShapeKindChanged ?? (_) {},
  pen: pen,
  onPenChanged: onPenChanged ?? (_) {},
  hasSelfBubble: hasSelfBubble,
  selfBubbleHidden: selfBubbleHidden,
  onToggleSelfBubbleHidden: onToggleSelfBubbleHidden ?? () {},
  hiddenTiles: hiddenTiles,
  onShowTile: onShowTile ?? (_) {},
  showTools: showTools,
);
