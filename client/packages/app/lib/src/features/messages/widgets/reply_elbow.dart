// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip above a reply's avatar: its quote line, and the hooked connector
/// that runs from the avatar up and right into it.
///
/// The connector lives in the avatar column and stops short of the content
/// column, so it never crosses text. See `docs/design/desktop-vs-mobile.md`
/// law 1: it follows the avatar step the density setting picks, not the
/// platform.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'continuation_marker.dart' show ContinuationRail;
import 'reply_quote.dart';

class ReplyElbow extends StatelessWidget {
  const ReplyElbow({
    super.key,
    required this.avatarSize,
    required this.quote,
    this.clearance = EdgeInsets.zero,
  });

  /// Key on the painted connector, for tests that measure where it lands.
  static const Key lineKey = Key('reply_elbow_line');

  /// Space between the connector's tip and the quote's first glyph.
  static const double tipGap = AppSpacing.s4;

  /// The strip's height at the reader's text scale.
  static double heightOf(BuildContext context) => ReplyQuote.heightOf(context);

  /// The author avatar step this strip hangs over.
  final double avatarSize;

  /// The reply's [ReplyQuote].
  final Widget quote;

  /// Room the hover toolbar needs on the right of the row's first line.
  final EdgeInsets clearance;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final height = heightOf(context);
    final gutter = avatarSize + AppSpacing.s12;
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: gutter,
          child: IgnorePointer(
            child: CustomPaint(
              key: lineKey,
              painter: ReplyElbowPainter(
                color: tokens.borderSubtle,
                geometry: ReplyElbowGeometry(
                  avatarSize: avatarSize,
                  height: height,
                  lineY: height / 2,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding:
              EdgeInsets.only(left: gutter - ReplyQuote.ringInset) + clearance,
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMessageColumnMax),
              child: quote,
            ),
          ),
        ),
      ],
    );
  }
}

/// Where the connector starts and ends, in the coordinates of its own box.
class ReplyElbowGeometry {
  const ReplyElbowGeometry({
    required this.avatarSize,
    required this.height,
    required this.lineY,
  });

  final double avatarSize;

  /// The box's height, which ends where the avatar below begins.
  final double height;

  /// The quote line's vertical centre.
  final double lineY;

  /// Where the connector leaves the avatar column: the top centre of the avatar.
  Offset get tail => Offset(avatarSize / 2, height);

  /// Where it stops, a [ReplyElbow.tipGap] short of the quote.
  Offset get tip =>
      Offset(avatarSize + AppSpacing.s12 - ReplyElbow.tipGap, lineY);

  @override
  bool operator ==(Object other) =>
      other is ReplyElbowGeometry &&
      other.avatarSize == avatarSize &&
      other.height == height &&
      other.lineY == lineY;

  @override
  int get hashCode => Object.hash(avatarSize, height, lineY);
}

class ReplyElbowPainter extends CustomPainter {
  const ReplyElbowPainter({required this.color, required this.geometry});

  final Color color;
  final ReplyElbowGeometry geometry;

  @override
  void paint(Canvas canvas, Size size) {
    final tail = geometry.tail;
    final tip = geometry.tip;
    final radius = [
      ContinuationRail.elbowRadius,
      tail.dy - tip.dy,
      tip.dx - tail.dx,
    ].reduce((a, b) => a < b ? a : b);
    final path = Path()
      ..moveTo(tail.dx, tail.dy)
      ..lineTo(tail.dx, tip.dy + radius)
      ..arcToPoint(
        Offset(tail.dx + radius, tip.dy),
        radius: Radius.circular(radius),
      )
      ..lineTo(tip.dx, tip.dy);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = ContinuationRail.thickness,
    );
  }

  @override
  bool shouldRepaint(ReplyElbowPainter old) =>
      old.color != color || old.geometry != geometry;
}
