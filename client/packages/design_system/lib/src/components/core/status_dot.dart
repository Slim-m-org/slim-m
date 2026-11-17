// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A presence indicator: five states, each with its own colour and its own
/// silhouette.
///
/// Colour is never the only cue here. The traffic-light convention is kept
/// because it is the one users already know, but a colour-blind viewer and a
/// screenshot in a bug report both need the state to survive without hue, so
/// every state also gets a distinct shape.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_motion.dart';
import '../../app_tokens.dart';

/// Every state a person can be drawn in, each with the one word that names
/// it.
///
/// [hidden] is "appearing offline": a deliberate privacy choice, not a real
/// disconnect. It has no colour of its own in [AppStatusColors] and reuses
/// [AppStatusColors.offline] on purpose; only the shape tells the two apart.
///
/// [unknown] is "nothing has been reported yet": it draws nothing and has no
/// word, because a grey ring would claim offline and a word would claim
/// something this client has not been told.
enum AppPresence {
  online('online'),
  away('away'),
  dnd('do not disturb'),
  offline('offline'),
  hidden('appearing offline'),
  unknown(null);

  const AppPresence(this.word);

  /// How the state is spoken and written beside a name; null for [unknown].
  final String? word;
}

/// The silhouette each [AppPresence] renders as, independent of colour.
enum AppStatusShape {
  filledDisc,
  triangle,
  notchedSquare,
  hollowRing,
  slashedRing
}

/// A small presence dot, drawn with both a colour and a shape so the state
/// still reads once colour is taken away.
class AppStatusDot extends StatelessWidget {
  const AppStatusDot({
    super.key,
    required this.status,
    this.size = _defaultSize,
    this.backgroundColor,
  });

  final AppPresence status;

  /// Diameter. Defaults to 10, the source design's own default for a
  /// free-standing dot; there is no size token this granular, since a dot's
  /// context (a row, an avatar corner) usually dictates it instead.
  final double size;

  /// What the dot sits on. [AppStatusShape.notchedSquare] and
  /// [AppStatusShape.slashedRing] both punch a mark out of a filled shape in
  /// this colour, so it must match the real backdrop or the mark shows a
  /// seam. Defaults to [AppTokens.surfaceBase].
  final Color? backgroundColor;

  static const double _defaultSize = 10;

  /// The shape for each state, kept as data rather than inlined in [build] so
  /// a test can assert all five stay distinguishable without rendering
  /// pixels.
  static const Map<AppPresence, AppStatusShape> shapeOf = {
    AppPresence.online: AppStatusShape.filledDisc,
    AppPresence.away: AppStatusShape.triangle,
    AppPresence.dnd: AppStatusShape.notchedSquare,
    AppPresence.offline: AppStatusShape.hollowRing,
    AppPresence.hidden: AppStatusShape.slashedRing,
  };

  Color _colorOf(AppStatusColors colors) => switch (status) {
        AppPresence.online => colors.online,
        AppPresence.away => colors.away,
        AppPresence.dnd => colors.dnd,
        AppPresence.offline => colors.offline,
        // No dedicated token: hidden is a privacy choice layered on top of
        // "offline", not a sixth colour, so it reuses offline's.
        AppPresence.hidden => colors.offline,
        AppPresence.unknown => colors.offline,
      };

  @override
  Widget build(BuildContext context) {
    final shape = shapeOf[status];
    if (shape == null) return SizedBox.square(dimension: size);
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Semantics(
      label: status.word,
      // A presence flip cross-fades; the state key means rebuilds swap nothing.
      child: AnimatedSwitcher(
        duration: AppMotion.reduced(context, AppMotion.fast),
        child: CustomPaint(
          key: ValueKey(status),
          size: Size.square(size),
          painter: AppStatusDotPainter(
            shape: shape,
            color: _colorOf(tokens.status),
            backgroundColor: backgroundColor ?? tokens.surfaceBase,
          ),
        ),
      ),
    );
  }
}

/// Draws one of the five [AppStatusShape]s inside a [size]-by-[size] box.
///
/// A public class, not a private `_Painter`, for the same reason
/// [AppStatusDot.shapeOf] is public data: a widget test can reach in and
/// assert `shape` directly instead of inferring it from pixels.
class AppStatusDotPainter extends CustomPainter {
  const AppStatusDotPainter({
    required this.shape,
    required this.color,
    required this.backgroundColor,
  });

  final AppStatusShape shape;
  final Color color;
  final Color backgroundColor;

  /// Every shape stays inside the circle of the dot's width, so the round
  /// cutout an avatar punches for its dot fits all five states alike.
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final center = Offset(w / 2, size.height / 2);
    final radius = w / 2;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (shape) {
      case AppStatusShape.filledDisc:
        canvas.drawCircle(center, radius, fill);

      case AppStatusShape.triangle:
        canvas.drawPath(_roundedTriangle(center, radius), fill);

      case AppStatusShape.notchedSquare:
        final corner = radius * _squareCornerShare;
        final half = (radius - corner) / math.sqrt2 + corner;
        final square = Rect.fromCircle(center: center, radius: half);
        canvas.drawRRect(
            RRect.fromRectAndRadius(square, Radius.circular(corner)), fill);
        canvas.drawRect(
          Rect.fromCenter(
            center: center,
            width: square.width * 0.62,
            height: math.max(2.0, square.height * 0.18),
          ),
          Paint()
            ..color = backgroundColor
            ..style = PaintingStyle.fill,
        );

      case AppStatusShape.hollowRing:
        _drawRing(canvas, center, w, color);

      case AppStatusShape.slashedRing:
        final stroke = _drawRing(canvas, center, w, color);
        // A flat, non-scaling 2px bar ending mid-stroke, so neither end pokes
        // past the ring; the ring scales, since it alone must stay visible small.
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-math.pi / 4);
        canvas.drawRect(
          Rect.fromCenter(center: Offset.zero, width: w - stroke, height: 2),
          Paint()..color = color,
        );
        canvas.restore();
    }
  }

  /// An upright triangle whose rounded corners touch the circle of [radius].
  static Path _roundedTriangle(Offset center, double radius) {
    final corner = radius * _triangleCornerShare;
    final path = Path();
    for (var i = 0; i < 3; i++) {
      final direction = -math.pi / 2 + i * 2 * math.pi / 3;
      final arcCentre =
          center + Offset.fromDirection(direction, radius - corner);
      path.arcTo(
        Rect.fromCircle(center: arcCentre, radius: corner),
        direction - math.pi / 3,
        2 * math.pi / 3,
        i == 0,
      );
    }
    return path..close();
  }

  static const double _triangleCornerShare = 0.2;
  static const double _squareCornerShare = 0.32;

  /// Draws the ring and returns its stroke width.
  double _drawRing(Canvas canvas, Offset center, double w, Color ringColor) {
    // Border-box sizing: the ring's outer edge sits on the box edge and the
    // stroke eats inward, so path radius = outer radius minus half the stroke.
    final strokeWidth = math.max(2.0, w * 0.26);
    canvas.drawCircle(
      center,
      w / 2 - strokeWidth / 2,
      Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
    return strokeWidth;
  }

  @override
  bool shouldRepaint(covariant AppStatusDotPainter oldDelegate) {
    return oldDelegate.shape != shape ||
        oldDelegate.color != color ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
