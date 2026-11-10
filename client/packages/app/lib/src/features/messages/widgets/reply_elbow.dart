// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip above a reply's avatar row: its quote line, and the hooked
/// connector that runs from the avatar up and right into it.
///
/// The connector lives in the avatar column and stops short of the content
/// column, so it never crosses text. See `docs/design/desktop-vs-mobile.md`
/// law 1: it follows the avatar step the density setting picks, not the
/// platform. Law 2: at touch density the quote's press area reaches down to
/// 44dp over the author line, which is why the strip sits above the row in a
/// [Stack] rather than ahead of it in a column that would clip the reach.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:slimm_design_system/design_system.dart';

import 'continuation_marker.dart' show ContinuationRail;
import 'reply_quote.dart';
import 'toolbar_clearance.dart';

class ReplyElbow extends StatelessWidget {
  const ReplyElbow({
    super.key,
    required this.avatarSize,
    required this.quote,
    required this.child,
    this.clearance = EdgeInsets.zero,
  });

  /// Key on the painted connector, for tests that measure where it lands.
  static const Key lineKey = Key('reply_elbow_line');

  /// Space between the connector's tip and the quote's first glyph.
  static const double tipGap = AppSpacing.s4;

  /// The least width the quote keeps once [clearance] is taken off its right.
  ///
  /// Narrower than this it runs under the toolbar instead, as a body does.
  static const double minQuoteWidth = 240;

  /// The strip's height at the reader's text scale.
  static double heightOf(BuildContext context) => ReplyQuote.heightOf(context);

  /// The author avatar step this strip hangs over.
  final double avatarSize;

  /// The reply's [ReplyQuote].
  final Widget quote;

  /// The avatar and message column the strip sits above.
  final Widget child;

  /// Room the hover toolbar needs on the right of the row's first line.
  final EdgeInsets clearance;

  @override
  Widget build(BuildContext context) {
    final height = heightOf(context);
    final touch = AppTouchTargets.of(context) ? AppSizes.rowTouch : 0.0;
    return _StripFirstStack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: math.max(height, touch),
          child: _Strip(
            avatarSize: avatarSize,
            height: height,
            clearance: clearance,
            quote: quote,
          ),
        ),
        Padding(
          padding: EdgeInsets.only(top: height),
          child: child,
        ),
      ],
    );
  }
}

/// A [Stack] that hit-tests its first child before the rest.
///
/// The strip is first so a screen reader hears the quote before the row, and
/// it must also win the press where its touch reach overlaps the author line.
class _StripFirstStack extends Stack {
  const _StripFirstStack({required super.children});

  @override
  RenderStack createRenderObject(BuildContext context) =>
      _RenderStripFirstStack(
        alignment: alignment,
        textDirection: textDirection ?? Directionality.maybeOf(context),
        fit: fit,
        clipBehavior: clipBehavior,
      );
}

class _RenderStripFirstStack extends RenderStack {
  _RenderStripFirstStack({
    super.alignment,
    super.textDirection,
    super.fit,
    super.clipBehavior,
  });

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final strip = firstChild;
    if (strip == null) return false;
    final offset = (strip.parentData! as StackParentData).offset;
    final onStrip = result.addWithPaintOffset(
      offset: offset,
      position: position,
      hitTest: (result, local) => strip.hitTest(result, position: local),
    );
    return onStrip || defaultHitTestChildren(result, position: position);
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    required this.avatarSize,
    required this.height,
    required this.clearance,
    required this.quote,
  });

  final double avatarSize;
  final double height;
  final EdgeInsets clearance;
  final Widget quote;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final gutter = avatarSize + AppSpacing.s12;
    final left = gutter - ReplyQuote.ringInset;
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          height: height,
          width: gutter,
          child: IgnorePointer(
            child: CustomPaint(
              key: ReplyElbow.lineKey,
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
          padding: EdgeInsets.only(left: left),
          child: ToolbarClearance(
            clearance: clearance,
            minWidth: ReplyElbow.minQuoteWidth,
            // The cap wraps the Align: a cap around the quote cuts its reach.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMessageColumnMax),
              child: Align(alignment: Alignment.topLeft, child: quote),
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
