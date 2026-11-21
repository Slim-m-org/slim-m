// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one box a video preview occupies in a message: its thumbnail, the
/// player that replaces it and the in-panel stand-in all use it, so the card
/// never changes height when play starts or the video moves.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'docked_video_panel.dart' show kMinPlayerHeight;

/// The box for a video [maxWidth] wide at most: 16:9, never under
/// [kMinPlayerHeight] high (decision 0128's floor).
Size inlineVideoBoxSize(double availableWidth, double maxWidth) {
  final width = math.min(availableWidth, maxWidth);
  return Size(width, math.max(width * 9 / 16, kMinPlayerHeight));
}

class InlineVideoBox extends StatelessWidget {
  const InlineVideoBox({
    super.key,
    required this.maxWidth,
    required this.child,
    this.claimsClicks = false,
  });

  /// Marks the sized box so a test can measure it.
  static const boxKey = Key('inline-video-box');

  final double maxWidth;
  final Widget child;

  /// Keeps a click on the box from reaching the message's text selection,
  /// which would otherwise select a word of the link text above on a
  /// double click meant for the player.
  final bool claimsClicks;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox.fromSize(
        key: boxKey,
        size: inlineVideoBoxSize(constraints.maxWidth, maxWidth),
        child: claimsClicks
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () {},
                child: SelectionContainer.disabled(child: child),
              )
            : child,
      ),
    );
  }
}
