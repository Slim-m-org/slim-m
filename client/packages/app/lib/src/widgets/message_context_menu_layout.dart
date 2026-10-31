// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where an open floating surface lands - originally split out of
/// `message_context_menu.dart` to keep that file inside the review budget,
/// now shared by every caller of `context_menu_region.dart` and by
/// `emoji_picker.dart`'s reaction picker, the two floating surfaces the app
/// opens near an arbitrary point in the transcript.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Kept off the viewport edges on top of whatever the safe area already
/// reserves, so a clamped floating surface never sits flush against the
/// screen. Shared by every [MessageMenuLayout] caller, rather than each
/// redeclaring its own copy of the same margin.
const double menuScreenMargin = 8;

/// Enough for a few rows, so a screen too short for the trigger's upward room still shows a usable menu.
const double _minAboveHeight = 96;

/// Places the menu at its anchor, sliding it back inside the viewport rather
/// than letting it run off an edge: a long-press on a message low on a phone
/// screen otherwise puts Delete past the bottom of the display.
class MessageMenuLayout extends SingleChildLayoutDelegate {
  const MessageMenuLayout({
    required this.anchor,
    required this.padding,
    this.above = false,
  });

  final Offset anchor;

  /// Treats [anchor] as the menu's bottom-left, for a trigger near the bottom edge.
  final bool above;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final loose = BoxConstraints.loose(constraints.biggest).deflate(padding);
    if (!above) return loose;
    // A menu opening upward is shortened to the room above its anchor so it never reaches down over the trigger.
    final room = math.max(_minAboveHeight, anchor.dy - padding.top);
    return loose.copyWith(maxHeight: math.min(loose.maxHeight, room));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = size.width - padding.right - childSize.width;
    final maxY = size.height - padding.bottom - childSize.height;
    return Offset(
      anchor.dx.clamp(padding.left, math.max(padding.left, maxX)),
      (above ? anchor.dy - childSize.height : anchor.dy).clamp(
        padding.top,
        math.max(padding.top, maxY),
      ),
    );
  }

  @override
  bool shouldRelayout(MessageMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      above != oldDelegate.above;
}
