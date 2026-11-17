// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One scaffold for "a small surface opened from a control": a bottom sheet on
/// a compact window, a popover anchored beside the control otherwise.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'anchored_popover.dart';
import 'floating_dock_card.dart';

/// Opens [popoverBuilder] anchored to [anchor] (or [anchorRect], in overlay
/// coordinates) on a wide window, and [sheetBuilder] (default: the popover's
/// own builder) as a sheet below [kCompactWidth]. Width, never platform,
/// picks the surface, per `desktop-vs-mobile.md`.
///
/// [above] opens the popover over the floating dock [anchor] sits in, as the dock's own menus do.
Future<T?> showAnchoredPopoverOrSheet<T>(
  BuildContext anchor, {
  required WidgetBuilder popoverBuilder,
  WidgetBuilder? sheetBuilder,
  Rect? anchorRect,
  bool sheetScrolls = false,
  bool sheetHandleOverContent = false,
  String? semanticLabel,
  bool above = false,
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
  final rect = anchorRect ?? _rectOf(anchor, above: above);
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
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.entrance,
        reverseCurve: AppMotion.exit,
      );
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (1 - curved.value) * 8),
            child: child,
          ),
          child: child,
        ),
      );
    },
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
