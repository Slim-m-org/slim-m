// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One scaffold for "a small surface opened from a control": a bottom sheet on
/// a compact window, a popover anchored beside the control otherwise.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'anchored_popover.dart';
import 'floating_dock_card.dart';
import 'rise_fade_transition.dart';

/// Opens [popoverBuilder] anchored to [anchor] (or [anchorRect], in overlay
/// coordinates) on a wide window, and [sheetBuilder] (default: the popover's
/// own builder) as a sheet below [kCompactWidth]. Width, never platform,
/// picks the surface, per `desktop-vs-mobile.md`.
///
/// [above] opens the popover over the floating dock [anchor] sits in, as the dock's own menus do.
/// [atTrailingEdge] hangs it off the end of a full-width row rather than beside the whole row.
Future<T?> showAnchoredPopoverOrSheet<T>(
  BuildContext anchor, {
  required WidgetBuilder popoverBuilder,
  WidgetBuilder? sheetBuilder,
  Rect? anchorRect,
  bool sheetScrolls = false,
  bool sheetHandleOverContent = false,
  String? semanticLabel,
  bool above = false,
  bool atTrailingEdge = false,
}) {
  if (MediaQuery.sizeOf(anchor).width < kCompactWidth) {
    return showAppSheet<T>(
      anchor,
      scrolls: sheetScrolls,
      handleOverContent: sheetHandleOverContent,
      semanticLabel: semanticLabel,
      builder: sheetBuilder ?? popoverBuilder,
    );
  }
  final measured = anchorRect ?? _rectOf(anchor, above: above);
  final rect = atTrailingEdge
      ? Rect.fromLTWH(measured.right, measured.top, 0, measured.height)
      : measured;
  return showGeneralDialog<T>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.reduced(anchor, AppMotion.base),
    pageBuilder: (context, _, _) => AnchoredPopover(
      origin: rect.topLeft,
      anchorSize: rect.size,
      above: above,
      child: popoverBuilder(context),
    ),
    transitionBuilder: (context, animation, _, child) =>
        RiseFadeTransition(animation: animation, rise: 8, child: child),
  );
}

Rect _rectOf(BuildContext anchor, {required bool above}) {
  final box = anchor.findRenderObject() as RenderBox?;
  final overlay =
      Overlay.of(anchor, rootOverlay: true).context.findRenderObject()
          as RenderBox?;
  if (box == null || overlay == null) return Rect.zero;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final dockTop = above ? FloatingDockCard.topEdgeOf(anchor, overlay) : null;
  if (dockTop == null) return rect;
  return Rect.fromLTRB(rect.left, dockTop, rect.right, rect.bottom);
}
