// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stamps over a shared screen's tile (decision 0121), placed and faded by
/// the same rules the sharer's overlay paints them with.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../screen_overlay/providers/screen_annotation_board.dart';
import '../../screen_overlay/providers/stamp_content.dart';
import 'stamp_view.dart';

/// The box a stamp fills over [content]: its longest side [size] of the screen's height, its shape [aspect], its centre at [at] (0 to 1) and held so all of it stays on the screen.
Rect stampBox(Rect content, Offset at, double size, double aspect) {
  final side = size * content.height;
  final width = aspect >= 1 ? side : side * aspect;
  final height = aspect >= 1 ? side / aspect : side;
  double hold(double v, double lo, double hi) =>
      lo > hi ? (lo + hi) / 2 : v.clamp(lo, hi);
  final cx = hold(
    content.left + at.dx * content.width,
    content.left + width / 2,
    content.right - width / 2,
  );
  final cy = hold(
    content.top + at.dy * content.height,
    content.top + height / 2,
    content.bottom - height / 2,
  );
  return Rect.fromCenter(center: Offset(cx, cy), width: width, height: height);
}

/// One positioned stamp per live stamp in [marks]; [aspectOf] is null for a picture still loading, which shows nothing yet.
List<Widget> screenStampMarks({
  required List<ScreenAnnotation> marks,
  required Rect content,
  required DateTime now,
  required double? Function(StampContent content) aspectOf,
  required bool reduceMotion,
}) => [
  for (final mark in marks)
    if (mark.stamp case final stamp? when mark.points.length == 2)
      if (aspectOf(stamp) case final aspect? when mark.alphaAt(now) > 0)
        Positioned.fromRect(
          key: ValueKey(mark.id),
          rect: stampBox(
            content,
            Offset(mark.points[0], mark.points[1]),
            mark.size,
            math.max(aspect, 0.01),
          ),
          child: Opacity(
            opacity: mark.alphaAt(now).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: mark.scaleAt(now, reduceMotion: reduceMotion),
              child: StampView(content: stamp),
            ),
          ),
        ),
];
