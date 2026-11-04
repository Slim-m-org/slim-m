// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A menu hung off a trigger, animated in and out.
///
/// The link, follower, surface, outside-tap close and keyboard scope every
/// anchored menu repeated by hand, so a menu cannot appear and vanish in one
/// frame by omitting the surface. The caller keeps the [AnimatedMenuController]
/// because its own items close the menu through it.
library;

import 'package:flutter/material.dart';

import 'animated_menu_portal.dart';
import 'context_menu_focus.dart';

class AnchoredMenu extends StatefulWidget {
  const AnchoredMenu({
    super.key,
    required this.controller,
    required this.menu,
    required this.child,
    this.targetAnchor = Alignment.bottomRight,
    this.followerAnchor = Alignment.topRight,
    this.offset = const Offset(0, 4),
  });

  final AnimatedMenuController controller;

  /// The open menu; closing it goes through [controller].
  final Widget menu;

  /// The trigger the menu hangs off.
  final Widget child;

  /// Where on the trigger the menu attaches; the default is the right edge,
  /// opening leftward so a right-edge trigger does not run off the window.
  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Offset offset;

  @override
  State<AnchoredMenu> createState() => _AnchoredMenuState();
}

const double _kMinRoomBelow = 320;

Alignment _flipped(Alignment a) => Alignment(a.x, -a.y);

class _AnchoredMenuState extends State<AnchoredMenu> {
  final _link = LayerLink();

  /// A trigger near the window's bottom opens its menu upward rather than
  /// letting the window edge clip it.
  bool _opensUpward() {
    final trigger = context.findRenderObject();
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (trigger is! RenderBox || overlay is! RenderBox) return false;
    if (!trigger.hasSize || !overlay.hasSize) return false;
    final rect = MatrixUtils.transformRect(
      trigger.getTransformTo(overlay),
      Offset.zero & trigger.size,
    );
    final below = overlay.size.height - rect.bottom;
    return below < _kMinRoomBelow && rect.top > below;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: controller.portal,
        // Positioned so the follower sizes to its content, not the whole screen a Column would otherwise fill it against.
        overlayChildBuilder: (_) {
          final flip = _opensUpward();
          final follower = flip
              ? _flipped(widget.followerAnchor)
              : widget.followerAnchor;
          return Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: flip
                  ? _flipped(widget.targetAnchor)
                  : widget.targetAnchor,
              followerAnchor: follower,
              offset: flip
                  ? Offset(widget.offset.dx, -widget.offset.dy)
                  : widget.offset,
              child: AnimatedMenuSurface(
                controller: controller,
                alignment: follower,
                child: TapRegion(
                  onTapOutside: (_) => controller.hide(),
                  // Escape closes it and Tab reaches every item once open.
                  child: ContextMenuKeyboardScope(
                    onDismiss: controller.hide,
                    child: widget.menu,
                  ),
                ),
              ),
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}
