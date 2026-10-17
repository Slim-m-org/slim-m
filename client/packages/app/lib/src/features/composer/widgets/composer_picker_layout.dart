// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the composer's Emoji/GIFs picker lands: above whichever button
/// opened it, right-aligned, clamped inside the viewport - the mirror image
/// of `message_context_menu_layout.dart`'s `MessageMenuLayout`, which
/// anchors from a top-left corner because the reaction picker opens below a
/// message instead of above a composer.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The gap the panel's own bottom edge leaves above [ComposerPickerLayout.anchor].
const double composerPickerGap = 8;

/// Places the child's bottom-right corner at [anchor], sliding it back
/// inside the viewport rather than letting it run off an edge.
class ComposerPickerLayout extends SingleChildLayoutDelegate {
  const ComposerPickerLayout({required this.anchor, required this.padding});

  /// The trigger's own top-right corner, in the overlay's coordinate space.
  final Offset anchor;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(padding);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = size.width - padding.right - childSize.width;
    final maxY = size.height - padding.bottom - childSize.height;
    final x = anchor.dx - childSize.width;
    final y = anchor.dy - composerPickerGap - childSize.height;
    return Offset(
      x.clamp(padding.left, math.max(padding.left, maxX)),
      y.clamp(padding.top, math.max(padding.top, maxY)),
    );
  }

  @override
  bool shouldRelayout(ComposerPickerLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}
