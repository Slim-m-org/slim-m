// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hosts a row's hover toolbar in the app overlay, hung from the row's top
/// right, so a row shorter than the toolbar keeps its density spacing.
///
/// A control laid out past its row's edge paints but cannot be hit, because
/// every ancestor rejects a pointer outside its own box. The overlay has no
/// such ancestors, so the whole plate stays clickable however short the row.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/hover_reveal.dart';
import 'message_hover_toolbar.dart';

class MessageToolbarAnchor extends StatefulWidget {
  const MessageToolbarAnchor({
    super.key,
    required this.show,
    required this.toolbar,
    required this.child,
  });

  /// Whether the toolbar is visible now.
  final bool show;
  final Widget toolbar;

  /// The row; the toolbar hangs from its top right.
  final Widget child;

  @override
  State<MessageToolbarAnchor> createState() => _MessageToolbarAnchorState();
}

class _MessageToolbarAnchorState extends State<MessageToolbarAnchor> {
  final _portal = OverlayPortalController();
  bool _attached = false;

  @override
  void initState() {
    super.initState();
    _attachWhenNeeded();
  }

  @override
  void didUpdateWidget(MessageToolbarAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _attachWhenNeeded();
  }

  // Rows that are never hovered never pay for an overlay child.
  void _attachWhenNeeded() {
    if (!widget.show || _attached) return;
    _attached = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _portal.show();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scrollable = Scrollable.maybeOf(context);
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (overlayContext, info) {
        if (!widget.show) return const SizedBox.shrink();
        final rowTopRight = MatrixUtils.transformPoint(
          info.childPaintTransform,
          Offset(info.childSize.width, 0),
        );
        if (!_plateFits(context, scrollable, info, rowTopRight.dy)) {
          return const SizedBox.shrink();
        }
        return Positioned(
          top: rowTopRight.dy,
          right: info.overlaySize.width - rowTopRight.dx + AppSizes.paneGutter,
          child: _KeepsRowHovered(child: widget.toolbar),
        );
      },
      child: widget.child,
    );
  }
}

/// Whether the plate, hanging from the row's top, lies inside the list's
/// viewport; a row scrolled half out of sight shows none rather than floating
/// the plate over the header above it.
bool _plateFits(
  BuildContext row,
  ScrollableState? scrollable,
  OverlayChildLayoutInfo info,
  double plateTop,
) {
  final rowBox = row.findRenderObject();
  final viewport = scrollable?.context.findRenderObject();
  if (rowBox is! RenderBox || viewport is! RenderBox) return true;
  if (!rowBox.attached || !viewport.attached) return true;
  final overlayTop =
      rowBox.localToGlobal(Offset.zero).dy -
      MatrixUtils.transformPoint(info.childPaintTransform, Offset.zero).dy;
  final viewportTop = viewport.localToGlobal(Offset.zero).dy - overlayTop;
  final viewportBottom = viewportTop + viewport.size.height;
  return plateTop >= viewportTop &&
      plateTop + MessageHoverToolbar.height <= viewportBottom;
}

/// Reports the pointer over the toolbar to the row, which it has left.
class _KeepsRowHovered extends StatelessWidget {
  const _KeepsRowHovered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = HoverRevealScope.maybeOf(context);
    return MouseRegion(
      onEnter: (_) => scope?.reportOverlayHover(true),
      onExit: (_) => scope?.reportOverlayHover(false),
      child: child,
    );
  }
}
