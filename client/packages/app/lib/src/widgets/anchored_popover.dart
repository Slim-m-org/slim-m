// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Places a popover beside the control that opened it, shared by every
/// anchored popover (member profile, reaction users, move participant).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'message_context_menu_layout.dart' show menuScreenMargin;

/// Places [child] beside [origin]/[anchorSize]: right of the anchor unless
/// that would overhang, then left; below the anchor unless there is no room,
/// then flipped above it - the same measured collision handling
/// `context_menu_region.dart`'s own `MessageMenuLayout` gives the message and
/// channel-row menus, extended with the horizontal side flip a plain floating
/// menu never needs. Neither direction fitting (a very tall popover in a
/// short window) falls back to the innermost [SingleChildScrollView], which
/// shrinks the visible slice rather than letting the popover run off an edge.
class AnchoredPopover extends StatelessWidget {
  const AnchoredPopover({
    super.key,
    required this.origin,
    required this.anchorSize,
    required this.child,
  });

  final Offset origin;
  final Size anchorSize;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final padding =
        MediaQuery.paddingOf(context) + const EdgeInsets.all(menuScreenMargin);
    return Stack(
      children: [
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _AnchoredPopoverLayout(
              origin: origin,
              anchorSize: anchorSize,
              padding: padding,
            ),
            child: SingleChildScrollView(child: child),
          ),
        ),
      ],
    );
  }
}

/// Reads the child's actual laid-out size before placing it, unlike the
/// fixed-height reserve this replaced: that guess left a popover taller than
/// the guess scrolled past the bottom of the window instead of flipping
/// above the row.
class _AnchoredPopoverLayout extends SingleChildLayoutDelegate {
  const _AnchoredPopoverLayout({
    required this.origin,
    required this.anchorSize,
    required this.padding,
  });

  final Offset origin;
  final Size anchorSize;
  final EdgeInsets padding;

  static const double _gap = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(padding);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = size.width - padding.right - childSize.width;
    final rightOfAnchor = origin.dx + anchorSize.width + _gap;
    final fitsRight =
        rightOfAnchor + childSize.width <= size.width - padding.right;
    final left = fitsRight ? rightOfAnchor : origin.dx - childSize.width - _gap;

    final maxTop = size.height - padding.bottom - childSize.height;
    final fitsBelow =
        origin.dy + childSize.height <= size.height - padding.bottom;
    final top = fitsBelow
        ? origin.dy
        : origin.dy + anchorSize.height - childSize.height;

    return Offset(
      left.clamp(padding.left, math.max(padding.left, maxLeft)),
      top.clamp(padding.top, math.max(padding.top, maxTop)),
    );
  }

  @override
  bool shouldRelayout(_AnchoredPopoverLayout oldDelegate) =>
      origin != oldDelegate.origin ||
      anchorSize != oldDelegate.anchorSize ||
      padding != oldDelegate.padding;
}
